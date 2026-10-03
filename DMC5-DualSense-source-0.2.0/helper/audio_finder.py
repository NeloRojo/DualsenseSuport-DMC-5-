"""Development audio finder: original sources, persistent fingerprints, RAM auditions.

The index contains identifiers and lossy numeric features, never decoded audio.
Search and preparation run off the controller loop. An audition is decoded only
when needed, and confirmations persist source/trim/layer metadata for development.
"""
import io,json,sqlite3,threading,time,wave,zlib,hashlib,math
from contextlib import contextmanager
from pathlib import Path
from audio_sources import Sources,source_rows,MAX_AUDIO_SECONDS

VERSION=1

@contextmanager
def connect(path):
    db=sqlite3.connect(path,timeout=20)
    db.execute('PRAGMA journal_mode=WAL');db.execute('PRAGMA synchronous=NORMAL')
    db.execute('CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY,value TEXT)')
    db.execute('CREATE TABLE IF NOT EXISTS samples (key TEXT PRIMARY KEY,source TEXT,kind TEXT,state TEXT,digest TEXT,canonical TEXT,duration REAL,frames INTEGER,features BLOB,vector BLOB,error TEXT)')
    db.execute('CREATE TABLE IF NOT EXISTS choices (id INTEGER PRIMARY KEY,created REAL,label TEXT,destination TEXT,layers TEXT)')
    old=db.execute("SELECT value FROM meta WHERE key='version'").fetchone()
    if old and int(old[0])!=VERSION:raise ValueError('Indice incompatible; usa una nueva ruta de indice')
    db.execute('INSERT OR REPLACE INTO meta VALUES (?,?)',('version',str(VERSION)));db.commit()
    try:
        with db:yield db
    finally:db.close()

class AudioFinder:
    def __init__(self,bridge):
        self.config=None;self.lock=threading.RLock();self.cancelled=threading.Event();self.thread=None;self.closed=False;self.generation=0
        self.reader=None;self.result=None;self.rows=[];self.layers=[];self.query_pcm=b'';self.query_range=[0,0]
        self.state='sin preparar';self.error='';self.message='';self.done=0;self.total=0;self.failed=0;self.valid=0;self.current='';self.operation='';self.container_errors=0;self.choices=[]
        try:
            config=json.loads((Path(bridge)/'audio_finder_runtime.json').read_text(encoding='utf-8-sig'))
            for key in ('game','list','decoder','index'):config[key]=str(Path(config[key]).resolve())
            if not Path(config['decoder']).is_file() or not Path(config['list']).is_file() or not Path(config['game']).is_dir():raise ValueError('Faltan las fuentes originales o el decodificador')
            self.config=config;self.reader=Sources(config['decoder']);Path(config['index']).parent.mkdir(parents=True,exist_ok=True)
            with connect(config['index']) as db:self._counts(db);self._choices(db)
            self.state='lista' if self.valid else 'sin preparar'
        except (OSError,ValueError,KeyError,sqlite3.Error) as exc:self.error=str(exc)
    def _counts(self,db):
        counts=dict(db.execute('SELECT state,count(*) FROM samples GROUP BY state').fetchall())
        self.valid=counts.get('ready',0);self.failed=counts.get('error',0);self.done=self.valid+self.failed+counts.get('duplicate',0);self.total=sum(counts.values())
        errors=db.execute("SELECT value FROM meta WHERE key='catalog_errors'").fetchone()
        self.container_errors=len(json.loads(errors[0])) if errors else 0
    def _choices(self,db):
        self.choices=[dict(id=i,label=label,destination=destination) for i,label,destination in db.execute('SELECT id,label,destination FROM choices ORDER BY id DESC LIMIT 20')]
    def load_choice(self,identity):
        if self.thread and self.thread.is_alive():raise ValueError('Espera a que termine la tarea activa')
        with connect(self.config['index']) as db:row=db.execute('SELECT layers FROM choices WHERE id=?',(int(identity),)).fetchone()
        if not row:raise ValueError('Seleccion no encontrada')
        with self.lock:self.layers=json.loads(row[0])
    def retry(self,include_other=False):
        if self.thread and self.thread.is_alive():raise ValueError('Primero pausa la tarea activa')
        with connect(self.config['index']) as db:db.execute("UPDATE samples SET state='pending',error=NULL WHERE state='error'");db.commit()
        self.prepare(include_other)
    def _check(self,generation):
        if self.closed or self.cancelled.is_set() or generation!=self.generation:raise InterruptedError()
    def _launch(self,operation,fn):
        if not self.config:raise ValueError(self.error or 'Buscador no disponible')
        with self.lock:
            if self.thread and self.thread.is_alive():raise ValueError('Hay una tarea activa; espera o pulsa Pausar')
            self.generation+=1;generation=self.generation;self.cancelled.clear();self.error='';self.message='';self.result=None;self.operation=operation;self.state=operation
        def work():
            try:fn(generation)
            except InterruptedError:
                with self.lock:self.state='pausada';self.message='Puedes continuar sin repetir lo terminado.'
            except Exception as exc:
                with self.lock:self.state='error';self.error=str(exc)
            finally:
                self.reader.clear()
                with self.lock:self.operation='';self.current=''
        self.thread=threading.Thread(target=work,daemon=True);self.thread.start()
    def prepare(self,include_other=False,workers=1):self._launch('preparando indice',lambda g:self._index(g,include_other,max(1,min(4,int(workers)))))
    def _index(self,generation,include_other=False,workers=1):
        import numpy as np
        from audio_fingerprint import mono,spectrum,vector
        with connect(self.config['index']) as db:
            # Fast PAK inventory metadata avoids reparsing unchanged archives.
            stamp=json.dumps([(p.name,p.stat().st_size,p.stat().st_mtime_ns) for p in sorted(Path(self.config['game']).glob('*.pak'))])
            old=db.execute("SELECT value FROM meta WHERE key='game_stamp'").fetchone()
            catalog_version=db.execute("SELECT value FROM meta WHERE key='catalog_version'").fetchone()
            if not old or old[0]!=stamp or catalog_version!=('2',):
                self.current='Localizando muestras internas y audio externo';seen=[];errors=[]
                for key,source,error in source_rows(self.config['game'],self.config['list'],self.reader,self.cancelled):
                    self._check(generation)
                    if not source:errors.append({'resource':key,'error':error});continue
                    seen.append(key)
                    db.execute('INSERT OR IGNORE INTO samples(key,source,kind,state) VALUES (?,?,?,?)',(key,json.dumps(source),source['category'],'pending'))
                self._check(generation)
                db.execute('CREATE TEMP TABLE seen(key TEXT PRIMARY KEY)');db.executemany('INSERT INTO seen VALUES (?)',((s,) for s in seen))
                db.execute('DELETE FROM samples WHERE key NOT IN (SELECT key FROM seen)')
                for k,v in (('game_stamp',stamp),('catalog_errors',json.dumps(errors)),('catalog_version','2')):db.execute('INSERT OR REPLACE INTO meta VALUES (?,?)',(k,v))
                db.commit()
            pending=db.execute("SELECT key,source FROM samples WHERE state='pending'"+('' if include_other else " AND kind='effects'")+" ORDER BY kind,source").fetchall()
            digests={digest:(key,duration) for key,digest,duration in db.execute("SELECT key,digest,duration FROM samples WHERE state='ready'")}
            self._counts(db)
            from concurrent.futures import ThreadPoolExecutor
            pool=ThreadPoolExecutor(max_workers=workers);jobs=[]
            def decode_features(source,encoded):
                reader=Sources(self.config['decoder'])
                pcm,rate,channels=reader.decode(source,self.cancelled,encoded)
                self._check(generation);x=mono(pcm,rate,channels)
                if len(x)<120 or float(np.max(np.abs(x)))<1e-5:raise ValueError('Muestra silenciosa o demasiado corta')
                spec=spectrum(x);return len(x)/12000,len(spec),zlib.compress(np.round(spec*255).astype('uint8').tobytes()),vector(spec).tobytes()
            def finish_jobs():
                for key,digest,future in jobs:
                    self._check(generation)
                    try:
                        duration,frames,features,v=future.result()
                        if digest in digests:
                            canonical,duration=digests[digest]
                            db.execute("UPDATE samples SET state='duplicate',digest=?,canonical=?,duration=? WHERE key=?",(digest,canonical,duration,key))
                        else:
                            db.execute("UPDATE samples SET state='ready',digest=?,duration=?,frames=?,features=?,vector=?,error=NULL WHERE key=?",(digest,duration,frames,features,v,key));digests[digest]=(key,duration)
                    except Exception as exc:
                        self._check(generation);db.execute("UPDATE samples SET state='error',error=? WHERE key=?",(str(exc),key))
                jobs.clear();db.commit();self._counts(db)
            try:
              for i,(key,text) in enumerate(pending):
                self._check(generation);source=json.loads(text);self.current=Path(source['name']).name
                try:
                    digest=hashlib.sha256(self.reader.encoded(source)).hexdigest()
                    if digest in digests:
                        canonical,duration=digests[digest]
                        db.execute("UPDATE samples SET state='duplicate',digest=?,canonical=?,duration=? WHERE key=?",(digest,canonical,duration,key))
                    else:
                        jobs.append((key,digest,pool.submit(decode_features,source,self.reader.encoded(source))))
                except InterruptedError:raise
                except Exception as exc:
                    self._check(generation);db.execute("UPDATE samples SET state='error',error=? WHERE key=?",(str(exc),key))
                if len(jobs)>=workers*2:finish_jobs()
                if i%25==0:db.commit();self._counts(db)
                # Keep preparation from saturating a core while the game is open.
                self.cancelled.wait(.003)
              finish_jobs()
            finally:pool.shutdown(wait=True,cancel_futures=True)
            db.commit();self._counts(db)
        self.state='lista';self.message='Indice preparado. Las muestras no compatibles quedan contadas, no se ocultan.'
    def search(self,pcm,start,end,include_other=False,deep=False,max_duration=None):
        start=float(start);end=float(end);duration=len(pcm)/192000
        if not 0<=start<end<=duration+.001 or end-start<.08:raise ValueError('Selecciona al menos 80 ms dentro de la captura')
        maximum=end-start if max_duration is None else float(max_duration)
        if not math.isfinite(maximum) or not 0<=maximum<=MAX_AUDIO_SECONDS:raise ValueError('Duracion maxima de candidatos: 0 a 30 segundos')
        with self.lock:self.query_pcm=pcm[int(start*48000)*4:int(end*48000)*4];self.query_range=[start,end];self.rows=[];self.layers=[]
        self._launch('buscando',lambda g:self._search(g,include_other,deep,maximum))
    def _search(self,generation,include_other,deep,maximum):
        import numpy as np
        from audio_fingerprint import mono,spectrum,vector,spectral_match,waveform_match,contrast
        query=mono(self.query_pcm,48000,2)
        if np.sqrt(np.mean(query*query))<1e-5:raise ValueError('El recorte esta en silencio; elige otra parte')
        spec=contrast(spectrum(query))
        with connect(self.config['index']) as db:
            sql="SELECT key,source,duration,vector FROM samples WHERE state='ready'"+('' if include_other else " AND kind='effects'")
            entries=db.execute(sql+(' AND duration<=?' if maximum else ''),(maximum+.001,) if maximum else ()).fetchall()
            if not entries:
                if maximum and db.execute(sql+' LIMIT 1').fetchone():raise ValueError('No hay sonidos dentro de esta duracion. Amplia el limite o permite sonidos mas largos.')
                raise ValueError('Primero prepara el indice de sonidos')
            # Scan all indexed spectra: a coarse timbre shortlist can drop the
            # desired layer when a voice/noise dominates a mixed reference.
            chosen=range(len(entries));matches=[]
            self.total=len(chosen);self.done=0
            for i,j in enumerate(chosen):
                self._check(generation);key,text,duration,_=entries[j]
                frames,blob=db.execute('SELECT frames,features FROM samples WHERE key=?',(key,)).fetchone()
                candidate=contrast(np.frombuffer(zlib.decompress(blob),dtype=np.uint8).reshape(frames,24).astype(np.float32)/255)
                score,offset,inside=spectral_match(spec,candidate)
                overlap=min(duration,len(query)/12000)/(len(query)/12000)
                rank=score*(.65+.35*overlap**.5)
                matches.append(dict(key=key,source=json.loads(text),duration=round(duration,3),similarity=score,spectral_rank=rank,offset=offset,inside=inside,correlation=0.0))
                self.done=i+1
            matches.sort(key=lambda r:r['spectral_rank'],reverse=True)
            # Refine the closest originals. Correlation can identify a source
            # inside a mixture, while spectral matching tolerates altered pitch.
            for i,row in enumerate(matches[:400 if deep else 120]):
                self._check(generation);self.current='Comprobando candidato '+str(i+1)
                try:
                    pcm,rate,ch=self.reader.decode(row['source'],self.cancelled);x=mono(pcm,rate,ch)
                    corr,offset,inside=waveform_match(query,x)
                    row['correlation']=corr
                    if corr>.25:row['offset']=offset;row['inside']=inside
                except Exception:
                    self._check(generation)
            # High waveform confidence outranks merely similar spectral timbre.
            for row in matches:row['score']=max(row['spectral_rank']*.75,row['correlation'])
            matches.sort(key=lambda r:r['score'],reverse=True)
            with self.lock:self._check(generation);self.rows=matches[:80]
        self.state='resultados';self.message='Son candidatos, no coincidencias garantizadas. Escucha antes de elegir.'
    def _row(self,key):
        row=next((r for r in self.rows if r['key']==key),None)
        if not row:raise ValueError('Resultado antiguo; vuelve a buscar')
        return row
    def reject(self,key):
        with self.lock:self._row(key)['rejected']=True
    def layer(self,key,start=0,end=None,offset=0,gain=1):
        row=self._row(key);start=float(start);end=float(end if end is not None else row['duration']);offset=float(offset);gain=float(gain)
        if not 0<=start<end<=row['duration']+.001 or not 0<=offset<=30 or not 0<=gain<=2:raise ValueError('Recorte o mezcla fuera de limites')
        with self.lock:
            if len(self.layers)>=6:raise ValueError('Maximo seis capas por efecto')
            self.layers.append(dict(key=key,source=row['source'],start=start,end=end,offset=offset,gain=gain))
    def clear_layers(self):
        with self.lock:self.layers=[]
    def audition(self,seq,key=None,start=0,end=None,mix=False,gain=1):
        gain=float(gain)
        if not 0<=gain<=1:raise ValueError('Volumen permitido: 0..100%')
        if mix:
            with self.lock:layers=list(self.layers)
            if not layers:raise ValueError('Agrega al menos una capa')
        else:
            row=self._row(key);start=float(start);end=float(end if end is not None else row['duration'])
            if not 0<=start<end<=row['duration']+.001:raise ValueError('Recorte del candidato fuera de limites')
            layers=[dict(key=key,source=row['source'],start=start,end=end,offset=0,gain=1)]
        def render(generation):
            import numpy as np
            from audio_fingerprint import stereo48
            pieces=[];length=0
            for layer in layers:
                self._check(generation);pcm,rate,ch=self.reader.decode(layer['source'],self.cancelled)
                stereo=stereo48(pcm,rate,ch);clip=np.frombuffer(stereo,dtype='<i2').reshape(-1,2).astype(np.float32)
                clip=clip[int(layer['start']*48000):int(layer['end']*48000)]
                at=int(layer['offset']*48000)
                if at+len(clip)>30*48000:raise ValueError('La mezcla supera 30 segundos')
                pieces.append((at,clip*layer['gain']));length=max(length,at+len(clip))
            out=np.zeros((length,2),dtype=np.float32)
            for at,clip in pieces:out[at:at+len(clip)]+=clip
            peak=float(np.max(np.abs(out))) if len(out) else 0
            if peak>0:out*=30000/max(peak,1)
            out*=gain
            # Short audition fades prevent a trim boundary click.
            fade=min(240,len(out)//2)
            if fade:out[:fade]*=np.linspace(0,1,fade)[:,None];out[-fade:]*=np.linspace(1,0,fade)[:,None]
            with self.lock:self._check(generation);self.result=(seq,np.clip(out,-32768,32767).astype('<i2').tobytes())
            self.state='resultados'
        self._launch('preparando escucha',render)
    def confirm(self,label,destination,key=None,start=0,end=None):
        if self.thread and self.thread.is_alive():raise ValueError('Espera a que termine la tarea activa')
        if destination not in ('haptics','speaker','both'):raise ValueError('Destino no valido')
        if key:
            row=self._row(key);start=float(start);end=float(end if end is not None else row['duration'])
            if not 0<=start<end<=row['duration']+.001:raise ValueError('Recorte fuera de limites')
            layers=[dict(key=key,source=row['source'],start=start,end=end,offset=0,gain=1)]
        else:layers=list(self.layers)
        if not layers:raise ValueError('Primero elige un sonido o mezcla')
        label=str(label).strip()[:100]
        if not label:raise ValueError('Escribe el nombre de la habilidad')
        with connect(self.config['index']) as db:
            cur=db.execute('INSERT INTO choices(created,label,destination,layers) VALUES (?,?,?,?)',(time.time(),label,destination,json.dumps(layers)));db.commit();identity=cur.lastrowid;self._choices(db)
        self.message='Seleccion '+str(identity)+' guardada: '+label+'. Lista para integrar al mod; aun no cambia el gameplay.'
        return identity
    def poll(self):
        with self.lock:result=self.result;self.result=None;return result
    def pause(self):self.cancelled.set();self.reader and self.reader.cancel()
    def status(self):
        with self.lock:
            return dict(available=bool(self.config),state=self.state,busy=bool(self.thread and self.thread.is_alive()),operation=self.operation,
                done=self.done,total=self.total,indexed=self.valid,failed=self.failed,container_errors=self.container_errors,choices=list(self.choices),current=self.current,error=self.error,message=self.message,
                layers=[dict(key=l['key'],start=l['start'],end=l['end'],offset=l['offset'],gain=l['gain']) for l in self.layers],
                results=[dict(key=r['key'],name=Path(r['source']['name']).name,media=r['source']['media_id'],duration=r['duration'],
                    score=round(r['score'],3),correlation=round(r['correlation'],3),similarity=round(r['similarity'],3),offset=round(r['offset'],3),inside=r['inside'],rejected=r.get('rejected',False)) for r in self.rows])
    def close(self):
        self.closed=True;self.generation+=1;self.pause()
        if self.thread:self.thread.join(timeout=10)
        self.query_pcm=b'';self.result=None
