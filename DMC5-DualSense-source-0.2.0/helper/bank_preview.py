"""Developer bank auditions decoded on demand into bounded volatile RAM."""
import array,io,json,subprocess,threading,time,wave
from pathlib import Path
from collections import OrderedDict

def pcm_speaker(raw,max_seconds=10):
    with wave.open(io.BytesIO(raw)) as w:
        rate=w.getframerate();channels=w.getnchannels()
        if w.getsampwidth()!=2 or channels not in (1,2) or not 8000<=rate<=96000:raise ValueError('Unsupported bank PCM')
        samples=array.array('h',w.readframes(min(w.getnframes(),rate*max_seconds)))
    mono=[sum(samples[i:i+channels])/channels/32768 for i in range(0,len(samples)-channels+1,channels)]
    if not mono:raise ValueError('Empty bank audio')
    scale=.92/max(max(abs(x) for x in mono),.01);out=array.array('f')
    for i in range(min(48000*max_seconds,int(len(mono)*48000/rate))):
        pos=i*rate/48000;j=int(pos);fraction=pos-j
        value=(mono[j]*(1-fraction)+mono[min(j+1,len(mono)-1)]*fraction)*scale
        out.extend((0,value,0,0))
    return out.tobytes()

class BankPreview:
    def __init__(self,bridge):
        self.index={};self.decoder=None;self.error='';self.pending=None;self.result=None
        self.lock=threading.Lock();self.closed=False;self.generation=0;self.cache=OrderedDict();self.cache_bytes=0;self.release_requested=False
        try:
            data=json.loads((Path(bridge)/'audio_bank_runtime.json').read_text())
            self.decoder=Path(data['decoder']).resolve();root=Path(data['root']).resolve();self.root=root
            if not self.decoder.is_file():return
            for key,filename in data['events'].items():
                relative=Path(filename)
                if key.startswith('preview_bank_') and not relative.is_absolute() and '..' not in relative.parts and relative.suffix=='.txtp':self.index[key]=root/relative
        except (OSError,KeyError,ValueError,TypeError):return
        self.thread=threading.Thread(target=self._work,daemon=True);self.thread.start()
    def submit(self,seq,event):
        with self.lock:self.generation+=1;self.result=None;self.pending=(self.generation,seq,event);self.error=''
    def cancel(self):
        with self.lock:self.generation+=1;self.pending=None;self.result=None
    def release(self):
        self.cancel()
        with self.lock:self.release_requested=True
    def poll(self):
        with self.lock:value=self.result;self.result=None;return value
    def _decode(self,path):
        path=path.resolve()
        if hasattr(self,'root') and (not path.is_relative_to(self.root) or not path.is_file()):raise ValueError('Receta fuera del banco o no disponible')
        proc=subprocess.Popen([str(self.decoder),'-p','-i',str(path)],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        timer=threading.Timer(8,lambda:proc.kill() if proc.poll() is None else None);timer.start()
        try:return pcm_speaker(proc.stdout.read(2*1024*1024))
        finally:
            if proc.poll() is None:proc.kill()
            proc.wait();proc.stdout.close();timer.cancel()
    def _work(self):
        while not self.closed:
            with self.lock:item=self.pending;self.pending=None;release=self.release_requested;self.release_requested=False
            if release:self.cache.clear();self.cache_bytes=0
            now=time.monotonic()
            for key,(clip,expiry) in list(self.cache.items()):
                if now>=expiry:self.cache_bytes-=len(clip);del self.cache[key]
            if not item:time.sleep(.025);continue
            generation,seq,event=item
            try:
                if event not in self.index:raise ValueError('Banco/receta no disponible')
                cached=self.cache.pop(event,None)
                if cached:self.cache_bytes-=len(cached[0])
                clip=cached[0] if cached else self._decode(self.index[event])
                while self.cache and self.cache_bytes+len(clip)>24*1024*1024:
                    _,(old,_)=self.cache.popitem(last=False);self.cache_bytes-=len(old)
                self.cache[event]=(clip,now+300);self.cache_bytes+=len(clip)
                with self.lock:
                    if generation==self.generation:self.result=(seq,event,clip)
            except Exception as exc:
                with self.lock:
                    if generation==self.generation:self.error=str(exc)
    def close(self):
        self.closed=True;self.cancel()
        if hasattr(self,'thread'):self.thread.join(timeout=9)
        self.cache.clear();self.cache_bytes=0
