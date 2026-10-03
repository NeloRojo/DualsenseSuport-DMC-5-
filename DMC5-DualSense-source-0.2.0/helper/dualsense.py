"""USB DualSense transport. HIDAPI is isolated here; IMU values are uncalibrated."""
import struct
import sys
import time

def decode(report):
    b = bytes(report)
    if len(b) != 64 or b[0] != 1:
        raise ValueError('Expected full USB report 0x01 (64 bytes); Bluetooth unsupported')
    names = ('square','cross','circle','triangle','l1','r1','l2','r2','create','options','l3','r3','ps','touchpad','mute')
    bits = [(b[8] >> i) & 1 for i in range(4,8)] + [(b[9] >> i) & 1 for i in range(8)] + [(b[10] >> i) & 1 for i in range(3)]
    return dict(sticks=list(b[1:5]), triggers=list(b[5:7]), dpad=b[8]&15,
                buttons=dict(zip(names,map(bool,bits))), gyro_raw=struct.unpack_from('<hhh',b,16),
                accel_raw=struct.unpack_from('<hhh',b,22), battery_level=min(100,(b[53]&15)*10), charging_state=b[53]>>4)

def trigger_block(config):
    """Zone vibration encoding follows nowrep/dualsensectl trigger_bitpacking_array."""
    if config.get('mode')=='off':return bytes(11)
    if config.get('mode')=='feedback':
        start,strength=config['start'],config['strength']
        if not (type(start) is int and 0<=start<=9 and type(strength) is int and 1<=strength<=8):
            raise ValueError('Invalid zoned trigger resistance')
        zones=sum(1<<i for i in range(start,10))
        forces=sum((strength-1)<<(3*i) for i in range(start,10))
        return bytes([0x21])+zones.to_bytes(2,'little')+forces.to_bytes(4,'little')+bytes(4)
    if config.get('mode')=='resistance':
        if any(type(config.get(k)) is not int or not 0<=config[k]<=255 for k in ('start','force')):
            raise ValueError('Invalid trigger resistance')
        return bytes([1,config['start'],config['force']])+bytes(8)
    if config.get('mode')!='vibration': raise ValueError('Invalid trigger mode')
    start,strength,frequency=config['start'],config['strength'],config['frequency']
    if not (type(start) is int and 0<=start<=9 and type(strength) is int and 1<=strength<=8 and type(frequency) is int and 1<=frequency<=255):
        raise ValueError('Invalid trigger vibration')
    zones=sum(1<<i for i in range(start,10))
    forces=sum((strength-1)<<(3*i) for i in range(start,10))
    return bytes([0x26])+zones.to_bytes(2,'little')+forces.to_bytes(4,'little')+bytes([0,0,frequency,0])

def packet(effect, toggles=None, audio_haptics=False, speaker_volume=None):
    t = toggles or dict(rumble=True,lightbar=True,triggers=True)
    b = bytearray(63); b[0] = 2
    # Speaker control is opt-in; microphone/headphone volume is never written.
    b[1] = 0x0c | (3 if t.get('rumble',False) and not audio_haptics else 0)
    b[2] = 4 if t.get('lightbar',False) else 0
    if speaker_volume is not None:
        if type(speaker_volume) is not int or not 0<=speaker_volume<=100: raise ValueError("Speaker volume 0..100")
        b[1] |= 0xa0 # speaker volume + audio routing valid
        b[2] |= 0x80 # speaker pre-gain valid
        b[6] = round(61+.41*speaker_volume) if speaker_volume else 0
        b[8] = 0x30 if speaker_volume else 0 # internal speaker FR; default headphone route when off
        b[38] = 4
    if t.get('rumble',False) and not audio_haptics:
        b[3], b[4] = effect.get('rumble',[0,0])
    for offset, key in ((11,'right_trigger'),(22,'left_trigger')):
        config=effect.get(key+'_preview') if t.get('triggers',False) else None
        if config:
            b[offset:offset+11]=trigger_block(config)
            continue
        start, force = effect.get(key,[0,0]) if t.get('triggers',False) else [0,0]
        b[offset:offset+3] = bytes([1 if force else 0,start,force])
    if t.get('lightbar',False):
        b[39]=2; b[42]=2; b[45:48]=bytes(effect.get('color',[0,0,0]))
    return bytes(b)

class DualSenseOutput:
    def __init__(self, index=0):
        import hid
        devices = [d for d in hid.enumerate(0x054c,0x0ce6) if d.get('usage_page')==1 and d.get('usage')==5]
        if not 0 <= index < len(devices):
            raise RuntimeError(f'No controller at index {index}; found {len(devices)}')
        self.info=devices[index]; self.device=hid.device(); self.device.open_path(self.info['path'])
        self.device.set_nonblocking(1)
        # Verify transport from actual report before writing any output.
        import time
        deadline=time.monotonic()+2
        while time.monotonic()<deadline:
            data=self.device.read(78)
            if data:
                try: self.input=decode(data); self.last_input_at=time.monotonic()
                except Exception: self.device.close(); raise
                return
            time.sleep(.005)
        self.device.close(); raise RuntimeError('No USB input report received')
    def read(self):
        data=self.device.read(78)
        if data: self.input=decode(data); self.last_input_at=time.monotonic()
        return self.input
    def send(self,effect,toggles=None,audio_haptics=False,speaker_volume=None):
        report=packet(effect,toggles,audio_haptics,speaker_volume)
        if speaker_volume is not None: self.speaker_owned=True
        # Windows descriptor exposes ID + 47-byte common payload;
        # the remaining USB bytes are reserved padding used by Linux.
        if sys.platform=='win32': report=report[:48]
        written=self.device.write(report)
        # Windows HIDAPI pads to the descriptor's OutputReportByteLength.
        if written<len(report): raise IOError(f'Incomplete HID output write: {written}/{len(report)}')
    def close(self):
        try: self.send({},speaker_volume=0 if getattr(self,"speaker_owned",False) else None)
        finally: self.device.close()
