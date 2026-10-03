"""Event-driven USB haptics and optional internal-speaker audio.

Uses sounddevice/PortAudio WASAPI behind a small output interface.
No desktop loopback or microphone capture.
"""
import array
import io
import math
import threading
import wave
import zipfile
from pathlib import Path

RATE = 48000
MAX_GAIN = .8
MAX_SPEAKER_GAIN = 1.0

def wav_source(filename, root):
    """Load a local WAV or a bounded pack member without extracting to disk."""
    root = Path(root).resolve()
    path = (root/filename).resolve()
    if not path.is_relative_to(root):
        raise ValueError('Audio WAV must be inside the profile directory')
    # Loose files allow replacing an individual sound during development.
    if path.is_file(): return str(path)
    member = path.relative_to(root).as_posix()
    try:
        with zipfile.ZipFile(root/'audio.dmcpack') as pack:
            entries = [item for item in pack.infolist() if item.filename == member]
            if len(entries) != 1: raise ValueError(f'Missing or duplicate packed WAV: {member}')
            entry = entries[0]
            if not 0 < entry.file_size <= RATE*10*2*2+65536:
                raise ValueError('Packed WAV too large or empty')
            return io.BytesIO(pack.read(entry))
    except zipfile.BadZipFile as exc:
        raise ValueError('Invalid audio pack') from exc

def devices():
    import sounddevice as sd
    apis = sd.query_hostapis()
    return [(i, d) for i, d in enumerate(sd.query_devices())
            if apis[d['hostapi']]['name'] == 'Windows WASAPI'
            and d['max_output_channels'] == 4
            and ('dualsense' in d['name'].lower() or 'wireless controller' in d['name'].lower())]

def gain(value, target="haptics"):
    maximum = MAX_SPEAKER_GAIN if target == "speaker" else MAX_GAIN
    if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= maximum:
        raise ValueError(f'{target} gain must be 0..{maximum}')
    return value

def render(spec, root, target="haptics"):
    """Float32 quad: haptics on rear L/R, optional speaker on front-right."""
    if target not in ("haptics", "speaker"): raise ValueError("Audio target")
    max_freq = 8000 if target == "speaker" else 350
    amplitude = gain(spec.get('gain', .15), target)
    out = array.array('f')
    if 'file' in spec:
        with wave.open(wav_source(spec['file'], root), 'rb') as wav:
            channels = wav.getnchannels()
            if channels not in (1, 2) or wav.getsampwidth() != 2 or wav.getframerate() != RATE:
                raise ValueError('Use 48kHz PCM16 mono/stereo WAV')
            count = wav.getnframes()
            limit_ms = spec.get('max_duration_ms', 2000)
            if target == 'haptics' and (type(limit_ms) is not int or not 1 <= limit_ms <= 10000):
                raise ValueError('Haptic WAV duration limit must be 1..10000 ms')
            max_seconds = 10 if target == "speaker" else limit_ms/1000
            if not 0 < count <= RATE*max_seconds: raise ValueError(f'{target} WAV must be <={max_seconds} seconds')
            pcm = array.array('h', wav.readframes(count))
        for i in range(count):
            # Short edge fades avoid clicks; preserve source waveform between them.
            fade = min(1, i/240, (count-1-i)/240)
            left = pcm[i*channels]/32768*amplitude*fade
            right = pcm[i*channels+channels-1]/32768*amplitude*fade
            out.extend((0, (left+right)/2, 0, 0) if target == "speaker" else (0, 0, left, right))
    else:
        segments = spec.get('segments', [spec])
        if not isinstance(segments, list) or not 1 <= len(segments) <= 16: raise ValueError('segments')
        total = 0
        for part in segments:
            ms = part.get('duration_ms', 150)
            if type(ms) is not int or not 1 <= ms <= 2000: raise ValueError('Audio duration')
            total += ms
            if total > 2000: raise ValueError('Audio pattern must be <=2 seconds')
            freq = part.get('frequency_hz', [90, 160])
            if len(freq) != 2 or any(type(f) not in (int, float) or not math.isfinite(f) or not 0 <= f <= max_freq for f in freq): raise ValueError(f'Audio frequencies 0..{max_freq}Hz')
            count = round(RATE*ms/1000)
            sweep = part.get('sweep_hz', freq)
            if len(sweep)!=2 or any(type(f) not in (int,float) or not math.isfinite(f) or not 0<=f<=max_freq for f in sweep): raise ValueError('Audio sweep')
            for i in range(count):
                t = i/RATE
                fade = min(1, i/240, (count-1-i)/480)
                decay = math.exp(-4*i/count) if part.get('decay', False) else 1
                values = [amplitude*fade*decay*math.sin(2*math.pi*(f*t+.5*(s-f)/(count/RATE)*t*t)) for f,s in zip(freq,sweep)]
                out.extend((0, sum(values)/2, 0, 0) if target == "speaker" else (0, 0, *values))
    return out.tobytes()

class AudioHapticsOutput:
    def __init__(self, device=None):
        import sounddevice as sd
        available = devices()
        if device is None:
            if len(available) != 1: raise RuntimeError(f'Expected one DualSense WASAPI endpoint; found {len(available)}. Use --audio-device.')
            device = available[0][0]
        if device not in [i for i,_ in available]: raise RuntimeError('Selected endpoint is not a four-channel DualSense WASAPI device')
        self.info = sd.query_devices(device)
        sd.check_output_settings(device=device, channels=4, dtype='float32', samplerate=RATE)
        self.lock = threading.Lock()
        self.haptics_enabled = True; self.speaker_enabled = True
        self.clip = b''; self.position = 0; self.loop = False; self.underruns = 0; self.error = ''
        self.stream = sd.RawOutputStream(device=device, samplerate=RATE, channels=4, dtype='float32', blocksize=480,
                                        latency='low', extra_settings=sd.WasapiSettings(exclusive=False), callback=self._callback)
        self.stream.start()

    def _callback(self, outdata, frames, timing, status):
        if status.output_underflow: self.underruns += 1
        size = frames*16
        try:
            with self.lock:
                chunks = []
                remaining = size
                while remaining and self.clip:
                    chunk = self.clip[self.position:self.position+remaining]
                    chunks.append(chunk); self.position += len(chunk); remaining -= len(chunk)
                    if self.position >= len(self.clip):
                        if self.loop: self.position = 0
                        else: break
                chunk = b''.join(chunks)
                speaker_clip = getattr(self, 'speaker_clip', b'')
                speaker_position = getattr(self, 'speaker_position', 0)
                voice_parts=[]; remaining_voice=size
                while remaining_voice and speaker_clip:
                    part=speaker_clip[speaker_position:speaker_position+remaining_voice]
                    voice_parts.append(part); speaker_position+=len(part); remaining_voice-=len(part)
                    if speaker_position>=len(speaker_clip):
                        if getattr(self,'speaker_loop',False): speaker_position=getattr(self,'speaker_loop_start',0)
                        else: break
                voice=b''.join(voice_parts)
                self.speaker_position=speaker_position
                overlay_clip=getattr(self,'speaker_overlay',b'')
                overlay_position=getattr(self,'speaker_overlay_position',0)
                overlay=overlay_clip[overlay_position:overlay_position+size]
                self.speaker_overlay_position=overlay_position+len(overlay)
                cue_clip=getattr(self,'speaker_cue',b'')
                cue_position=getattr(self,'speaker_cue_position',0)
                cue=cue_clip[cue_position:cue_position+size]
                self.speaker_cue_position=cue_position+len(cue)
            samples = array.array("f", chunk + bytes(size-len(chunk)))
            if speaker_clip:
                speaker_samples = array.array('f', voice+bytes(size-len(voice)))
                for i in range(1,len(samples),4): samples[i]=speaker_samples[i]
            if overlay or cue:
                foreground=array.array('f',overlay+bytes(size-len(overlay)))
                notice=array.array('f',cue+bytes(size-len(cue)))
                base_active=any(samples[1::4])
                if overlay and cue: base_gain,cue_gain,dt_gain=.15,.25,.55
                elif overlay: base_gain,cue_gain,dt_gain=.25,0,.7 if base_active else 1.0
                else: base_gain,cue_gain,dt_gain=.25,.7 if base_active else 1.0,0
                for i in range(1,len(samples),4):
                    samples[i]=samples[i]*base_gain+notice[i]*cue_gain+foreground[i]*dt_gain
            scale=getattr(self,"haptic_scale",1.0)
            if scale!=1.0:
                for i in range(2,len(samples),4): samples[i]*=scale; samples[i+1]*=scale
            if not getattr(self,"haptics_enabled",True):
                for i in range(2,len(samples),4): samples[i]=0; samples[i+1]=0
            if not getattr(self,"speaker_enabled",True):
                for i in range(1,len(samples),4): samples[i]=0
            outdata[:] = bytes(size) if getattr(self,'game_paused',False) else samples.tobytes()
        except Exception as exc:
            self.error = str(exc)
            outdata[:] = bytes(size)

    def play(self, clip, loop=False):
        with self.lock:
            self.clip = b'' if getattr(self,'game_paused',False) else clip; self.position = 0; self.loop = loop and bool(self.clip)
            self.speaker_clip = b''; self.speaker_position = 0; self.speaker_loop=False
            self.speaker_overlay=b''; self.speaker_overlay_position=0
            self.speaker_cue=b''; self.speaker_cue_position=0

    def set_haptic_scale(self,value):
        self.haptic_scale=max(0,min(1,float(value)))

    def play_haptics(self, clip, loop=False):
        """Replace the actuator track while the speaker keeps its cursor."""
        with self.lock: self.clip=b'' if getattr(self,'game_paused',False) else clip; self.position=0; self.loop=loop and bool(self.clip)

    def play_speaker(self, clip, loop=False, loop_start_ms=0):
        """Replace only the internal-speaker track."""
        if type(loop_start_ms) not in (int,float) or not math.isfinite(loop_start_ms) or not 0<=loop_start_ms<len(clip)/16/RATE*1000: raise ValueError('Speaker loop start outside clip')
        with self.lock:
            self.speaker_clip=b'' if getattr(self,'game_paused',False) else clip
            self.speaker_position=0;self.speaker_loop=loop and bool(self.speaker_clip)
            self.speaker_loop_start=round(loop_start_ms*RATE/1000)*16

    def play_speaker_overlay(self, clip):
        """DT transitions leave the technique, its loop and cursor intact."""
        with self.lock:
            self.speaker_overlay=b'' if getattr(self,'game_paused',False) else clip
            self.speaker_overlay_position=0

    def play_speaker_cue(self, clip):
        """Charge-level notices preserve the background and DT transition clocks."""
        with self.lock:
            self.speaker_cue=b'' if getattr(self,'game_paused',False) else clip
            self.speaker_cue_position=0

    def set_game_paused(self, paused):
        """Discard all controller tracks; unpausing never restores discarded audio."""
        with self.lock:
            self.game_paused=paused
            if paused:
                cancelled=any(getattr(self,name,b'') for name in ('clip','speaker_clip','speaker_overlay','speaker_cue'))
                self.clip=b'';self.position=0;self.loop=False;self.haptic_scale=1.0
                self.speaker_clip=b'';self.speaker_position=0;self.speaker_loop=False
                self.speaker_overlay=b'';self.speaker_overlay_position=0
                self.speaker_cue=b'';self.speaker_cue_position=0
                return cancelled
        return False

    def stop_speaker_cue(self):
        with self.lock: self.speaker_cue=b''; self.speaker_cue_position=0

    def stop_speaker(self):
        with self.lock: self.speaker_clip=b''; self.speaker_position=0; self.speaker_loop=False

    def stop_haptics(self):
        with self.lock: self.clip=b''; self.position=0; self.loop=False

    def set_channels(self, haptics=True, speaker=True):
        with self.lock: self.haptics_enabled=haptics; self.speaker_enabled=speaker

    def stop(self):
        with self.lock:
            self.clip = b''; self.position = 0; self.loop = False
            self.speaker_clip = b''; self.speaker_position = 0; self.speaker_loop=False
            self.speaker_overlay=b''; self.speaker_overlay_position=0
            self.speaker_cue=b''; self.speaker_cue_position=0

    def close(self):
        self.stop(); self.stream.stop(); self.stream.close()


def mix(haptics=None, speaker=None):
    """Disjoint channels: speaker FR, actuators rear L/R; no clipping addition."""
    a=array.array("f",haptics or b""); b=array.array("f",speaker or b"")
    a.extend([0.]*(max(len(a),len(b))-len(a)))
    for i in range(1,len(b),4): a[i]=b[i]
    return a.tobytes()
