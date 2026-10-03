"""Standalone four-channel audio haptics test. Stop bridge helper first."""
import argparse
import time
from pathlib import Path
from audio_haptics import AudioHapticsOutput, devices, render
from dualsense import DualSenseOutput

def run():
    parser=argparse.ArgumentParser()
    parser.add_argument('--list',action='store_true')
    parser.add_argument('--audio-device',type=int)
    parser.add_argument('--index',type=int,default=0)
    parser.add_argument('--wav',type=Path)
    args=parser.parse_args()
    if args.list:
        for index,info in devices(): print(index,info)
        return
    hid=DualSenseOutput(args.index)
    audio=None
    try:
        audio=AudioHapticsOutput(args.audio_device)
        hid.send({},dict(rumble=False,lightbar=False,triggers=False),audio_haptics=True)
        patterns=[{'frequency_hz':[90,0],'duration_ms':180},
                  {'frequency_hz':[0,170],'duration_ms':180},
                  {'frequency_hz':[65,65],'sweep_hz':[220,220],'duration_ms':600}]
        if args.wav: patterns=[{'file':args.wav.name}]
        for spec in patterns:
            clip=render(spec,args.wav.parent if args.wav else Path.cwd())
            print('Audio haptic test',spec,flush=True)
            audio.play(clip)
            time.sleep(len(clip)/(48000*16)+.6)
        print('Complete; underruns:',audio.underruns,'error:',audio.error,flush=True)
    finally:
        if audio: audio.close()
        hid.close()
if __name__=='__main__': run()
