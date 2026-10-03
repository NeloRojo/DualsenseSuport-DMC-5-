"""Read original DMC5 PAK/BNK/PCK media. Never modify or extract the game.

Wwise package table layout checked against wwiser-utils' PCK format reader.
Only one bounded, encoded temporary WEM is used by the external decoder.
Decoded PCM is piped straight into RAM; no WAV is written.
"""
import hashlib, io, json, struct, subprocess, tempfile, threading, wave, zlib
from pathlib import Path
from collections import OrderedDict

MAX_RESOURCE=256*1024*1024
MAX_AUDIO_SECONDS=30

def rot(x,n): return ((x<<n)|(x>>(32-n)))&0xffffffff

def path_hash(text):
    b=text.encode('utf-16le');h=0xffffffff
    for i in range(0,len(b)//4*4,4):
        k=int.from_bytes(b[i:i+4],'little');k=rot(k*0xcc9e2d51&0xffffffff,15)*0x1b873593&0xffffffff
        h=rot(h^k,13);h=(h*5+0xe6546b64)&0xffffffff
    tail=b[len(b)//4*4:]
    if tail:
        k=int.from_bytes(tail,'little');k=rot(k*0xcc9e2d51&0xffffffff,15)*0x1b873593&0xffffffff;h^=k
    h^=len(b);h^=h>>16;h=h*0x85ebca6b&0xffffffff;h^=h>>13;h=h*0xc2b2ae35&0xffffffff;h^=h>>16
    return h

def bank_media(data):
    pos=0;index=None;base=None;length=0
    while pos<len(data):
        if pos+8>len(data):raise ValueError('BNK truncado')
        tag,size=struct.unpack_from('<4sI',data,pos);pos+=8
        if pos+size>len(data):raise ValueError('BNK fuera de limites')
        if tag==b'DIDX':index=data[pos:pos+size]
        if tag==b'DATA':base=pos;length=size
        pos+=size
    if index is None:return []
    if len(index)%12 or base is None:raise ValueError('Indice BNK invalido')
    rows=[]
    for identity,start,size in struct.iter_unpack('<III',index):
        if start+size>length:raise ValueError('Media BNK fuera de limites')
        if size:rows.append((str(identity),base+start,size))
    return rows

def package_media(data):
    if len(data)<24 or data[:4]!=b'AKPK':raise ValueError('PCK no compatible')
    endian='<' if struct.unpack_from('<I',data,8)[0]==1 else '>'
    header,flag,languages,banks,sounds=struct.unpack_from(endian+'5I',data,4)
    if flag!=1 or header+8>len(data):raise ValueError('Cabecera PCK invalida')
    external=struct.unpack_from(endian+'I',data,24)[0] if languages+banks+sounds+16<header else 0
    pos=28 if external or languages+banks+sounds+16<header else 24
    pos+=languages;rows=[]
    for kind,size in (('bank',banks),('sound',sounds),('external',external)):
        if not size:continue
        if size<4 or pos+size>header+8:raise ValueError('Tabla PCK fuera de limites')
        count=struct.unpack_from(endian+'I',data,pos)[0]
        if count:
            if (size-4)%count:raise ValueError('Entradas PCK invalidas')
            stride=(size-4)//count
            if stride not in (20,24):raise ValueError('Variante PCK no compatible')
            for i in range(count):
                p=pos+4+i*stride
                if kind=='external' and stride==24:identity,block,length,offset,lang=struct.unpack_from(endian+'Q4I',data,p)
                elif stride==24:identity,block,length,offset,lang=struct.unpack_from(endian+'IIQII',data,p)
                else:identity,block,length,offset,lang=struct.unpack_from(endian+'5I',data,p)
                offset*=block or 1
                if offset+length>len(data):raise ValueError('Media PCK fuera de limites')
                if kind=='bank':
                    rows.extend((identity2,offset+start,n) for identity2,start,n in bank_media(data[offset:offset+length]))
                elif length:rows.append((str(identity),offset,length))
        pos+=size
    return rows

def resources(game,list_path):
    names=[n.strip() for n in Path(list_path).read_text(encoding='utf-8-sig').splitlines()
           if '/sound/wwise/' in n.lower() and ('.bnk.2.' in n.lower() or '.pck.3.' in n.lower())]
    lookup={(path_hash(n.lower()),path_hash(n.upper())):n for n in names};latest={}
    for pak in sorted(Path(game).glob('*.pak')):
        stat=pak.stat()
        with pak.open('rb') as f:
            raw=f.read(16)
            if len(raw)!=16:continue
            magic,major,minor,flags,count,_=struct.unpack('<4sBBHII',raw)
            if (magic,major,minor,flags)!=(b'KPKA',4,0,0):raise ValueError('PAK no compatible: '+pak.name)
            if count*48>stat.st_size-16:raise ValueError('Tabla PAK fuera de limites')
            table=f.read(count*48)
        for lo,hi,offset,size,expanded,flags,_ in struct.iter_unpack('<IIQQQQQ',table):
            name=lookup.get((lo,hi))
            if not name:continue
            if not 0<size<=MAX_RESOURCE or not 0<expanded<=MAX_RESOURCE or offset+size>stat.st_size:raise ValueError('Recurso de audio fuera de limites')
            latest[name]=dict(pak=str(pak.resolve()),stamp=[stat.st_size,stat.st_mtime_ns],offset=offset,size=size,expanded=expanded,flags=flags,name=name)
    return latest

class Sources:
    def __init__(self,decoder):self.decoder=Path(decoder);self.cache=OrderedDict();self.bytes=0;self.proc=None;self.lock=threading.Lock()
    def read(self,source):
        key=(source['pak'],source['offset'],source['size'],tuple(source['stamp']))
        if key in self.cache:self.cache.move_to_end(key);return self.cache[key]
        pak=Path(source['pak']);stat=pak.stat()
        if [stat.st_size,stat.st_mtime_ns]!=source['stamp']:raise ValueError('Archivos del juego cambiaron; actualiza el indice')
        size=source['size'];expanded=source['expanded'];flags=source['flags']
        if not 0<size<=MAX_RESOURCE or not 0<expanded<=MAX_RESOURCE or source['offset']<16 or source['offset']+size>stat.st_size or flags&0xff0000:raise ValueError('Recurso no compatible')
        with pak.open('rb') as f:f.seek(source['offset']);data=f.read(size)
        mode=flags&15
        if mode==1:
            obj=zlib.decompressobj(-15);data=obj.decompress(data,expanded+1)
            if not obj.eof or obj.unconsumed_tail:raise ValueError('Compresion PAK invalida')
        elif mode==2:
            import zstandard
            data=zstandard.ZstdDecompressor().decompress(data,max_output_size=expanded)
        elif mode!=0:raise ValueError('Compresion PAK no compatible')
        if len(data)!=expanded:raise ValueError('Longitud PAK inesperada')
        while self.cache and self.bytes+len(data)>64*1024*1024:
            _,old=self.cache.popitem(last=False);self.bytes-=len(old)
        if len(data)<=64*1024*1024:self.cache[key]=data;self.bytes+=len(data)
        return data
    def encoded(self,source):
        data=self.read(source);start=source['media_offset'];size=source['media_size']
        if not 0<size<=32*1024*1024 or start<0 or start+size>len(data):raise ValueError('Muestra fuera de limites')
        return data[start:start+size]
    def decode(self,source,cancel=None,encoded=None):
        encoded=self.encoded(source) if encoded is None else encoded
        if cancel and cancel.is_set():raise InterruptedError()
        with tempfile.TemporaryDirectory(prefix='dmc5-listen-') as folder:
            path=Path(folder)/'source.wem';path.write_bytes(encoded)
            proc=subprocess.Popen([str(self.decoder),'-p','-i','-D','2',str(path)],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0)|getattr(subprocess,'BELOW_NORMAL_PRIORITY_CLASS',0))
            with self.lock:self.proc=proc
            timer=threading.Timer(8,lambda:proc.kill() if proc.poll() is None else None);timer.start()
            try:
                raw=proc.stdout.read(MAX_AUDIO_SECONDS*96000*4+65536)
                with wave.open(io.BytesIO(raw)) as w:
                    if w.getsampwidth()!=2 or w.getnchannels() not in (1,2) or not 8000<=w.getframerate()<=96000:raise ValueError('Formato de audio no compatible')
                    rate=w.getframerate();channels=w.getnchannels();pcm=w.readframes(min(w.getnframes(),MAX_AUDIO_SECONDS*rate))
                if not pcm:raise ValueError('Muestra vacia')
                return pcm,rate,channels
            finally:
                if proc.poll() is None:proc.kill()
                proc.wait();proc.stdout.close();timer.cancel()
                with self.lock:
                    if self.proc is proc:self.proc=None
    def cancel(self):
        with self.lock:
            if self.proc and self.proc.poll() is None:self.proc.kill()
    def clear(self):self.cache.clear();self.bytes=0

def category(name):
    stem=Path(name).name.lower()
    return 'music' if stem.startswith('bgm') or '_bgm' in stem else 'voice' if '.en' in stem or '.ja' in stem or '_v.' in stem or '_voice' in stem else 'effects'

def source_rows(game,list_path,reader,cancel=None):
    entries=resources(game,list_path)
    for name,source in sorted(entries.items(),key=lambda item:(category(item[0])!='effects',item[0])):
        if cancel and cancel.is_set():return
        # RE Engine may keep only the package header in the resident resource.
        # The streaming companion has the same header plus the actual payload.
        # Do not treat the header-only half as missing/broken audio.
        companion=name.replace('natives/x64/','natives/x64/streaming/',1)
        if '.pck.' in name and '/streaming/' not in name and companion in entries:continue
        try:
            data=reader.read(source)
            media=bank_media(data) if '.bnk.' in name else package_media(data)
            for identity,start,size in media:
                row={**source,'media_offset':start,'media_size':size,'media_id':identity,'category':category(name)}
                key=hashlib.sha256(json.dumps(row,sort_keys=True).encode()).hexdigest()
                yield key,row,''
        except (ValueError,OSError,struct.error) as exc:yield name,None,str(exc)
