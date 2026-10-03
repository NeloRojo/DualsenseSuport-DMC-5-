"""Read embedded Wwise media indexes for offline developer preparation."""
import struct

def embedded_media(data):
    offset=0;index=None;media_size=None
    while offset<len(data):
        if offset+8>len(data):raise ValueError('Truncated bank chunk')
        tag,size=struct.unpack_from('<4sI',data,offset);offset+=8
        if offset+size>len(data):raise ValueError('Bank chunk out of bounds')
        if tag==b'DIDX':index=data[offset:offset+size]
        if tag==b'DATA':media_size=size
        offset+=size
    if index is None:return []
    if len(index)%12 or media_size is None:raise ValueError('Invalid embedded media index')
    result=[]
    for position,(identity,start,size) in enumerate(struct.iter_unpack('<III',index),1):
        if start+size>media_size:raise ValueError('Media out of bounds')
        if size:result.append((position,identity,size))
    return result
