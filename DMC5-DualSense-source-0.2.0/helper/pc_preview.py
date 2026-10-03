"""Asynchronous PCM auditions through the PC's default output, never microphone."""
import array,threading,time,sys

class PCPreview:
    def __init__(self):
        self.lock=threading.Lock();self.closed=False;self.pending=None;self.clip=b'';self.position=0
        self.generation=0;self.stream=None;self.error='';self.name='Salida predeterminada del PC'
        self.thread=threading.Thread(target=self._work,daemon=True);self.thread.start()
    def play(self,pcm,quad=False):
        with self.lock:self.generation+=1;self.pending=(self.generation,pcm,quad);self.error=''
    def _callback(self,outdata,frames,time_info,status):
        with self.lock:
            chunk=self.clip[self.position:self.position+frames*4];self.position+=len(chunk)
        outdata[:]=chunk+b'\0'*(frames*4-len(chunk))
    def _open(self):
        import sounddevice as sd
        device=sd.default.device[1];info=sd.query_devices(device)
        if 'dualsense' in info['name'].lower() or 'wireless controller' in info['name'].lower():raise ValueError('La salida predeterminada del PC es el mando; selecciona tus audifonos en Windows.')
        apis=sd.query_hostapis();devices=sd.query_devices();choices=[]
        def same_name(name):
            # MME can truncate names; use only the same default endpoint,
            # never arbitrary monitors, virtual cables or the controller.
            a=name.casefold();b=info['name'].casefold()
            return a==b or (len(b)>=20 and a.startswith(b))
        for api_name in ('Windows WASAPI','MME','Windows DirectSound'):
            for i,candidate in enumerate(devices):
                if candidate['max_output_channels']>=2 and apis[candidate['hostapi']]['name']==api_name and same_name(candidate['name']):choices.append((i,candidate,api_name))
        if not choices:raise ValueError('No hay salida compartida disponible para los audifonos seleccionados.')
        errors=[]
        for device,candidate,api in choices:
            stream=None
            try:
                settings=sd.WasapiSettings(exclusive=False,auto_convert=True) if api=='Windows WASAPI' else None
                stream=sd.RawOutputStream(device=device,samplerate=48000,channels=2,dtype='int16',blocksize=0,latency='high',extra_settings=settings,callback=self._callback)
                stream.start();self.stream=stream;self.name=candidate['name']+' / '+api;return
            except Exception as exc:
                errors.append(api+': '+str(exc))
                if stream:
                    try:stream.close()
                    except Exception:pass
        raise RuntimeError('No se pudo abrir la salida del PC. '+' | '.join(errors))
    def _work(self):
        ole32=None
        if sys.platform=='win32':
            import ctypes
            api=ctypes.windll.ole32
            if api.CoInitializeEx(None,0)>=0:ole32=api
        try:
            while not self.closed:
                with self.lock:item=self.pending;self.pending=None
                if not item:time.sleep(.025);continue
                generation,pcm,quad=item
                try:
                    if quad:
                        source=array.array('f');source.frombytes(pcm);stereo=array.array('h')
                        for value in source[1::4]:
                            value=round(max(-1,min(1,value))*32767);stereo.extend((value,value))
                        pcm=stereo.tobytes()
                    if self.stream and hasattr(self.stream,'active') and not self.stream.active:
                        self.stream.close();self.stream=None
                    if not self.stream:self._open()
                    with self.lock:
                        if not self.closed and generation==self.generation:self.clip=pcm;self.position=0
                except Exception as exc:self.error=str(exc)
        finally:
            if self.stream:
                try:self.stream.close()
                except Exception:pass
                self.stream=None
            if ole32:ole32.CoUninitialize()
    def stop(self):
        with self.lock:self.generation+=1;self.pending=None;self.clip=b'';self.position=0
    def status(self):
        with self.lock:return dict(output=self.name,active=self.position<len(self.clip),error=self.error)
    def close(self):
        self.closed=True;self.stop();self.thread.join(timeout=2)
        if self.stream:self.stream.stop();self.stream.close()
