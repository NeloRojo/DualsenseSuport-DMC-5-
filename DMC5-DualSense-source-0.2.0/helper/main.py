import argparse, json, logging, time, uuid, sys, wave
from logging.handlers import RotatingFileHandler
from configparser import ConfigParser
from pathlib import Path
from dualsense import DualSenseOutput
from effects import ExceedContext, compose
from audio_haptics import AudioHapticsOutput, render, mix
from lifecycle import GameLifetime, AlreadyRunning
from native_input import NativeInputOutput
from action_capture import ActionCapture
from pc_preview import PCPreview
from audio_finder import AudioFinder

ROOT=Path(sys.executable).parent if getattr(sys,'frozen',False) else Path(__file__).resolve().parents[1]
ASSETS=Path(sys._MEIPASS) if getattr(sys,'frozen',False) else ROOT
def load(path):
    return json.loads(path.read_text(encoding='utf-8'))
def profile(path):
    p=load(path)
    common=path.parent/'common.json'
    if common.exists(): p['effects']={**load(common)['effects'],**p['effects']}
    dante=path.parent/'dante.json'
    dante_profile=load(dante) if dante.exists() else {}
    p['weapon_preview']=dante_profile.get('weapon_preview',{})
    p['sdt_charge_led']=dante_profile.get('sdt_charge_led',{})
    p['sdt_attack_triggers']=dante_profile.get('sdt_attack_triggers',{})
    p['effects']={**dante_profile.get('effects',{}),**p['effects']}
    vergil=path.parent/'vergil.json'
    vergil_profile=load(vergil) if vergil.exists() else {}
    p['effects']={**vergil_profile.get('effects',{}),**p['effects']}
    p['doppel_led']=vergil_profile.get('doppel_led',{})
    for kind in ('L','S'):
        p['weapon_preview'][kind]={**p['weapon_preview'].get(kind,{}),**vergil_profile.get('weapon_preview',{}).get(kind,{})}
    if vergil_profile.get('weapon_preview',{}).get('enabled'):p['weapon_preview']['enabled']=True
    from dualsense import trigger_block
    for kind in ('L','S'):
        for config in p['weapon_preview'].get(kind,{}).values(): trigger_block(config)
    for move in ('demolition','luce'):
        for config in p['sdt_attack_triggers'].get(move,{}).values():trigger_block(config)
    for e in p['effects'].values():
        if not isinstance(e['duration_ms'],int) or not 1<=e['duration_ms']<=2000: raise ValueError('duration must be 1..2000ms')
        if 'led_pulses' in e and (type(e['led_pulses']) is not int or not 1<=e['led_pulses']<=8 or 'color' not in e): raise ValueError('led_pulses')
        for key,n in [('color',3),('rumble',2),('left_trigger',2),('right_trigger',2)]:
            a=e.get(key,[0]*n)
            if len(a)!=n or any(type(x)!=int or not 0<=x<=255 for x in a): raise ValueError(key)
    adaptive=p.get('adaptive_exceed',{}).get('left_trigger',[45,35])
    if len(adaptive)!=2 or any(type(x)!=int or not 0<=x<=255 for x in adaptive): raise ValueError('adaptive_exceed')
    for key,default in [('snatch_trigger',[5,190]),('buster_trigger',[25,160])]:
        trigger=p.get('adaptive_bringer',{}).get(key,default)
        if len(trigger)!=2 or any(type(x)!=int or not 0<=x<=255 for x in trigger): raise ValueError('adaptive_bringer.'+key)
    forces=p.get('adaptive_exceed',{}).get('force_by_stock',[35,55,80,110])
    if len(forces)!=4 or any(type(x)!=int or not 0<=x<=255 for x in forces) or forces!=sorted(forces): raise ValueError('force_by_stock')
    fire=p.get('exceed_fire',{})
    brightness=fire.get('brightness_by_stock',[0,.30,.65,1.0])
    if len(brightness)!=4 or any(type(x) not in (int,float) or not 0<=x<=1 for x in brightness) or brightness!=sorted(brightness) or brightness[0]!=0: raise ValueError('brightness_by_stock')
    for key,default in [('low_color',[175,35,0]),('high_color',[255,145,4])]:
        color=fire.get(key,default)
        if len(color)!=3 or any(type(x)!=int or not 0<=x<=255 for x in color): raise ValueError('exceed_fire.'+key)
    volume=p.get("speaker_volume",50)
    if type(volume) is not int or not 0<=volume<=100: raise ValueError("Speaker volume 0..100")
    return p

def profile_stamp(path):
    files=[path,*[path.parent/name for name in ('common.json','dante.json','vergil.json','audio.dmcpack')]]
    return tuple(f.stat().st_mtime_ns if f.exists() else None for f in files)

def clips(p,root):
    return {name:render(e['haptic_audio'],root) for name,e in p['effects'].items() if 'haptic_audio' in e}
def speaker_clips(p,root):
    return {name:render(e["speaker_audio"],root,target="speaker") for name,e in p["effects"].items() if "speaker_audio" in e}

def atomic(path,value):
    tmp=path.with_suffix('.tmp'); tmp.write_text(json.dumps(value),encoding='utf-8')
    for attempt in range(4):
        try: tmp.replace(path); return True
        except PermissionError:
            if attempt==3: return False # Lua reader may briefly hold the destination open.
            time.sleep(.005)
def arguments():
    ap=argparse.ArgumentParser(); ap.add_argument('--list',action='store_true'); ap.add_argument('--index',type=int,default=0)
    ap.add_argument('--profile',type=Path,default=ASSETS/'profiles/nero.json'); ap.add_argument('--bridge',type=Path)
    ap.add_argument('--effect',default='damage'); ap.add_argument('--monitor',action='store_true'); ap.add_argument('--dry-run',action='store_true')
    ap.add_argument('--speaker',action='store_true'); ap.add_argument('--audio-haptics',action='store_true'); ap.add_argument('--audio-device',type=int)
    ap.add_argument('--verbose',action='store_true',help='Enable detailed development logging')
    ap.add_argument('--parent-pid',type=int,help='Exit when the owning game process closes')
    return ap.parse_args()

def run(args=None):
    args=args or arguments()
    if args.list:
        import hid
        for i,d in enumerate(hid.enumerate(0x054c,0x0ce6)): print(i,d)
        return
    p=profile(args.profile); audio_clips=clips(p,args.profile.parent) if args.audio_haptics else {}; speaker_samples=speaker_clips(p,args.profile.parent) if args.speaker else {}; speaker_end=0; speaker_overlay_end=0; speaker_cue_end=0; speaker_loop=False; speaker_loop_started=0; haptic_end=0; output=None; audio=None; audio_end=0; audio_loop=False; session=str(uuid.uuid4()); last=None; end=0; last_effect='none'; active=False
    lifetime=GameLifetime(args.bridge,args.parent_pid)
    native_input=None
    action_capture=ActionCapture(args.bridge,args.parent_pid) if args.bridge and args.speaker else None
    pc_preview=PCPreview() if action_capture else None
    finder=AudioFinder(args.bridge) if action_capture else None
    sdt_loop=False
    sdt_transform_consumed=False
    context=ExceedContext(); context_poll=0; current_effect={}; current_toggles=dict(rumble=True,lightbar=True,triggers=True); effect_started=0
    sent=None; previous_pressed=False; previous_fire=False
    if args.bridge: args.bridge.mkdir(parents=True,exist_ok=True)
    try:
        if not args.dry_run: output=DualSenseOutput(args.index)
        if output and args.parent_pid and args.bridge:
            input_config=ConfigParser();input_config.read(args.bridge/'native_input.ini')
            if input_config.getboolean('input','enabled',fallback=False): native_input=NativeInputOutput(args.parent_pid)
        if (args.audio_haptics or args.speaker) and not args.dry_run:
            try:
                audio=AudioHapticsOutput(args.audio_device)
                logging.info('Audio haptics connected: %s',audio.info)
            except Exception: logging.exception('Audio haptics unavailable; keeping HID rumble')
        logging.info('Connected: %s',output.info if output else 'simulation')
        if not args.bridge and not args.monitor:
            e=p['effects'][args.effect]
            haptic=audio_clips.get(args.effect) if args.audio_haptics else None
            speaker=speaker_samples.get(args.effect) if args.speaker else None
            clip=mix(haptic,speaker)
            if audio and clip: audio.play(clip)
            if output: output.send(e,audio_haptics=bool(audio and haptic),speaker_volume=p.get("speaker_volume",50) if args.speaker and speaker else (0 if args.speaker else None))
            else: logging.info('Packet effect %s',e)
            time.sleep(max(e['duration_ms']/1000,len(clip)/(48000*16) if audio and clip else 0)); return
        tick=0; profile_mtime=profile_stamp(args.profile);profile_check=0;request_poll=0
        while lifetime.running():
            now=time.monotonic()
            if output:
                state=output.read()
                if now-output.last_input_at>1: raise OSError('DualSense USB input stopped; reconnecting')
            else: state={}
            if args.monitor and now-tick>.25: print(json.dumps(state)); tick=now
            if args.bridge:
                request=None
                if now-request_poll>=.01:
                    request_poll=now
                    try: request=load(args.bridge/'request.json')
                    except (OSError,ValueError): pass # partial Lua writes are retried
                if request and request.get('session')==session and request.get('seq')!=last:
                    last=request.get('seq')
                    if finder and str(request.get('event','')).startswith('finder_'):
                        try:
                            command=request['event']
                            if command=='finder_prepare':finder.prepare(bool(request.get('include_other',False)))
                            elif command=='finder_retry':finder.retry(bool(request.get('include_other',False)))
                            elif command=='finder_saved':finder.load_choice(request['choice']);finder.audition(last,mix=True,gain=request.get('gain',.5))
                            elif command=='finder_pause':finder.pause()
                            elif command=='finder_search':
                                with action_capture.lock:pcm=action_capture.pcm
                                finder.search(pcm,request.get('capture_start',0),request.get('capture_end',len(pcm)/192000),bool(request.get('include_other',False)),bool(request.get('deep',False)),request.get('max_candidate_seconds'))
                            elif command=='finder_listen':finder.audition(last,request['key'],request.get('start',0),request.get('finish'),gain=request.get('gain',.5))
                            elif command=='finder_mix':finder.audition(last,mix=True,gain=request.get('gain',.5))
                            elif command=='finder_reject':finder.reject(request['key'])
                            elif command=='finder_layer':finder.layer(request['key'],request.get('start',0),request.get('finish'),request.get('offset',0),request.get('gain',1))
                            elif command=='finder_clear_layers':finder.clear_layers()
                            elif command=='finder_confirm':finder.confirm(request.get('label',''),request.get('destination','haptics'),request.get('key'),request.get('start',0),request.get('finish'))
                            elif command=='finder_silence':
                                if finder.operation=='preparando escucha':finder.pause()
                                if pc_preview:pc_preview.stop()
                            else:raise ValueError('Comando de busqueda no reconocido')
                        except (ValueError,KeyError,TypeError,OverflowError) as exc:finder.error=str(exc)
                        continue
                    if action_capture and str(request.get('event','')).startswith('preview_capture_'):
                        try:
                            command=request['event']
                            if command=='preview_capture_start':
                                if finder:finder.pause();finder.rows=[];finder.clear_layers()
                                if pc_preview:pc_preview.stop()
                                action_capture.start(request.get('capture_seconds',15))
                            elif command=='preview_capture_stop':action_capture.stop()
                            elif command=='preview_capture_release':
                                if finder:finder.pause()
                                action_capture.release()
                                if pc_preview:pc_preview.stop()
                                if audio:audio.stop_speaker();audio.stop_haptics();speaker_end=0;haptic_end=0
                            elif command=='preview_capture_play':
                                if pc_preview:pc_preview.stop()
                                action_capture.preview(last,request.get('capture_start',0),request.get('capture_end'),request.get('capture_mode','pc'))
                            elif command=='preview_capture_silence':
                                if pc_preview:pc_preview.stop()
                                if audio:audio.stop_speaker();audio.stop_haptics();speaker_end=0;haptic_end=0
                            else:raise ValueError('Comando de captura no reconocido')
                        except (ValueError,TypeError,OverflowError) as exc:action_capture.error=str(exc)
                        continue
                    if pc_preview and request.get('event')=='preview_audio_stop':pc_preview.stop()
                    try:
                        e=p['effects'][request['event']]
                        # Reject old requests by matching the helper session; keep only newest event.
                        toggles=request.get('toggles',{})
                        current_effect=e; current_toggles=toggles; effect_started=now
                        haptic=audio_clips.get(request['event']) if args.audio_haptics and toggles.get('haptics',True) else None
                        speaker=speaker_samples.get(request['event']) if args.speaker and toggles.get('speaker',False) else None
                        if pc_preview and speaker and request.get('preview_output')=='pc' and str(request.get('event','')).startswith('preview_'):
                            pc_preview.play(speaker,quad=True);last_effect=request['event'];continue
                        clip=mix(haptic,speaker)
                        if audio:
                            if haptic:
                                sdt_loop=False;audio.set_haptic_scale(1)
                                audio_loop=request['event']=='maximum_bet_charge' and e.get('haptic_audio',{}).get('loop') is True
                                audio.play_haptics(haptic,loop=audio_loop)
                                haptic_end=float('inf') if audio_loop else now+len(haptic)/(48000*16)
                                if request['event']=='dante_sdt_enter' and e.get('haptic_audio',{}).get('max_duration_ms',2000)>2000:
                                    sdt_loop='transform';sdt_transform_consumed=True
                            if request['event'] in ('maximum_bet_release','maximum_bet_release_lv1','maximum_bet_release_lv2','special_cancel'):
                                audio.stop_speaker_cue(); speaker_cue_end=0
                            if speaker:
                                if request['event'] in ('devil_trigger_enter','devil_trigger_exit','dante_devil_trigger_enter','dante_devil_trigger_exit','dante_sdt_enter','dante_sdt_short_enter','vergil_sdt_enter','vergil_sdt_exit'):
                                    audio.play_speaker_overlay(speaker)
                                    speaker_overlay_end=now+len(speaker)/(48000*16)
                                elif request['event'] in ('maximum_bet_level2','maximum_bet_level3','vergil_sdt_ready','dante_sdt_ready'):
                                    audio.play_speaker_cue(speaker)
                                    speaker_cue_end=now+len(speaker)/(48000*16)
                                else:
                                    speaker_loop=request['event']=='maximum_bet_charge' and e.get('speaker_audio',{}).get('loop') is True
                                    speaker_loop_started=now
                                    audio.play_speaker(speaker,loop=speaker_loop,loop_start_ms=e.get("speaker_audio",{}).get("loop_start_ms",0))
                                    speaker_end=float('inf') if speaker_loop else now+len(speaker)/(48000*16)
                            if request['event']=='special_cancel':
                                audio.stop_haptics(); haptic_end=0; audio_loop=False
                                if speaker_loop: audio.stop_speaker(); speaker_end=0; speaker_loop=False
                            if clip:
                                logging.info('Audio event %s: haptics=%s speaker=%s (%d frames)',request['event'],bool(haptic),bool(speaker),len(clip)//16)
                        end=now+e['duration_ms']/1000; active=True; last_effect=request['event']
                        logging.info('Event %s seq=%s',last_effect,last)
                    except (KeyError,TypeError,ValueError): logging.exception('Invalid event')
                if now-context_poll>.05:
                    try: context.update(load(args.bridge/'control.json'),session,now)
                    except (OSError,ValueError): pass # transient reads expire by monotonic lease
                    context_poll=now
            if audio:
                cancelled=audio.set_game_paused(context.game_paused)
                if context.game_paused:
                    speaker_end=0;speaker_overlay_end=0;speaker_cue_end=0;speaker_loop=False
                if cancelled:logging.info('Controller audio cancelled by game pause')
            if context.game_paused:
                active=False;current_effect={};end=0
                haptic_end=0;audio_loop=False;sdt_loop=False
            if active and now>=end:
                active=False; current_effect={}
            if native_input and now-output.last_input_at<.1: native_input.publish(state)
            pressed=context.pressed(state,now,bool(output) and now-output.last_input_at<.25)
            if pressed!=previous_pressed:
                logging.info('Adaptive Exceed L2 %s','on' if pressed else 'released')
                previous_pressed=pressed
            fire=context.fire_active(now)
            if fire!=previous_fire:
                logging.info('Exceed fire LED %s','on' if fire else 'off')
                previous_fire=fire
            bringer=context.bringer_ready(now,bool(output) and now-output.last_input_at<.25)
            combined,flags=compose(current_effect,current_toggles,pressed,p.get('adaptive_exceed',{}),context.peak_stock,fire,now,p.get('exceed_fire',{}),context.stock,bringer,p.get('adaptive_bringer',{}),context.lock_on,now-effect_started)
            combined,flags=context.weapon_preview(combined,flags,p.get('weapon_preview',{}),now,bool(output) and now-output.last_input_at<.25)
            combined,flags=context.sdt_triggers(combined,flags,p.get('sdt_attack_triggers',{}),now,bool(output) and now-output.last_input_at<.25)
            combined,flags=context.vergil_sdt_led(combined,flags,now,bool(output) and now-output.last_input_at<.25)
            combined,flags=context.doppel_led(combined,flags,p.get('doppel_led',{}),now,bool(output) and now-output.last_input_at<.25)
            combined,flags=context.sdt_led(combined,flags,p.get('sdt_charge_led',{}),now,bool(output) and now-output.last_input_at<.25)
            # Stop audio on lost game context, disabled feature or disconnected HID.
            audio_enabled=bool(not context.game_paused and audio and audio.stream.active and ((args.audio_haptics and context.haptics_allowed) or (args.speaker and context.speaker_allowed)) and now-context.renewed<.75 and output and now-output.last_input_at<.25 and not audio.error)
            if audio and not audio_enabled and args.bridge: audio.stop(); haptic_end=0; speaker_end=0; speaker_overlay_end=0; speaker_cue_end=0; audio_loop=False; speaker_loop=False
            if audio and audio_loop and now-effect_started>.1 and not context.maximum_bet_charging:
                audio.stop_haptics(); haptic_end=0; audio_loop=False
            if audio and speaker_loop and now-speaker_loop_started>.1 and not context.maximum_bet_charging:
                audio.stop_speaker(); speaker_end=0; speaker_loop=False
                audio.stop_speaker_cue(); speaker_cue_end=0
            preparing=bool(audio_enabled and args.audio_haptics and context.haptics_allowed and context.sdt_preparing)
            transforming=bool(audio_enabled and args.audio_haptics and context.haptics_allowed and context.sdt_transforming)
            sdt_wanted='transform' if transforming else ('charge' if preparing else False)
            transform_grace=sdt_loop=='transform' and now-effect_started<.2
            if not context.game_paused and not context.sdt_transforming and not transform_grace:
                sdt_transform_consumed=False
            if audio and sdt_loop and sdt_loop!=sdt_wanted and not transform_grace:
                audio.stop_haptics();audio.set_haptic_scale(1);sdt_loop=False;haptic_end=0
            if audio and sdt_wanted and not sdt_loop and not active and not (sdt_wanted=='transform' and sdt_transform_consumed):
                charge_clip=audio_clips.get('dante_sdt_'+sdt_wanted)
                if charge_clip:
                    one_shot=sdt_wanted=='transform' and p['effects'].get('dante_sdt_transform',{}).get('haptic_audio',{}).get('max_duration_ms',2000)>2000
                    audio.play_haptics(charge_clip,loop=not one_shot);sdt_loop=sdt_wanted
                    haptic_end=now+len(charge_clip)/(48000*16) if one_shot else float('inf')
                    if one_shot:sdt_transform_consumed=True
            if audio and sdt_loop:
                audio.set_haptic_scale(1 if sdt_loop=='transform' else .15+.85*context.sdt_progress)
            if audio: audio.set_channels(haptics=not context.game_paused and args.audio_haptics and context.haptics_allowed,speaker=not context.game_paused and args.speaker and context.speaker_allowed)
            playing_audio=bool(audio_enabled and args.audio_haptics and context.haptics_allowed and now<haptic_end)
            if finder:
                audition=finder.poll()
                if audition and pc_preview:pc_preview.play(audition[1]);last_effect='audio_finder_audition'
            if action_capture:
                captured=action_capture.poll()
                if captured and captured[0]==last and captured[3]=='pc':
                    # ActionCapture's PC path returns original PCM16 stereo, not controller float32 quad.
                    _,last_effect,pcm,_=captured;pc_preview.play(pcm);captured=None
                if captured and captured[0]==last and audio and audio_enabled:
                    _,last_effect,clip,mode=captured;duration=len(clip)/(48000*16)
                    if mode in ('speaker','both') and args.speaker and context.speaker_allowed:audio.play_speaker(clip);speaker_loop=False;speaker_end=now+duration
                    if mode in ('haptics','both') and args.audio_haptics and context.haptics_allowed:audio.set_haptic_scale(1);audio.play_haptics(clip);haptic_end=now+duration
            playing_speaker=bool(audio_enabled and args.speaker and context.speaker_allowed and now<max(speaker_end,speaker_overlay_end,speaker_cue_end))
            speaker_volume=round(p.get("speaker_volume",50)*(context.speaker_volume if context.speaker_volume is not None else 100)/100) if playing_speaker else (0 if args.speaker else None)
            if context.game_paused: combined['rumble']=[0,0]
            signature=json.dumps([combined,flags,playing_audio,speaker_volume],sort_keys=True)
            if signature!=sent:
                if output: output.send(combined,flags,audio_haptics=playing_audio,speaker_volume=speaker_volume)
                sent=signature
            if args.bridge and now-tick>.1:
                atomic(args.bridge/'status.json',dict(session=session,heartbeat=time.time(),connected=bool(output),simulation=args.dry_run,transport='USB',last_effect=last_effect,audio_haptics_connected=bool(audio and audio.stream.active and not audio.error),audio_haptics_active=playing_audio,speaker_connected=bool(args.speaker and audio and audio.stream.active and not audio.error),speaker_active=playing_speaker,audio_haptics_error=audio.error if audio else '',audio_haptics_underruns=audio.underruns if audio else 0,adaptive_exceed_active=pressed,adaptive_exceed_force=combined.get('left_trigger',[0,0])[1] if pressed else 0,adaptive_bringer_active=bringer,adaptive_bringer_force=combined.get('right_trigger',[0,0])[1] if bringer else 0,exceed_fire_active=fire and 'color' not in current_effect,input=state,capture=action_capture.status() if action_capture else {},finder=finder.status() if finder else {},pc_preview=pc_preview.status() if pc_preview else {}))
                tick=now
            m=profile_mtime
            if now-profile_check>=1:
                profile_check=now;m=profile_stamp(args.profile)
            if m!=profile_mtime:
                try:
                    updated=profile(args.profile); updated_clips=clips(updated,args.profile.parent) if args.audio_haptics else {}; updated_speaker=speaker_clips(updated,args.profile.parent) if args.speaker else {}
                    p=updated; audio_clips=updated_clips; speaker_samples=updated_speaker; profile_mtime=m; logging.info('Profile reloaded')
                except (ValueError,TypeError,KeyError,OSError,wave.Error): logging.exception('Invalid profile; previous retained'); profile_mtime=m
            time.sleep(.005)
    except KeyboardInterrupt: pass
    finally:
        try:
            if finder:finder.close()
            if action_capture:action_capture.close()
            if pc_preview:pc_preview.close()
            if native_input: native_input.close()
            if audio: audio.close()
            if output: output.close()
        finally:
            try:
                if args.bridge: atomic(args.bridge/'status.json',dict(session=session,heartbeat=time.time(),connected=False,last_effect='stopped'))
            finally: lifetime.close()
def main():
    args=arguments()
    if args.bridge: args.bridge.mkdir(parents=True,exist_ok=True)
    logging.basicConfig(level=logging.INFO if getattr(args,'verbose',False) or not args.bridge else logging.WARNING,format='%(asctime)s %(levelname)s %(message)s',handlers=[logging.StreamHandler(),RotatingFileHandler(ROOT/'helper.log',maxBytes=1048576,backupCount=1,encoding='utf-8')])
    if not args.bridge: return run(args)
    watch=GameLifetime(parent_pid=args.parent_pid)
    try:
        while watch.running():
            try:
                run(args)
                return
            except AlreadyRunning:
                logging.info('Helper already running; duplicate exits')
                return
            except (OSError,RuntimeError):
                logging.exception('Controller unavailable; retrying automatically')
                deadline=time.monotonic()+2
                while watch.running() and time.monotonic()<deadline: time.sleep(.05)
    except KeyboardInterrupt: pass
    finally: watch.close()

if __name__=='__main__': main()
