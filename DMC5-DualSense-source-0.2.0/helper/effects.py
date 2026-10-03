"""Compose timed feedback with a separately renewed Nero/L2 context."""
import math

def fire_color(now, settings, stock=3):
    # 20 Hz quantization: warm flicker that never blacks out or floods USB writes.
    phase = math.floor(now * 20) / 20
    glow = .5 + .30 * math.sin(phase * 7.1) + .20 * math.sin(phase * 17.3 + 1.2)
    low = settings.get('low_color', [175, 35, 0])
    high = settings.get('high_color', [255, 145, 4])
    brightness = settings.get('brightness_by_stock', [0, .30, .65, 1.0])[max(0,min(3,int(stock)))]
    return [round((a + (b-a)*glow)*brightness) for a,b in zip(low,high)]

class ExceedContext:
    def __init__(self):
        self.game_paused=False
        self.sdt_luce_hits=None;self.sdt_luce_hit_session=None;self.sdt_luce_pulse_until=0
        self.sdt_phase=0;self.sdt_phase_at=None
        self.token = None
        self.renewed = float('-inf')
        self.allowed = False
        self.stock = 0
        self.held = False
        self.peak_stock = 0
        self.fire_allowed = False
        self.bringer_allowed = False
        self.lock_on = False
        self.haptics_allowed = False; self.speaker_allowed = False
        self.maximum_bet_charging = False
        self.speaker_volume = None
        self.dante_next_l=None; self.dante_next_s=None
        self.sdt_active=False;self.sdt_action='';self.sdt_held=False;self.sdt_percent=0;self.sdt_preparing=False;self.sdt_progress=0;self.sdt_transforming=False;self.doppel_delay=None;self.vergil_sdt_held=False;self.vergil_sdt_percent=0;self.vergil_sdt_preparing=False;self.vergil_sdt_progress=0

    def update(self, data, session, now):
        self.game_paused=False
        self.speaker_volume = None
        self.dante_next_l=None; self.dante_next_s=None
        self.sdt_active=False;self.sdt_action='';self.sdt_held=False;self.sdt_percent=0;self.sdt_preparing=False;self.sdt_progress=0;self.sdt_transforming=False;self.doppel_delay=None;self.vergil_sdt_held=False;self.vergil_sdt_percent=0;self.vergil_sdt_preparing=False;self.vergil_sdt_progress=0
        if not isinstance(data, dict) or data.get('session') != session:
            self.allowed = False
            self.fire_allowed = False
            self.bringer_allowed = False
            self.haptics_allowed = False; self.speaker_allowed = False
            self.maximum_bet_charging = False
            return
        token = (data.get('session'), data.get('tick'))
        if token != self.token and type(data.get('tick')) is int:
            self.token = token
            self.renewed = now
        self.allowed = data.get('adaptive_exceed') is True
        self.fire_allowed = data.get('exceed_fire') is True
        self.bringer_allowed = data.get('adaptive_bringer') is True
        self.lock_on = data.get('lock_on') is True
        self.haptics_allowed = data.get('haptics') is True
        self.speaker_allowed = data.get('speaker') is True
        self.game_paused = data.get('game_paused') is True
        volume = data.get('speaker_volume')
        if type(volume) is int and 0 <= volume <= 100:
            self.speaker_volume = volume
        self.maximum_bet_charging = data.get('maximum_bet_charging') is True
        self.sdt_active=data.get('dante_sdt_active') is True
        self.sdt_action=data.get('dante_sdt_action','') if isinstance(data.get('dante_sdt_action'),str) else ''
        if self.sdt_luce_hit_session!=session:self.sdt_luce_pulse_until=0
        hits=data.get('dante_sdt_luce_hits')
        if type(hits) is int and hits>=0:
            if self.sdt_luce_hit_session==session and self.sdt_luce_hits is not None and hits>self.sdt_luce_hits and self.sdt_active and not self.game_paused:
                self.sdt_luce_pulse_until=now+.09
            self.sdt_luce_hits=hits;self.sdt_luce_hit_session=session
        if not self.sdt_active or self.game_paused:self.sdt_luce_pulse_until=0
        self.sdt_transforming=data.get('dante_sdt_transforming') is True
        self.sdt_preparing=data.get('dante_sdt_preparing') is True
        progress=data.get('dante_sdt_progress')
        self.sdt_progress=progress if type(progress) in (int,float) and 0<=progress<=1 else 0
        self.sdt_held=data.get('dante_sdt_held') is True
        percent=data.get('dante_sdt_percent')
        self.sdt_percent=percent if type(percent) in (int,float) and 0<=percent<=1 else 0
        self.vergil_sdt_preparing=data.get('vergil_sdt_preparing') is True
        progress=data.get('vergil_sdt_progress')
        self.vergil_sdt_progress=progress if type(progress) in (int,float) and 0<=progress<=1 else 0
        if self.vergil_sdt_preparing:
            self.sdt_preparing=True;self.sdt_progress=self.vergil_sdt_progress
        self.vergil_sdt_held=data.get('vergil_sdt_held') is True
        percent=data.get('vergil_sdt_percent')
        self.vergil_sdt_percent=percent if type(percent) in (int,float) and 0<=percent<=1 else 0
        self.doppel_delay=data.get('vergil_doppel_delay')
        self.dante_next_l=data.get('dante_next_l')
        self.dante_next_s=data.get('dante_next_s')
        stock = data.get('exceed_stock', 0)
        self.stock = int(stock) if type(stock) in (int, float) and 0 <= stock <= 3 else 0

    def pressed(self, state, now, input_fresh=True):
        triggers = state.get('triggers', [])
        pressed = bool(input_fresh and self.allowed and now-self.renewed < .75
                       and len(triggers) == 2 and triggers[0] >= (12 if self.held else 40))
        if pressed:
            self.peak_stock = max(self.peak_stock if self.held else 0, self.stock)
        else:
            self.peak_stock = 0
        self.held = pressed
        return pressed

    def fire_active(self, now):
        return self.fire_allowed and self.stock > 0 and now-self.renewed < .75

    def bringer_ready(self, now, input_fresh=True):
        return self.bringer_allowed and input_fresh and now-self.renewed < .75

    def weapon_preview(self, effect, flags, settings, now, input_fresh=True):
        effect=dict(effect);flags=dict(flags)
        if not input_fresh or now-self.renewed>=.75 or settings.get('enabled') is not True:
            return effect,flags
        for kind,name,key in [('L',self.dante_next_l,'left_trigger'),('S',self.dante_next_s,'right_trigger')]:
            config=settings.get(kind,{}).get(name) if isinstance(name,str) else None
            if config and key not in effect:
                effect[key+'_preview']=config;flags['triggers']=True
        return effect,flags

    def sdt_triggers(self,effect,flags,settings,now,input_fresh=True):
        effect=dict(effect);flags=dict(flags)
        if not self.sdt_active or self.game_paused or not input_fresh or now-self.renewed>=.75 or settings.get('enabled') is not True:
            return effect,flags
        action=self.sdt_action.lower()
        for key,move in (('left_trigger','demolition'),('right_trigger','luce')):
            config=settings.get(move,{})
            performing=(now<self.sdt_luce_pulse_until) if move=='luce' else (move in action and not action.endswith(('.end','.finish')))
            selected=config.get('active') if performing else config.get('idle')
            if selected:
                effect.pop(key,None);effect[key+'_preview']=selected;flags['triggers']=True
        return effect,flags

    def vergil_sdt_led(self,effect,flags,now,input_fresh=True):
        effect=dict(effect);flags=dict(flags)
        if self.vergil_sdt_held and input_fresh and now-self.renewed<.75 and 'color' not in effect:
            progress=self.vergil_sdt_progress if self.vergil_sdt_preparing else 0
            color=[0,25+230*progress,255]
            brightness=self.vergil_sdt_percent
            if self.vergil_sdt_preparing:
                brightness*=.4+.6*(1+math.sin(2*math.pi*(2+5*progress)*math.floor(now*20)/20))/2
            effect['color']=[round(c*brightness) for c in color]
            flags['lightbar']=True
        return effect,flags

    def doppel_led(self,effect,flags,settings,now,input_fresh=True):
        effect=dict(effect);flags=dict(flags)
        color=settings.get('colors',{}).get(str(self.doppel_delay))
        if color and input_fresh and now-self.renewed<.75 and settings.get('enabled') is True and 'color' not in effect:
            effect['color']=[round(c*settings.get('brightness',.35)) for c in color];flags['lightbar']=True
        return effect,flags

    def sdt_led(self,effect,flags,settings,now,input_fresh=True):
        effect=dict(effect);flags=dict(flags)
        if self.sdt_held and input_fresh and now-self.renewed<.75 and settings.get('enabled') is True and 'color' not in effect:
            brightness=self.sdt_percent
            if self.sdt_preparing:
                led_time=math.floor(now*20)/20
                dt=max(0,min(.1,led_time-self.sdt_phase_at)) if self.sdt_phase_at is not None else 0
                self.sdt_phase=(self.sdt_phase+(2+5*self.sdt_progress)*dt)%1
                self.sdt_phase_at=led_time
                brightness*=.25+.75*(1+math.sin(2*math.pi*self.sdt_phase))/2
            else: self.sdt_phase=0;self.sdt_phase_at=None
            color=settings.get('color',[255,0,0])
            if self.sdt_preparing:
                target=settings.get('preparation_color',[255,160,0])
                color=[a+(b-a)*self.sdt_progress for a,b in zip(color,target)]
            effect['color']=[round(c*brightness) for c in color]
            flags['lightbar']=True
        return effect,flags

def compose(effect, toggles, pressed, settings, stock=0, fire=False, now=0, fire_settings=None, fire_stock=3, bringer=False, bringer_settings=None, lock_on=False, elapsed=0):
    result = dict(effect)
    flags = dict(toggles)
    if result.get('led_pulses') and 'color' in result:
        phase=math.floor(max(0,elapsed)*20)/20 * result['led_pulses'] / (result['duration_ms']/1000)
        glow=(1+math.cos(2*math.pi*phase))/2
        result['color']=[round(c*glow) for c in result['color']]
    if bringer and 'right_trigger' not in result:
        config = bringer_settings or {}
        result['right_trigger'] = config.get('snatch_trigger' if lock_on else 'buster_trigger', [5, 190] if lock_on else [25, 160])
        flags['triggers'] = True
    if fire and 'color' not in result:
        result['color'] = fire_color(now, fire_settings or {}, fire_stock)
        flags['lightbar'] = True
    if pressed:
        # Timed effects retain rumble/RGB/R2 while L2 stays independently owned.
        result['left_trigger'] = settings.get('left_trigger', [45, 35])
        forces = settings.get('force_by_stock')
        if forces:
            result['left_trigger'] = [result['left_trigger'][0], forces[max(0,min(3,int(stock)))]]
        flags['triggers'] = True
    return result, flags
