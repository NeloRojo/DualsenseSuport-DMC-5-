"""Low-latency XInput snapshot for the optional in-game translator (Windows)."""
import ctypes
import mmap
import struct

MAGIC = 0x354D4344
BUTTONS = dict(dpad_up=1, dpad_down=2, dpad_left=4, dpad_right=8,
               options=0x10, create=0x20, l3=0x40, r3=0x80,
               l1=0x100, r1=0x200, cross=0x1000, circle=0x2000,
               square=0x4000, triangle=0x8000)

def axis(value, invert=False):
    # USB centre is 127/128. Preserve the full asymmetric signed XInput range.
    value = max(0, min(255, int(value)))
    result = round((value - 128) * 32768 / 128) if value < 128 else round((value - 128) * 32767 / 127)
    return max(-32768, min(32767, -result if invert else result))

def gamepad(state):
    buttons = sum(mask for name, mask in BUTTONS.items() if state['buttons'].get(name, False))
    dpad = state['dpad']
    if dpad in (7, 0, 1): buttons |= 1
    if dpad in (3, 4, 5): buttons |= 2
    if dpad in (5, 6, 7): buttons |= 4
    if dpad in (1, 2, 3): buttons |= 8
    sticks = state['sticks']
    return struct.pack('<HBBhhhh', buttons, *state['triggers'],
                       axis(sticks[0]), axis(sticks[1], True),
                       axis(sticks[2]), axis(sticks[3], True))

class NativeInputOutput:
    def __init__(self, game_pid):
        self.mapping = mmap.mmap(-1, 32, tagname=f'Local\\DMC5DualSenseInput_{game_pid}', access=mmap.ACCESS_WRITE)
        self.kernel = ctypes.WinDLL('kernel32')
        self.kernel.GetTickCount64.restype = ctypes.c_ulonglong
        self.sequence = 0
        self.packet = 0
        self.previous = None

    def publish(self, state):
        pad = gamepad(state)
        if pad != self.previous: self.packet = (self.packet + 1) & 0xffffffff
        self.previous = pad
        self.sequence = (self.sequence + 2) & 0xfffffffe
        # Odd during write; readers require the same even sequence around copy.
        self.mapping[4:8] = struct.pack('<I', self.sequence | 1)
        self.mapping[8:32] = struct.pack('<QI', self.kernel.GetTickCount64(), self.packet) + pad
        self.mapping[0:4] = struct.pack('<I', MAGIC)
        self.mapping[4:8] = struct.pack('<I', self.sequence)

    def close(self):
        self.mapping[0:4] = bytes(4)
        self.mapping.close()
