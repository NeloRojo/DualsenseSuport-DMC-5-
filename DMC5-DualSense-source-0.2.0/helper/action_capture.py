"""Developer process-only audio capture and trimmed speaker auditions in RAM."""
import array,io,json,math,subprocess,threading,time,wave
from pathlib import Path
from bank_preview import pcm_speaker

class ActionCapture:
    def __init__(self,bridge,pid):
        self.pid=pid;self.recorder=None;self.proc=None;self.thread=None;self.closed=False
        self.lock=threading.Lock();self.generation=0;self.result=None;self.pcm=b''
        self.state='no disponible';self.error='';self.started=0;self.seconds=15;self.preview_seq=None;self.preview_thread=None
        try:
            path=Path(json.loads((Path(bridge)/'audio_capture_runtime.json').read_text(encoding='utf-8-sig'))['recorder']).resolve()
            if pid and path.is_file():self.recorder=path;self.state='sin captura'
        except (OSError,KeyError,ValueError,TypeError):pass
    def start(self,seconds=15):
        seconds=int(seconds)
        if not 3<=seconds<=30:raise ValueError('Duracion permitida: 3 a 30 segundos')
        with self.lock:
            if not self.recorder:raise ValueError('Capturador no disponible')
            if self.state in ('preparando','grabando'):raise ValueError('Ya hay una captura activa')
            self.generation+=1;generation=self.generation;self.pcm=b'';self.result=None;self.preview_seq=None
            self.seconds=seconds;self.state='preparando';self.error=''
        self.thread=threading.Thread(target=self._capture,args=(generation,seconds),daemon=True);self.thread.start()
    def _capture(self,generation,seconds):
        proc=None
        try:
            proc=subprocess.Popen([str(self.recorder),str(self.pid),str(seconds),'-'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            with self.lock:
                if self.closed or generation!=self.generation:proc.kill();return
                self.proc=proc
            timer=threading.Timer(seconds+8,lambda:proc.kill() if proc.poll() is None else None);timer.start()
            try:
                ready=proc.stderr.readline().decode(errors='replace').strip()
                if ready!='CAPTURE_READY':raise ValueError(ready or 'No pudo iniciarse WASAPI')
                with self.lock:
                    if generation==self.generation:self.state='grabando';self.started=time.monotonic()
                raw=proc.stdout.read(30*192000+65536);error=proc.stderr.read(4096).decode(errors='replace');proc.wait()
                if proc.returncode:raise ValueError(error or 'Captura interrumpida')
                with wave.open(io.BytesIO(raw)) as w:
                    if (w.getframerate(),w.getnchannels(),w.getsampwidth())!=(48000,2,2):raise ValueError('PCM inesperado')
                    pcm=w.readframes(min(w.getnframes(),30*48000))
                if not pcm:raise ValueError('Captura vacia')
                with self.lock:
                    if generation==self.generation:self.pcm=pcm;self.state='lista'
            finally:timer.cancel()
        except Exception as exc:
            with self.lock:
                if generation==self.generation:self.error=str(exc);self.state='error'
        finally:
            if proc:
                if proc.poll() is None:proc.kill()
                proc.wait()
                for stream in (proc.stdin,proc.stdout,proc.stderr):stream.close()
            with self.lock:
                if self.proc is proc:self.proc=None
    def stop(self):
        with self.lock:proc=self.proc
        if proc and proc.poll() is None:
            try:proc.stdin.write(b's');proc.stdin.flush()
            except (OSError,ValueError):pass
    def preview(self,seq,start=0,end=None,mode='speaker'):
        if mode not in ('pc','speaker','haptics','both'):raise ValueError('Destino de prueba no valido')
        with self.lock:
            if self.preview_thread and self.preview_thread.is_alive():raise ValueError('Preparando la prueba anterior; espera un momento')
            if not self.pcm:raise ValueError('Primero termina una captura')
            duration=len(self.pcm)/192000;end=duration if end is None else float(end);start=float(start)
            if not 0<=start<end<=duration+.001:raise ValueError('Recorte fuera de la captura')
            pcm=self.pcm[int(start*48000)*4:int(end*48000)*4];generation=self.generation
            self.preview_seq=seq;self.result=None
        def render():
            try:
                if mode=='pc':
                    with self.lock:
                        if not self.closed and generation==self.generation and seq==self.preview_seq:self.result=(seq,'preview_capture_play',pcm,mode)
                    return
                data=io.BytesIO()
                with wave.open(data,'wb') as w:w.setparams((2,2,48000,0,'NONE','not compressed'));w.writeframes(pcm)
                clip=pcm_speaker(data.getvalue(),max_seconds=30)
                if mode!='speaker':
                    samples=array.array('f');samples.frombytes(clip)
                    low=0;slow=0;filtered=[]
                    fast_a=1-math.exp(-2*math.pi*180/48000);slow_a=1-math.exp(-2*math.pi*30/48000)
                    for x in samples[1::4]:
                        low+=fast_a*(x-low);slow+=slow_a*(x-slow);filtered.append(low-slow)
                    gain=.35/max(max((abs(x) for x in filtered),default=0),.01)
                    for i,x in enumerate(filtered):
                        fade=min(1,i/960,(len(filtered)-1-i)/960)
                        value=math.tanh(x*gain)*fade
                        samples[i*4+2]=value;samples[i*4+3]=value
                        if mode=='haptics':samples[i*4+1]=0
                    clip=samples.tobytes()
                with self.lock:
                    if not self.closed and generation==self.generation and seq==self.preview_seq:self.result=(seq,'preview_capture_play',clip,mode)
            except Exception as exc:
                with self.lock:self.error=str(exc)
        self.preview_thread=threading.Thread(target=render,daemon=True);self.preview_thread.start()
    def poll(self):
        with self.lock:result=self.result;self.result=None;return result
    def status(self):
        with self.lock:return dict(available=bool(self.recorder),state=self.state,duration=round(len(self.pcm)/192000,3),elapsed=round(max(0,time.monotonic()-self.started),1) if self.state=='grabando' else 0,limit=self.seconds,preview_busy=bool(self.preview_thread and self.preview_thread.is_alive()),error=self.error)
    def release(self):
        self.stop()
        with self.lock:self.generation+=1;self.pcm=b'';self.result=None;self.preview_seq=None;self.state='sin captura' if self.recorder else 'no disponible';self.error=''
    def close(self):
        self.closed=True;self.release()
        with self.lock:proc=self.proc
        if proc and proc.poll() is None:proc.kill()
        if self.thread:self.thread.join(timeout=2)
