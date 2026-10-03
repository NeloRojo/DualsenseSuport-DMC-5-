"""One helper per bridge; an automatic helper exits gracefully with its game."""
import ctypes
import hashlib
import os
from ctypes import wintypes

class AlreadyRunning(RuntimeError):
    pass

class GameLifetime:
    def __init__(self, bridge=None, parent_pid=None):
        self.kernel = None
        self.mutex = None
        self.parent = None
        if os.name != 'nt':
            if parent_pid: raise RuntimeError('Automatic game lifetime requires Windows')
            return
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.kernel.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
        self.kernel.CreateMutexW.restype = wintypes.HANDLE
        self.kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.kernel.OpenProcess.restype = wintypes.HANDLE
        self.kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.kernel.WaitForSingleObject.restype = wintypes.DWORD
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel.CloseHandle.restype = wintypes.BOOL
        try:
            if bridge:
                key = hashlib.sha256(str(bridge.resolve()).casefold().encode()).hexdigest()[:24]
                self.mutex = self.kernel.CreateMutexW(None, False, 'Local\\DMC5DualSense_' + key)
                error = ctypes.get_last_error()
                if not self.mutex: raise ctypes.WinError(error)
                if error == 183: raise AlreadyRunning('A DualSense helper is already running for this game')
            if parent_pid:
                self.parent = self.kernel.OpenProcess(0x00100000, False, parent_pid) # SYNCHRONIZE, read-only
                if not self.parent: raise ctypes.WinError(ctypes.get_last_error())
        except Exception:
            self.close()
            raise

    def running(self):
        if not self.parent: return True
        result = self.kernel.WaitForSingleObject(self.parent, 0)
        if result == 0x102: return True
        if result == 0: return False
        raise ctypes.WinError(ctypes.get_last_error())

    def close(self):
        if self.kernel:
            for name in ('parent', 'mutex'):
                handle = getattr(self, name)
                if handle: self.kernel.CloseHandle(handle); setattr(self, name, None)
