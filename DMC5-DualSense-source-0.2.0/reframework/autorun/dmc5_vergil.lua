-- Read-only Vergil weapon previews and Doppelganger state.
if reframework:get_game_name()~='dmc5' then return end
local V={state={},event=nil,error=nil}
_G.dmc5_vergil=V
local names={}
local td=sdk.find_type_definition('app.PlayerVergilPL.WeaponS')
if td then for _,f in ipairs(td:get_fields()) do local ok,v=pcall(function() return f:get_data(nil) end);if ok and type(v)=='number' then names[v]=f:get_name() end end end
local jce_finish_at,jce_finish_sent=nil,false
local jce_started,jce_sent,jce_baselined=nil,false,false
local pending_audio=nil
local jce_prep_sent=false
local pending_jc=nil
local last_jc=-1
local stinger_baselined=false
local stinger_phase=nil
local stinger_finish_sent=false
local pending_stinger_finish=nil
local pending_stinger_advance=nil
local stinger_advance_sent=false
local stinger_haptic_at=nil
local space_active=false
local space_sent=false
local space_baselined=false
local space_started_at=nil
local pending_space=nil
local space_effect_at=nil
local space_haptic_part=1
local function clear_space()
    space_active=false;space_sent=false;space_baselined=false;space_started_at=nil;pending_space=nil
    space_effect_at=nil;space_haptic_part=1
end
local function clear_stinger()
    stinger_baselined=false;stinger_phase=nil;stinger_finish_sent=false;pending_stinger_finish=nil
    pending_stinger_advance=nil;stinger_advance_sent=false;stinger_haptic_at=nil
end
local rapid_action=nil
local rapid_tick=-1
local beowulf_charge=nil
local charge_tick=-1
local previous_charge_level=nil
local consumed_charge_action=nil
function V.consume_charge_hit(action)
    if type(action)~='string' or action==consumed_charge_action or not action:find('BW_',1,true) then return nil end
    local lower=action:lower()
    local hit_phase=lower:find('charge_hit',1,true)~=nil
    if lower:find('charge',1,true) and not hit_phase then return nil end
    if not beowulf_charge or os.clock()>beowulf_charge.expires then return nil end
    local level=beowulf_charge.level;beowulf_charge=nil;consumed_charge_action=action;return level
end
local function is_rapid_attack(action)
    if type(action)~='string' then return false end
    for _,phase in ipairs({'YMT_ComboC_Loop','FE_Millionstab_Loop','FE_ComboB_2_Loop','FE_ComboB_3_Loop','BW_Lunarphase_Loop'}) do
        if action:find(phase,1,true) then return true end
    end
    return action:find('BW_Kick13',1,true)~=nil and action:find('Finish',1,true)==nil
end
local audio_hooks=false
local audio_action=nil
local function is_judgment_cut(action)
    return type(action)=='string' and (action:find('Yamato.YM_JudgeMentCut.',1,true)==1 or action:find('Yamato.YM_JudgeMentCutAerial.',1,true)==1)
end
local previous_sin=nil
local previous_sdt_ready=nil
local sdt_roar_at=nil
local world_baselined=false
local world_active=false
local world_sent=false
local world_started_at=nil
local world_effect_at=nil
local world_part=1
local hell_baselined,hell_active,hell_sent=false,false,false
local hell_started,hell_effect_at=nil,nil
local hell_part=1
local last_player,last_weapon,slots,previous_active,previous_delay=nil,nil,{},nil,nil
-- Only observed JCE weapon events; no offsets or writes to game state.
do
    local ok=pcall(function()
        local td=sdk.find_type_definition('via.wwise.WwiseContainer')
        if not td then return end
        for _,method in ipairs(td:get_methods()) do
            if method:get_name()=='trigger' and method:get_num_params()==2 then
                local params=method:get_param_types()
                local event_index=nil
                for i,param in ipairs(params) do if param:get_full_name()=='System.UInt32' then event_index=i+1;break end end
                if event_index then
                    sdk.hook(method,function(args)
                        local event=sdk.to_int64(args[event_index]) & 0xffffffff
                        if event~=4029849030 and event~=218237983 and event~=1611655846 and event~=1938484806 and event~=1844469120 and event~=1860346562 and event~=3626237035 then return end
                        pcall(function()
                            local action=audio_action
                            if event==3626237035 then
                                if last_player and type(action)=='string' and action:find('Yamato.YM_Spaceslash.',1,true)==1 then pending_space={player=last_player} end
                                return
                            end
                            if event==1844469120 or event==1860346562 then
                                if last_player and type(action)=='string' and action:find('Forceedge.FE_Deadly.FE_Stinger_',1,true)==1 then
                                    if event==1844469120 then pending_stinger_finish={player=last_player}
                                    else pending_stinger_advance={player=last_player} end
                                end
                                return
                            end
                            if last_player and event==1611655846 and is_judgment_cut(action) then
                                local now=os.clock()
                                if last_jc<0 or now-last_jc>=.12 then pending_jc={player=last_player};last_jc=now end
                                return
                            end
                            if not last_player or type(action)~='string' or action:find('Yamato.YM_JudgeMentCutEnd.',1,true)~=1 then return end
                            if event==1938484806 and action:find('YMT_Judgementcut_End_Start',1,true) then
                                pending_audio={player=last_player,kind='prepare'}
                            elseif event==4029849030 then
                                pending_audio={player=last_player,kind='slashes'}
                            elseif action:find('YMT_Judgementcut_End_Finish',1,true) then
                                pending_audio={player=last_player,kind='finish'}
                            end
                        end)
                    end,function(retval) return retval end)
                    audio_hooks=true
                end
            end
        end
    end)
    if not ok then audio_hooks=false end
end
function V.update(player,game_paused)
    V.state={};V.event=nil;V.error=nil
    if not player or player:get_type_definition():get_full_name()~='app.PlayerVergilPL' or tostring(player:get_address())~=last_player then
        previous_sdt_ready=nil
        sdt_roar_at=nil
        if hell_effect_at then V.state.hell_on_earth_cancel=true end
        hell_baselined=false;hell_active=false;hell_sent=false;hell_started=nil;hell_effect_at=nil;hell_part=1
        world_baselined=false;world_active=false;world_sent=false;world_started_at=nil;world_effect_at=nil;world_part=1
    end
    if not player or player:get_type_definition():get_full_name()~='app.PlayerVergilPL' then
        if (space_active and space_sent) or space_effect_at then V.state.space_slash_cancel=true end
        clear_space()
    end
    if not player or player:get_type_definition():get_full_name()~='app.PlayerVergilPL' then clear_stinger() end
    if not player or player:get_type_definition():get_full_name()~='app.PlayerVergilPL' then beowulf_charge=nil;charge_tick=-1;previous_charge_level=nil;consumed_charge_action=nil end
    if not player or player:get_type_definition():get_full_name()~='app.PlayerVergilPL' then rapid_action=nil;rapid_tick=-1 end
    if not player or player:get_type_definition():get_full_name()~='app.PlayerVergilPL' then jce_prep_sent=false end
    if not player or player:get_type_definition():get_full_name()~='app.PlayerVergilPL' then pending_jc=nil;last_jc=-1 end
    if not player or player:get_type_definition():get_full_name()~='app.PlayerVergilPL' then audio_action=nil;pending_audio=nil;jce_finish_at=nil;jce_finish_sent=false;jce_started=nil;jce_sent=false;jce_baselined=false;previous_sin=nil;last_player=nil;last_weapon=nil;slots={};previous_active=nil;previous_delay=nil;return end
    local ok,err=pcall(function()
        local id=tostring(player:get_address())
        if id~=last_player then
            if (space_active and space_sent) or space_effect_at then V.state.space_slash_cancel=true end
            clear_space()
        end
        if id~=last_player then clear_stinger() end
        if id~=last_player then beowulf_charge=nil;charge_tick=-1;previous_charge_level=nil;consumed_charge_action=nil end
        if id~=last_player then rapid_action=nil;rapid_tick=-1 end
        if id~=last_player then jce_prep_sent=false end
        if id~=last_player then pending_jc=nil;last_jc=-1 end
        if id~=last_player then audio_action=nil;pending_audio=nil;jce_finish_at=nil;jce_finish_sent=false;jce_started=nil;jce_sent=false;jce_baselined=false;previous_sin=nil;last_player=id;last_weapon=nil;previous_active=nil;previous_delay=nil end
        local current=player:call('get_currentWeaponS')
        if current~=last_weapon then
            slots={};local list=player:call('get_slotWeaponS');local count=list and list:call('get_Count')
            if type(count)=='number' and count>=0 and count<=16 then for i=0,count-1 do slots[#slots+1]=list:call('get_Item(System.Int32)',i) end end
            last_weapon=current
        end
        local found=nil
        for i,weapon in ipairs(slots) do if weapon==current then if found then found=nil;break end;found=i end end
        if found then
            -- Trace: L2 ChangeWeaponL16384 goes backwards; R2 ChangeWeaponS8192 forwards.
            V.state.next_l=names[slots[(found-2)%#slots+1]]
            V.state.next_r=names[slots[found%#slots+1]]
        end
        V.state.weapon=names[current]
        -- SDK gauge maximum verified from PlayerVergilPL: 10000.
        local gauge=player:call('get_theDTGauge')
        local pouring=player:call('get_isTheDTToPour')
        local sin=player:call('get_isTheDevilTrigger')
        V.state.sdt_active=sin==true
        local pad=player:call('get_padInput')
        local buttons=pad and pad:call('get_buttonOnFlags')
        if type(gauge)=='number' and gauge==gauge and gauge>=0 and gauge<=10000 then
            V.state.sdt_percent=gauge/10000
            local held=sin==false and type(buttons)=='number' and (buttons & 65536)~=0
            V.state.sdt_held=held and (pouring==true or gauge>=10000)
            local charge=player:call('get_theDevilGaugeCharge')
            local timer=player:call('get_devilTriggerPressTimer')
            if held and gauge>=10000 and (charge==1 or charge==2) and type(timer)=='number' and timer==timer then
                V.state.sdt_preparing=true
                V.state.sdt_progress=charge==2 and 1 or math.max(0,math.min(1,timer/90))
            end
            local ready=held and gauge>=10000 and charge==2
            V.state.sdt_ready=ready
            V.state.sdt_ready_entered=ready and previous_sdt_ready==false
            -- Live correlation: roar begins ~127ms after the ready state.
            -- Start 90ms later to allow bridge/audio output latency.
            if V.state.sdt_ready_entered then sdt_roar_at=os.clock()+.09 end
            if not ready or game_paused then sdt_roar_at=nil
            elseif sdt_roar_at and os.clock()>=sdt_roar_at then V.state.sdt_ready_sound=true;sdt_roar_at=nil end
            previous_sdt_ready=ready
            V.state.sdt_entered=sin==true and previous_sin==false
            V.state.sdt_exited=sin==false and previous_sin==true
            previous_sin=sin
        end
        local active=player:call('get_DoppelMode');local delay=player:call('get_CurrentDelayState')
        V.state.doppel=active==true
        if active==true and (delay==1 or delay==2 or delay==3) then V.state.delay=delay end
        if active==true and previous_active==false then V.event='vergil_doppel_enter'
        elseif active==true and previous_active==true and delay~=previous_delay and V.state.delay then V.event='vergil_doppel_mode_'..delay end
        previous_active=active;previous_delay=delay
        local action=player:call('get_nowActionNameFull')
        V.state.action=action
        local hell=type(action)=='string' and action:find('Beowulf.BW_Deadly.BW_Inferno',1,true)==1
        if not hell_baselined then
            hell_baselined=true;hell_active=hell;hell_sent=hell
        elseif hell and not hell_active then
            hell_started=os.clock();hell_sent=false;hell_effect_at=nil;hell_part=1
        end
        -- Original preparation starts 649ms after action entry; bridge allowance 40ms.
        if hell and not hell_sent and hell_started and not game_paused and os.clock()-hell_started>=.61 then
            V.state.hell_on_earth=true;hell_sent=true;hell_effect_at=os.clock();hell_part=1
        end
        if game_paused or (not hell and hell_active) then
            local natural=not game_paused and hell_started and os.clock()-hell_started>=6.2 and type(action)=='string' and action:find('BaseMove.Wait.',1,true)==1
            if not natural then
                if hell_effect_at then V.state.hell_on_earth_cancel=true end
                hell_effect_at=nil;hell_sent=true
            end
            hell_started=nil
        end
        hell_active=hell
        if hell_effect_at then
            local elapsed=os.clock()-hell_effect_at
            if elapsed>=5.8 then hell_effect_at=nil
            elseif elapsed>=hell_part*2 and hell_part<3 then
                hell_part=hell_part+1;V.state.hell_on_earth_haptic=hell_part
            end
        end
        local world=type(action)=='string' and action:find('VMode.',1,true)==1
        if not world_baselined then world_baselined=true;world_active=world;world_sent=world end
        if world and not world_active then
            world_sent=false
            world_started_at=action:find('Vmode_Start',1,true) and os.clock() or nil
        end
        -- Measured against the original waveform: onset 1.864s into Vmode_Start.
        -- Allow ~40ms for bridge polling and USB output startup.
        if world and not world_sent and world_started_at and os.clock()-world_started_at>=1.82 then
            V.state.world_of_v=true;world_sent=true;world_effect_at=os.clock();world_part=1
        end
        world_active=world
        if not world then world_started_at=nil end
        if world_effect_at then
            local elapsed=os.clock()-world_effect_at
            if elapsed>=4.713 then world_effect_at=nil
            elseif elapsed>=world_part*2 and world_part<3 then
                world_part=world_part+1;V.state.world_of_v_haptic=world_part
            end
        end
        local space=type(action)=='string' and action:find('Yamato.YM_Spaceslash.',1,true)==1
        if not space_baselined then
            space_baselined=true;space_active=space;space_sent=space
        elseif space and not space_active then
            space_sent=false;space_started_at=os.clock()
            space_effect_at=nil;space_haptic_part=1
        end
        if space and not space_sent and ((pending_space and pending_space.player==id) or (not audio_hooks and space_started_at and os.clock()-space_started_at>=.12)) then
            V.state.space_slash_start=true;space_sent=true
            space_effect_at=os.clock();space_haptic_part=1
        end
        if not space and space_active then
            -- Captured full animation lasts ~3.42s after the start sound.
            -- Preserve the glass decay on natural idle; cancel interrupted actions.
            local natural=space_effect_at and os.clock()-space_effect_at>=3.2 and type(action)=='string' and action:find('BaseMove.Wait.',1,true)==1
            if space_sent and not natural then V.state.space_slash_cancel=true;space_effect_at=nil end
            space_sent=false;space_started_at=nil
        end
        space_active=space;pending_space=nil
        if space_effect_at then
            local elapsed=os.clock()-space_effect_at
            if not space and type(action)=='string' and action:find('BaseMove.Wait.',1,true)~=1 then space_effect_at=nil
            elseif elapsed>=4.8 then space_effect_at=nil
            elseif elapsed>=space_haptic_part*2 and space_haptic_part<3 then
                space_haptic_part=space_haptic_part+1;V.state.space_slash_haptic=space_haptic_part
            end
        end
        local stinger=type(action)=='string' and action:find('Forceedge.FE_Deadly.FE_Stinger_',1,true)==1
        local phase=stinger and (action:find('FE_Stinger_Start',1,true) and 'start' or action:find('FE_Stinger_Finish',1,true) and 'finish' or 'loop') or nil
        if not stinger_baselined then
            -- Reloading scripts during an attack must not replay its beginning.
            stinger_baselined=true;stinger_phase=phase;stinger_finish_sent=stinger
            stinger_advance_sent=stinger
        elseif phase=='start' and stinger_phase~='start' then
            V.state.deep_stinger_start=true;stinger_finish_sent=false
            stinger_advance_sent=false;stinger_haptic_at=nil
        end
        if stinger and not stinger_advance_sent and not stinger_finish_sent and phase~='finish' and ((pending_stinger_advance and pending_stinger_advance.player==id) or (not audio_hooks and phase=='loop')) then
            V.state.deep_stinger_advance=true;stinger_advance_sent=true;stinger_haptic_at=os.clock()
        elseif phase=='loop' and stinger_haptic_at and os.clock()-stinger_haptic_at>=1.95 then
            V.state.deep_stinger_advance_haptic=true;stinger_haptic_at=os.clock()
        end
        if stinger and not stinger_finish_sent and ((pending_stinger_finish and pending_stinger_finish.player==id) or (not audio_hooks and phase=='finish' and stinger_phase~='finish')) then
            V.state.deep_stinger_finish=true;stinger_finish_sent=true
        end
        if not stinger then
            if stinger_phase and stinger_phase~='finish' and not stinger_finish_sent then V.state.deep_stinger_cancel=true end
            stinger_finish_sent=false;stinger_advance_sent=false;stinger_haptic_at=nil
        end
        if phase=='finish' then stinger_haptic_at=nil;V.state.deep_stinger_advance_haptic=nil end
        stinger_phase=phase;pending_stinger_finish=nil;pending_stinger_advance=nil
        if action~=consumed_charge_action then consumed_charge_action=nil end
        local charging=type(action)=='string' and action:find('BW_',1,true) and action:lower():find('charge',1,true)~=nil and not action:lower():find('charge_hit',1,true)
        if charging then
            local level_ok,level=pcall(function()
                local checker=player:call('get_BeowulfCharge')
                return checker and checker:call('get_currentLevel')
            end)
            if not level_ok or type(level)~='number' or level~=level or level<0 or level>3 then level=nil end
            V.state.beowulf_charge_level=level
            V.state.beowulf_charging=true
            local current=level or 0
            local now=os.clock()
            beowulf_charge={level=current,charging=true,expires=now+1.5}
            if previous_charge_level~=nil and current>previous_charge_level then
                V.state.charge_event='vergil_beowulf_charge_level_'..current;charge_tick=now+.08
            elseif charge_tick<0 or now-charge_tick>=.12 then
                V.state.charge_event='vergil_beowulf_charge_hold_'..current;charge_tick=now
            end
            previous_charge_level=current
        else
            if beowulf_charge and beowulf_charge.charging then beowulf_charge.charging=false;beowulf_charge.expires=os.clock()+1.5 end
            if beowulf_charge and (type(action)~='string' or not action:find('BW_',1,true) or os.clock()>beowulf_charge.expires) then beowulf_charge=nil end
            charge_tick=-1;previous_charge_level=nil
        end
        audio_action=action
        if is_rapid_attack(action) then
            local now=os.clock()
            if rapid_action~=action or now-rapid_tick>=.09 then V.state.rapid_attack=true;rapid_tick=now end
            rapid_action=action
        else rapid_action=nil;rapid_tick=-1 end
        if pending_jc and pending_jc.player==id and is_judgment_cut(action) then V.state.judgment_cut=true end
        pending_jc=nil
        local jce=type(action)=='string' and action:find('Yamato.YM_JudgeMentCutEnd.',1,true)==1
        if not jce_baselined then jce_baselined=true;jce_sent=jce end
        if jce then
            jce_started=jce_started or os.clock()
            -- Recorded slash reference begins about 1.8 s after attack entry.
            if not audio_hooks and not jce_sent and os.clock()-jce_started>=1.8 then V.state.jce_slashes=true;jce_sent=true end
            local finishing=action:find('YMT_Judgementcut_End_Finish',1,true)~=nil
            if finishing then
                jce_finish_at=jce_finish_at or os.clock()
                -- Sheath/remnant audio event recorded about 1.4 s into Finish.
                if not audio_hooks and not jce_finish_sent and os.clock()-jce_finish_at>=1.4 then V.state.jce_finish=true;jce_finish_sent=true end
            end
            if pending_audio and pending_audio.player==id then
                if pending_audio.kind=='prepare' and not jce_prep_sent and not jce_sent then V.state.jce_prepare=true;jce_prep_sent=true
                elseif pending_audio.kind=='slashes' and not jce_sent then V.state.jce_slashes=true;jce_sent=true
                elseif pending_audio.kind=='finish' and not jce_finish_sent then V.state.jce_finish=true;jce_finish_sent=true end
                pending_audio=nil
            end
        else jce_prep_sent=false;pending_audio=nil;jce_started=nil;jce_sent=false;jce_finish_at=nil;jce_finish_sent=false end
    end)
    if not ok then audio_action=nil;pending_audio=nil;jce_finish_at=nil;jce_finish_sent=false;jce_started=nil;jce_sent=false;jce_baselined=false;V.state={};previous_active=nil;previous_delay=nil;previous_sin=nil;V.error=tostring(err) end
    if not ok then jce_prep_sent=false end
    if not ok then rapid_action=nil;rapid_tick=-1 end
    if not ok then beowulf_charge=nil;charge_tick=-1;previous_charge_level=nil;consumed_charge_action=nil end
    if not ok then clear_stinger() end
    if not ok then clear_space() end
    if not ok then previous_sdt_ready=nil;sdt_roar_at=nil end
    if not ok then world_baselined=false;world_active=false;world_sent=false;world_started_at=nil;world_effect_at=nil end
end
function V.draw()
    imgui.text('Arma: '..tostring(V.state.weapon))
    imgui.text('Proxima L2: '..tostring(V.state.next_l)..' / R2: '..tostring(V.state.next_r))
    imgui.text('Doppelganger: '..tostring(V.state.doppel)..' / modo: '..tostring(({[1]='Rapido',[2]='Normal',[3]='Lento'})[V.state.delay]))
    imgui.text('Sin DT: '..math.floor((V.state.sdt_percent or 0)*100)..'% / carga manual: '..tostring(V.state.sdt_held==true))
    if V.error then imgui.text(V.error) end
end
