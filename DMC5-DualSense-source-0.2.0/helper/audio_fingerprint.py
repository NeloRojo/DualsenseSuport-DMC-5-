"""Compact spectral search plus original-wave correlation for mixed references."""
import numpy as np

RATE=12000
HOP=240
BANDS=24

def mono(pcm,rate,channels):
    x=np.frombuffer(pcm,dtype='<i2').astype(np.float32).reshape(-1,channels).mean(axis=1)/32768
    if rate!=RATE:
        n=int(len(x)*RATE/rate)
        x=np.interp(np.arange(n,dtype=np.float64)*rate/RATE,np.arange(len(x)),x).astype(np.float32)
    return x

def spectrum(x):
    x=np.asarray(x,dtype=np.float32)
    if len(x)<512:x=np.pad(x,(0,512-len(x)))
    frames=np.lib.stride_tricks.sliding_window_view(x,512)[::HOP]
    power=np.abs(np.fft.rfft(frames*np.hanning(512),axis=1))**2
    edges=np.unique(np.round(np.geomspace(1,256,BANDS+1)).astype(int))
    # Linear fallback guarantees 24 nonempty bands at the low end.
    edges=np.maximum.accumulate(np.maximum(np.round(np.geomspace(1,256,BANDS+1)).astype(int),np.arange(BANDS+1)))
    energy=np.stack([power[:,edges[i]:max(edges[i]+1,edges[i+1])].sum(axis=1) for i in range(BANDS)],axis=1)
    energy=np.sqrt(np.sqrt(energy+1e-15))
    norms=np.linalg.norm(energy,axis=1,keepdims=True)
    energy/=np.maximum(norms,1e-8)
    # Truly silent windows must not look like a broadband sound.
    energy[np.mean(frames*frames,axis=1)<1e-9]=0
    return energy.astype(np.float32)

def vector(spec):
    x=np.r_[spec.mean(axis=0),spec.max(axis=0)]
    return (x/max(np.linalg.norm(x),1e-8)).astype('<f4')

def contrast(spec):
    """Undo broad compression and remove each frame's broadband noise floor."""
    x=spec*spec
    floor=np.quantile(x,.2,axis=1,keepdims=True)
    x=np.maximum(0,x-floor)
    x/=np.maximum(np.linalg.norm(x,axis=1,keepdims=True),1e-8)
    return x.astype(np.float32)

def spectral_match(a,b):
    """Best contiguous alignment; permits a short trim inside a longer sample."""
    swapped=len(a)<len(b)
    if swapped:a,b=b,a
    n=1<<(len(a)+len(b)-2).bit_length()
    dot=np.fft.irfft((np.fft.rfft(a,n,axis=0)*np.fft.rfft(b[::-1],n,axis=0)).sum(axis=1),n)[len(b)-1:len(a)]
    energy=np.r_[0,np.cumsum(np.sum(a*a,axis=1))]
    scores=dot/np.sqrt(np.maximum(energy[len(b):]-energy[:-len(b)],1e-10)*max(float(np.sum(b*b)),1e-10))
    index=int(np.argmax(scores))
    return float(np.clip(scores[index],0,1)),index*HOP/RATE,swapped

def waveform_match(a,b):
    swapped=len(a)<len(b)
    if swapped:a,b=b,a
    a=a.astype(np.float64);b=b.astype(np.float64);b=b-b.mean()
    n=1<<(len(a)+len(b)-2).bit_length()
    dot=np.fft.irfft(np.fft.rfft(a,n)*np.fft.rfft(b[::-1],n),n)[len(b)-1:len(a)]
    energy=np.r_[0,np.cumsum(a*a)];sums=np.r_[0,np.cumsum(a)]
    variance=energy[len(b):]-energy[:-len(b)]-(sums[len(b):]-sums[:-len(b)])**2/len(b)
    score=np.abs(dot)/np.sqrt(np.maximum(variance,1e-12)*max(float(np.sum(b*b)),1e-12))
    i=int(np.argmax(score))
    return float(np.clip(score[i],0,1)),i/RATE,swapped

def stereo48(pcm,rate,channels):
    x=np.frombuffer(pcm,dtype='<i2').reshape(-1,channels).astype(np.float32)
    if channels==1:x=np.repeat(x,2,axis=1)
    if rate!=48000:
        pos=np.arange(int(len(x)*48000/rate))*rate/48000
        x=np.stack([np.interp(pos,np.arange(len(x)),x[:,i]) for i in range(2)],axis=1)
    return np.clip(x,-32768,32767).astype('<i2').tobytes()
