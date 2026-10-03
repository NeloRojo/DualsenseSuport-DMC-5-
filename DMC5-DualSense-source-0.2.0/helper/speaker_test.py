"""Short USB internal-speaker test. Stop the bridge helper first."""
import argparse
import time
from pathlib import Path
from audio_haptics import AudioHapticsOutput, render
from dualsense import DualSenseOutput

def run():
    p=argparse.ArgumentParser()
    p.add_argument('--audio-device',type=int)
    p.add_argument('--index',type=int,default=0)
    p.add_argument('--volume',type=int,default=50)
    p.add_argument('--wav',type=Path)
    args=p.parse_args()
    hid=DualSenseOutput(args.index); audio=None
    try:
        audio=AudioHapticsOutput(args.audio_device)
        spec={'gain':.2,'segments':[{'duration_ms':180,'frequency_hz':[660,660]}, {'duration_ms':180,'frequency_hz':[880,880]}, {'duration_ms':280,'frequency_hz':[1100,1100],'decay':True}]}
        if args.wav: spec={'file':args.wav.name,'gain':.2}
        clip=render(spec,args.wav.parent if args.wav else Path.cwd(),target='speaker')
        hid.send({},dict(rumble=False,lightbar=False,triggers=False),audio_haptics=True,speaker_volume=args.volume)
        time.sleep(.15)
        audio.play(clip)
        time.sleep(len(clip)/(48000*16)+.3)
        print('Speaker test complete; underruns:',audio.underruns,'error:',audio.error)
    finally:
        if audio: audio.close()
        hid.close()

if __name__=='__main__': run()
