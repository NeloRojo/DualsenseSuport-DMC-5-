"""Lossless local sound pack. Verify all bytes before removing loose WAVs.

Python is needed only by developers updating the pack, not by installed users.
"""
import argparse
import hashlib
import os
import re
import tempfile
import zipfile
from pathlib import Path

NAME = re.compile(r'assets/[a-zA-Z0-9_-]+\.wav\Z')
LIMIT = 48000*10*2*2+65536

def pack_audio(root, keep_loose=False):
    root = Path(root).resolve()
    destination = root/'audio.dmcpack'
    assets = root/'assets'
    members = {}
    if destination.exists():
        with zipfile.ZipFile(destination) as old:
            for entry in old.infolist():
                if not NAME.fullmatch(entry.filename) or not 0 < entry.file_size <= LIMIT:
                    raise ValueError('Unexpected audio pack member')
                if entry.filename in members: raise ValueError('Duplicate audio member')
                members[entry.filename] = old.read(entry)
    loose = []
    if assets.exists():
        for path in sorted(assets.glob('*.wav')):
            resolved = path.resolve()
            if not resolved.is_relative_to(root) or path.is_symlink():
                raise ValueError('WAV must remain inside the profile directory')
            name = 'assets/'+path.name
            if not NAME.fullmatch(name) or not 0 < path.stat().st_size <= LIMIT:
                raise ValueError('Invalid loose audio member')
            data = path.read_bytes()
            members[name] = data
            loose.append((path, data))
    if not members: raise ValueError('No audio assets to pack')
    fd, temporary = tempfile.mkstemp(prefix='audio-', suffix='.tmp', dir=root)
    os.close(fd)
    temporary = Path(temporary)
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as pack:
            for name, data in sorted(members.items()):
                entry = zipfile.ZipInfo(name, date_time=(1980,1,1,0,0,0))
                entry.compress_type = zipfile.ZIP_DEFLATED
                pack.writestr(entry, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        with zipfile.ZipFile(temporary) as check:
            if set(check.namelist()) != set(members): raise ValueError('Pack member verification failed')
            for name, data in members.items():
                if hashlib.sha256(check.read(name)).digest() != hashlib.sha256(data).digest():
                    raise ValueError('Pack content verification failed')
        temporary.replace(destination)
        if not keep_loose:
            for path, data in loose:
                # Keep a file that changed since verification rather than losing an update.
                if path.read_bytes() == data: path.unlink()
            if assets.exists() and not any(assets.iterdir()): assets.rmdir()
        profile = root/'nero.json'
        if profile.exists(): os.utime(profile, None)
        return {'files':len(members), 'original_bytes':sum(map(len,members.values())), 'packed_bytes':destination.stat().st_size}
    finally:
        if temporary.exists(): temporary.unlink()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile_root', type=Path)
    parser.add_argument('--keep-loose', action='store_true')
    args = parser.parse_args()
    print(pack_audio(args.profile_root, args.keep_loose))
