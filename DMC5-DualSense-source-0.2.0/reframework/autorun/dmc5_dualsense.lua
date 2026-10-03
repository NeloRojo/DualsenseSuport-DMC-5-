-- Read-only SDK integration. No memory offsets or game writes.
if reframework:get_game_name() ~= 'dmc5' then return end
local dir='dmc5_dualsense/'
local function normalize(cfg)
    cfg=type(cfg)=='table' and cfg or {}
    for _,key in ipairs({'enabled','rumble','haptics','speaker','lightbar','triggers','exceed','exceed_hits','normal_sword_hits','enemy_step','adaptive_exceed','exceed_fire','bringer','adaptive_bringer','devil_trigger','nero_specials','max_act','parry','dante_weapons','dante_normal_hits','dante_normal_block','dante_royal_block','dante_royal_release','dante_normal_release','dante_devil_counter','dante_gunfire','dante_devil_trigger','dante_sdt_charge','dante_sdt_transform','dante_sdt_attacks','dante_sdt_triggers','vergil_weapons','vergil_doppel','vergil_sdt_charge','vergil_sdt_transform','vergil_specials','vergil_normal_hits','vergil_beowulf_charge'}) do
        if type(cfg[key])~='boolean' then cfg[key]=true end
    end
    if type(cfg.hp_path)~='table' then cfg.hp_path={} end
    if type(cfg.speaker_volume)~='number' or cfg.speaker_volume~=cfg.speaker_volume then cfg.speaker_volume=100 end
    cfg.speaker_volume=math.floor(math.max(0,math.min(100,cfg.speaker_volume)))
    return cfg
end
local cfg=normalize(json.load_file(dir..'config.json'))
local function draw_speaker_volume()
    local changed,value=imgui.slider_int('Volumen del altavoz (%)',cfg.speaker_volume,0,100)
    if changed then cfg.speaker_volume=value;json.dump_file(dir..'config.json',cfg) end
end
local inspect_player=false
local seq=0
local previous_player=nil
local previous_hp=nil
local previous_exceed=nil
local exceed_text='unavailable'
local devil_trigger=nil
local dt_gauge=nil
local previous_dt=nil
local previous_dante_dt=nil
local previous_dante_sdt=nil
local dante_dt=nil
local dante_sdt=nil
local bringer={}
local previous_bringer={}
local pending_buster=false
local pending_maxact=false
local maxact_count=0
local maxact_hook_error=''
local pending_parry=false
local parry_count=0
local parry_error=''
local parry_last={}
local last_parry=-1
local bind_parry
local parry_ok,parry_err=pcall(function()
    local results=sdk.find_type_definition('app.HitController.ParryResultEnum')
    local win=results and results:get_field('Win')
    win=win and win:get_data(nil)
    if win~=0 then error('Unexpected sword parry result enum') end
    local bound={}
    bind_parry=function(td)
    if not td then return end
    local method=td:get_method('setParryAction')
    if not method then return end
    local params=method:get_param_types()
    if method:get_num_params()~=2 or #params~=2 or params[1]:get_full_name()~='app.HitController.ParryResultEnum' or params[2]:get_full_name()~='app.HitController.ParryData' or method:get_return_type():get_full_name()~='System.Void' then error('Unexpected shared parry SDK signature') end
    local identity=tostring(method:get_function())
    if bound[identity] then return end
    sdk.hook(method,function(args)
        if not cfg.enabled or cfg.parry==false or sdk.to_int64(args[3])~=win then return end
        local ok,err=pcall(function()
            local owner=sdk.to_managed_object(args[2])
            if not owner or tostring(owner:get_address())~=previous_player then return end
            local action=owner:call('get_nowActionNameFull')
            local character=owner:get_type_definition():get_full_name()
            local melee_ok,melee=pcall(function() return owner:call('get_isShortRangeAttack') end)
            local sword=character=='app.PlayerNero' and type(action)=='string' and (action:match('^RedQueenCombo%.') or action:match('^RedQueenSkill%.'))
            local true_parry
            local data_ok,data=pcall(sdk.to_managed_object,args[4])
            if data_ok and data then
                local read_ok,value=pcall(function() return data:get_field('<isTrueParry>k__BackingField') end)
                if read_ok and type(value)=='boolean' then true_parry=value end
            end
            local accepted=sword or (character~='app.PlayerNero' and melee_ok and melee==true and true_parry==true)
            parry_last={character=character,action=action,true_parry=true_parry,short_range=melee_ok and melee or false,accepted=not not accepted}
            if not accepted then return end
            local now=os.clock()
            if now-last_parry<.08 then return end
            last_parry=now; pending_parry=true; parry_count=parry_count+1
        end)
        if not ok then parry_error=tostring(err) end
    end,function(retval) return retval end)
    bound[identity]=true
    end
    for _,name in ipairs({'app.Player','app.PlayerNero','app.PlayerDante'}) do bind_parry(sdk.find_type_definition(name)) end
end)
if not parry_ok then parry_error=tostring(parry_err) end
local pending_showdown_hit=false
local showdown_hits=0
local pending_normal_hit=false
local last_normal_contact=-1
local pending_vergil_hit=false
local last_vergil_contact=-1
local last_vergil_finisher=nil
local vergil_strong_until=0
local vergil_last_finisher_effect='none'
local pending_exceed_hit=false
local exceed_hits=0
local sword_contacts={}
local function ex_skill_effect(action)
    local skill=action:match('^RedQueenSkill%.([^%.]+)')
    if not skill then return nil end
    if skill:match('^ExHighRollerLv[1234]$') then return 'ex_high_roller_hit' end
    if skill=='ExStreak' then return 'ex_streak_hit' end
    if skill:match('^ExCalibarLv[1234]$') then return 'ex_calibur_hit' end
    if skill:match('^ExSplitLv[1234]$') then return 'ex_double_down_hit' end
    if skill:match('^ExShuffleLv[1234]$') then return 'ex_shuffle_hit' end
    if skill:match('^ExKillerBeeLv[123]$') then return 'ex_payline_hit' end
end
local special_action=nil
local previous_special_action=nil
local previous_enemy_step=nil
local function is_enemy_step(action)
    if type(action)~="string" then return false end
    for part in action:gmatch("[^%.]+") do
        local name=part:lower()
        if name=="enemystepup" or name=="enemystep" then return true end
    end
    return false
end
local previous_maxbet_level=nil
local pending_maxbet_level=nil
local special_hook_error=''
local buster_starts=0
local buster_hook_error=''
local status={}
local local_pad=nil
local lock_on=false
local buster_input={calls=0,depth=0,max_depth=0}
local lock_mask
local input_hook_ok,input_hook_err=pcall(function()
    local td=sdk.find_type_definition('app.PadInput')
    local method=td and td:get_method('update')
    if not method or method:get_return_type():get_full_name()~='System.Void' or method:get_num_params()~=0 then error('PadInput update unavailable') end
    lock_mask=td:get_field('LockOn'):get_data(nil)
    if type(lock_mask)~='number' then error('Input mask unavailable') end
    for _,name in ipairs({'get_analogR','get_buttonOnFlags'}) do
        if not td:get_method(name) then error('Input SDK method unavailable: '..name) end
    end
    sdk.hook(method,function(args)
        local ok,owner=pcall(function() return sdk.to_managed_object(args[2]) end)
        thread.get_hook_storage().buster_pad=ok and owner and tostring(owner:get_address())==local_pad and owner or nil
    end,function(retval)
        local pad=thread.get_hook_storage().buster_pad
        if not pad then return retval end
        local ok,err=pcall(function()
            buster_input.calls=buster_input.calls+1
            local depth=pad:call('get_analogR')
            local on=pad:call('get_buttonOnFlags')
            lock_on=(on & lock_mask)~=0
            buster_input.depth=depth
            if type(depth)~='number' or depth~=depth or depth<0 or depth>1 then return end
            buster_input.max_depth=math.max(buster_input.max_depth,depth)
        end)
        if not ok then buster_input.error=tostring(err) end
        return retval
    end)
end)
if not input_hook_ok then buster_input.error=tostring(input_hook_err) end
local hook_ok,hook_err=pcall(function()
    local td=sdk.find_type_definition('app.PlayerNero')
    -- This overload was observed during a real local-player Buster.
    local method=td and td:get_method('setUniqueBuster')
    if not method then error('Buster SDK method unavailable') end
    sdk.hook(method,function(args)
        local ok,owner=pcall(function() return sdk.to_managed_object(args[2]) end)
        if ok and owner and cfg.enabled and cfg.bringer and tostring(owner:get_address())==previous_player then
            pending_buster=true; buster_starts=buster_starts+1
        end
    end,function(retval) return retval end)
end)
if not hook_ok then buster_hook_error=tostring(hook_err); log.info('[DualSense Buster hook] '..buster_hook_error) end
local maxact_ok,maxact_err=pcall(function()
    local td=sdk.find_type_definition('app.PlayerNero')
    local method=td and td:get_method('setMaxAct')
    if not method or method:get_num_params()~=1 or method:get_param_types()[1]:get_full_name()~='System.Boolean' or method:get_return_type():get_full_name()~='System.Void' then error('Unexpected MAX-Act SDK signature') end
    sdk.hook(method,function(args)
        local storage=thread.get_hook_storage();storage.dualsense_maxact_owner=nil
        if not cfg.enabled or not cfg.max_act or sdk.to_int64(args[3])==0 then return end
        local ok,owner=pcall(function() return sdk.to_managed_object(args[2]) end)
        if ok and owner and tostring(owner:get_address())==previous_player then storage.dualsense_maxact_owner=owner end
    end,function(retval)
        local storage=thread.get_hook_storage();local owner=storage.dualsense_maxact_owner;storage.dualsense_maxact_owner=nil
        if owner then
            local ok,stock=pcall(function() return owner:call('get_exceedStock') end)
            if ok and stock==3 then pending_maxact=true;maxact_count=maxact_count+1 end
        end
        return retval
    end)
end)
if not maxact_ok then maxact_hook_error=tostring(maxact_err);log.info('[DualSense MAX-Act hook] '..maxact_hook_error) end
local special_ok,special_err=pcall(function()
    local td=sdk.find_type_definition('app.Player')
    local method=td and td:get_method('onAtkCalcDamageEnd')
    if not method or method:get_num_params()~=1 or method:get_param_types()[1]:get_full_name()~='app.HitController.DamageInfo' or method:get_return_type():get_full_name()~='System.Void' then error('Unexpected Showdown hit signature') end
    sdk.hook(method,function(args)
        if not cfg.enabled then return end
        local ok,err=pcall(function()
            local owner=sdk.to_managed_object(args[2])
            if not owner or tostring(owner:get_address())~=previous_player then return end
            if owner:get_type_definition():get_full_name()=='app.PlayerDante' then
                if dmc5_dante_combat then dmc5_dante_combat.on_hit(owner) end
                return
            end
            if owner:get_type_definition():get_full_name()=='app.PlayerVergilPL' then
                if not cfg.vergil_normal_hits and not cfg.vergil_beowulf_charge then return end
                local action=owner:call('get_nowActionNameFull')
                if cfg.vergil_beowulf_charge and dmc5_vergil and dmc5_vergil.consume_charge_hit then
                    local level=dmc5_vergil.consume_charge_hit(action)
                    if level then
                        pending_vergil_hit='vergil_beowulf_charge_hit_'..level;vergil_strong_until=os.clock()+.40
                        vergil_last_finisher_effect=pending_vergil_hit;last_vergil_contact=os.clock();return
                    end
                end
                if not cfg.vergil_normal_hits then return end
                -- Judgment Cut effects are driven by their own audio events.
                if type(action)~='string' or action:lower():find('judgementcut',1,true) then return end
                local finisher=nil
                for phase,effect in pairs({YMT_ComboD_2_DT='yamato_d',YMT_ComboE_DT='yamato_e',YMT_ComboC_Finish='yamato_c',FE_ComboA_3='mirage_a',FE_ComboB_3_Finish='mirage_b',BW_Kick13_Finish='beowulf_kick',BW_Backwardkick_DT='beowulf_back',BW_Tornadokick='beowulf_tornado'}) do
                    local leaf=action:match('([^.]+)$') or action
                    if leaf==phase or leaf:sub(1,#phase+1)==phase..' ' then finisher='vergil_sdt_finish_'..effect;break end
                end
                local sin_ok,sin=pcall(function() return owner:call('get_isTheDevilTrigger') end)
                if sin_ok and sin==true and finisher then
                    if last_vergil_finisher~=action then
                        pending_vergil_hit=finisher;last_vergil_finisher=action;last_vergil_contact=os.clock()
                        vergil_strong_until=os.clock()+.30;vergil_last_finisher_effect=finisher
                    end
                    return
                end
                local short_ok,short=pcall(function() return owner:call('get_isShortRangeAttack') end)
                local now=os.clock()
                if now<vergil_strong_until then return end
                local gap=now-last_vergil_contact
                if short_ok and short==true and gap>=.025 then
                    pending_vergil_hit=(last_vergil_contact>=0 and gap<=.24) and 'vergil_combo_hit' or 'vergil_normal_hit'
                    last_vergil_contact=now
                end
                return
            end
            if owner:get_type_definition():get_full_name()~='app.PlayerNero' then return end
            local action=owner:call('get_nowActionNameFull')
            if cfg.nero_specials and type(action)=='string' and action:find('RedQueenSkill.ShowDown.RQ_Skill_Showdown_Success',1,true)==1 then
                pending_showdown_hit=true; showdown_hits=showdown_hits+1
            end
            if type(action)=='string' and action:find('RedQueen',1,true)==1 and not action:find('RedQueenSkill.ShowDown.',1,true) and not action:find('RedQueenSkill.MaximumBet.',1,true) then
                local level_ok,level=pcall(function() return owner:call('get_exceedLevel') end)
                local stock_ok,stock=pcall(function() return owner:call('get_exceedStock') end)
                local short_ok,short=pcall(function() return owner:call('get_isShortRangeAttack') end)
                table.insert(sword_contacts,{action=action,level=level_ok and level or nil,stock=stock_ok and stock or nil,short_range=short_ok and short or false,time=os.clock()})
                if #sword_contacts>30 then table.remove(sword_contacts,1) end
                local ex_effect=ex_skill_effect(action)
                -- Double Down's observed contact can report short-range=false.
                -- Its exact EX action plus this local-player contact hook identifies it.
                if cfg.exceed_hits and ex_effect and ((short_ok and short==true) or ex_effect=='ex_double_down_hit') then
                    -- EX skills consume stock before contact; classify their exact
                    -- SDK action identity rather than a generic stock decrease.
                    pending_exceed_hit=ex_effect; exceed_hits=exceed_hits+1
                elseif cfg.exceed_hits and short_ok and short==true and level_ok and type(level)=='number' and level>=1 and level<=3 then
                    pending_exceed_hit='exceed_hit'; exceed_hits=exceed_hits+1
                elseif cfg.normal_sword_hits and not ex_effect and not action:match('^RedQueenSkill%.Ex') and short_ok and short==true and level_ok and level==0 and os.clock()-last_normal_contact>=.08 then
                    pending_normal_hit=true;last_normal_contact=os.clock()
                end
            end
        end)
        if not ok then special_hook_error=tostring(err) end
    end,function(retval) return retval end)
end)
if not special_ok then special_hook_error=tostring(special_err) end
local function timer_started(value,previous)
    return type(value)=='number' and type(previous)=='number' and value>0 and (previous<=0 or value>previous+0.5)
end
local last_event='none'
local error_text=''
local last_poll=0
local diagnostic_player=nil
local last_telemetry=0
local control_tick=0
local game_paused=false
local function read_game_pause()
    local ok,value=pcall(function()
        local manager=sdk.get_managed_singleton('app.GameManager')
        return manager and manager:call('get_isPause')==true
    end)
    return ok and value==true
end
local function maximum_bet_preparing(action)
    return action=='RedQueenSkill.MaximumBet.RQ_Skill_Maxbet_Set' or action=='RedQueenSkill.MaximumBet.RQ_Skill_Maxbet_Charge'
end
local function control(allowed,stock,has_player)
    control_tick=control_tick+1
    local audio_allowed=has_player==true or stock~=nil
    local weapons=dmc5_dante_weapons and dmc5_dante_weapons.state or {}
    local preview=cfg.enabled and cfg.triggers and cfg.dante_weapons and has_player==true
    local vergil=dmc5_vergil and dmc5_vergil.state or {}
    local vergil_preview=cfg.enabled and cfg.triggers and cfg.vergil_weapons and has_player==true
    local sdt=dmc5_dante_sdt
    local sdt_held=cfg.enabled and cfg.lightbar and cfg.dante_sdt_charge and has_player==true and sdt and sdt.held or false
    if sdt and sdt.active then preview=false end
    local next_l=preview and weapons.L and weapons.L.next and weapons.L.next.name or nil
    local next_s=preview and weapons.S and weapons.S.next and weapons.S.next.name or nil
    if vergil_preview then next_l=vergil.next_l or next_l;next_s=vergil.next_r or next_s end
    local doppel_delay=cfg.enabled and cfg.lightbar and cfg.vergil_doppel and has_player==true and vergil.doppel and vergil.delay or nil
    json.dump_file(dir..'control.json',{game_paused=game_paused,speaker_volume=cfg.speaker_volume,vergil_sdt_preparing=cfg.enabled and cfg.vergil_sdt_transform and vergil.sdt_preparing==true,vergil_sdt_progress=vergil.sdt_progress or 0,vergil_sdt_held=cfg.enabled and cfg.lightbar and cfg.vergil_sdt_charge and has_player==true and vergil.sdt_held==true,vergil_sdt_percent=vergil.sdt_percent or 0,vergil_doppel_delay=doppel_delay,session=status.session,tick=control_tick,dante_sdt_active=cfg.enabled and cfg.triggers and cfg.dante_sdt_triggers and sdt and sdt.active or false,dante_sdt_luce_hits=dmc5_dante_combat and dmc5_dante_combat.state.sdt_luce_hits or 0,dante_sdt_action=sdt and sdt.action or '',dante_sdt_transforming=cfg.enabled and cfg.dante_sdt_transform and sdt and sdt.transforming or false,dante_sdt_preparing=cfg.enabled and cfg.dante_sdt_transform and sdt and sdt.preparing or false,dante_sdt_progress=sdt and sdt.progress or 0,dante_sdt_held=sdt_held,dante_sdt_percent=sdt and sdt.percent or 0,dante_next_l=next_l,dante_next_s=next_s,haptics=cfg.enabled and cfg.haptics and audio_allowed,speaker=cfg.enabled and cfg.speaker and audio_allowed,maximum_bet_charging=cfg.enabled and cfg.nero_specials and stock~=nil and maximum_bet_preparing(special_action),adaptive_exceed=allowed,exceed_stock=stock,adaptive_bringer=cfg.enabled and cfg.triggers and cfg.bringer and cfg.adaptive_bringer and stock~=nil,lock_on=lock_on,exceed_fire=cfg.enabled and cfg.lightbar and cfg.exceed_fire and stock~=nil and stock>0})
end
local function export_player(player)
    local rows={}
    local td=player:get_type_definition()
    local count=0
    while td and count<12 do
        local group={type=td:get_full_name(),fields={},methods={}}
        for _,field in ipairs(td:get_fields()) do
            local row={name=field:get_name(),type=field:get_type():get_full_name()}
            if not field:is_static() then
                local ok,value=pcall(function() return field:get_data(player) end)
                if ok then
                    local kind=type(value)
                    row.value=(kind=='number' or kind=='boolean' or kind=='string') and value or tostring(value)
                end
            end
            table.insert(group.fields,row)
        end
        for _,method in ipairs(td:get_methods()) do table.insert(group.methods,method:get_name()) end
        table.insert(rows,group)
        td=td:get_parent_type(); count=count+1
    end
    local pad=player:call('get_padInput')
    if pad then
        local pad_td=pad:get_type_definition()
        local group={type=pad_td:get_full_name(),fields={},methods={}}
        for _,field in ipairs(pad_td:get_fields()) do
            local ok,value=pcall(function() return field:get_data(pad) end)
            if ok then table.insert(group.fields,{name=field:get_name(),type=field:get_type():get_full_name(),value=tostring(value)}) end
        end
        for _,method in ipairs(pad_td:get_methods()) do
            local params={}
            for _,p in ipairs(method:get_param_types()) do table.insert(params,p:get_full_name()) end
            table.insert(group.methods,{name=method:get_name(),params=params,returns=method:get_return_type():get_full_name()})
        end
        table.insert(rows,group)
    end
    json.dump_file(dir..'player_sdk.json',rows)
end
local function emit(event)
    if not cfg.enabled or not status.session then return end
    seq=seq+1
    local ok=json.dump_file(dir..'request.json',{session=status.session,seq=seq,event=event,toggles={rumble=cfg.rumble,haptics=cfg.haptics,speaker=cfg.speaker,lightbar=cfg.lightbar,triggers=cfg.triggers}})
    if ok then last_event=event; log.info('[DualSense] '..event) else error_text='Cannot write request' end
end
local function hp(player)
    -- Optional, explicitly configured SDK field path verified in Object Explorer.
    local value=player
    if cfg.hp_method=='get_hp' then return player:call('get_hp') end
    if #cfg.hp_path==0 then return nil end
    for _,field in ipairs(cfg.hp_path) do
        if value==nil then return nil end
        value=value:get_field(field)
    end
    if type(value)=='number' and value==value and value>=0 then return value end
end
re.on_frame(function()
    if os.clock()-last_poll<0.05 then return end
    last_poll=os.clock()
    status=json.load_file(dir..'status.json') or {}
    game_paused=read_game_pause()
    local ok,err=pcall(function()
        local manager=sdk.get_managed_singleton(sdk.game_namespace('PlayerManager'))
        local player=manager and manager:call('get_manualPlayer') or nil
        if dmc5_dante_weapons then dmc5_dante_weapons.update(player) end
        if dmc5_dante_sdt then dmc5_dante_sdt.update(player) end
        if dmc5_dante_combat then dmc5_dante_combat.update(player,game_paused,cfg) end
        if dmc5_vergil then dmc5_vergil.update(player,game_paused) end
        local id=player and tostring(player:get_address()) or nil
        if player and diagnostic_player~=id then
            diagnostic_player=id
            local exported,err=pcall(function() export_player(player) end)
            if not exported then log.info('[DualSense diagnostic] '..tostring(err)) end
        end
        if id~=previous_player then
            vergil_strong_until=0;vergil_last_finisher_effect='none'
            last_vergil_finisher=nil
            pending_vergil_hit=false;last_vergil_contact=-1
            pending_parry=false
            if player and bind_parry then
                local bound,err=pcall(bind_parry,player:get_type_definition())
                if not bound then parry_error=tostring(err) end
            end
            local_pad=nil; lock_on=false
            previous_hp=nil
            previous_dt=nil;previous_dante_dt=nil;previous_dante_sdt=nil
            previous_exceed=nil
            previous_bringer={}
            pending_buster=false
            previous_enemy_step=nil
            pending_normal_hit=false;last_normal_contact=-1
            pending_showdown_hit=false; pending_exceed_hit=false; previous_special_action=nil
            if id then emit('player_enter') end
            previous_player=id
        if last_vergil_finisher and (not player or player:call('get_nowActionNameFull')~=last_vergil_finisher) then last_vergil_finisher=nil end
        end
        if not player or not cfg.enabled then pending_vergil_hit=false;last_vergil_contact=-1;previous_enemy_step=nil;pending_normal_hit=false;pending_maxact=false; previous_maxbet_level=nil; pending_maxbet_level=nil; previous_hp=nil; previous_exceed=nil; previous_bringer={}; previous_dt=nil; previous_dante_dt=nil; previous_dante_sdt=nil; dante_dt=nil; dante_sdt=nil; devil_trigger=nil; dt_gauge=nil; pending_buster=false; pending_showdown_hit=false; pending_exceed_hit=false; previous_special_action=nil; special_action=nil; control(false); return end
        local value=hp(player)
        local damaged=value and previous_hp and value<previous_hp
        local event=damaged and 'damage' or nil
        previous_hp=value
        -- Isolate optional Nero getters so an unsupported character cannot break HP.
        local stock_ok,stock=pcall(function()
            if player:get_type_definition():get_full_name()~='app.PlayerNero' then return nil end
            return player:call('get_exceedStock')
        end)
        if not stock_ok or type(stock)~='number' or stock~=stock or stock<0 or stock>3 then stock=nil end
        if stock~=nil then
            local pad=player:call('get_padInput')
            local_pad=pad and tostring(pad:get_address()) or nil
        else local_pad=nil; lock_on=false end
        devil_trigger=nil; dt_gauge=nil
        if stock~=nil then
            local dt_ok,active=pcall(function() return player:call('get_isDevilTrigger') end)
            if dt_ok and type(active)=='boolean' then devil_trigger=active end
            local gauge_ok,gauge=pcall(function() return player:call('get_devilTriggerGauge') end)
            if gauge_ok and type(gauge)=='number' and gauge==gauge then dt_gauge=gauge end
        end
        if cfg.devil_trigger and devil_trigger==true and previous_dt==false and not damaged then event='devil_trigger_enter' end
        if cfg.devil_trigger and devil_trigger==false and previous_dt==true and not damaged then event='devil_trigger_exit' end
        previous_dt=devil_trigger
        dante_dt=nil;dante_sdt=nil
        if player:get_type_definition():get_full_name()=='app.PlayerDante' then
            local normal_ok,normal=pcall(function() return player:call('get_isDevilTrigger') end)
            local sin_ok,sin=pcall(function() return player:call('get_isTheDevilTrigger') end)
            if normal_ok and type(normal)=='boolean' then dante_dt=normal end
            if sin_ok and type(sin)=='boolean' then dante_sdt=sin end
            if cfg.dante_devil_trigger and dante_dt==true and dante_sdt==false and previous_dante_dt==false and not damaged then
                event='dante_devil_trigger_enter'
            end
            if cfg.dante_devil_trigger and dante_dt==false and dante_sdt==false and previous_dante_dt==true and previous_dante_sdt==false and not damaged then
                event='dante_devil_trigger_exit'
            end
        end
        previous_dante_dt=dante_dt
        previous_dante_sdt=dante_sdt
        if cfg.dante_sdt_transform and dmc5_dante_sdt and dmc5_dante_sdt.entered and not damaged then event=dmc5_dante_sdt.short and 'dante_sdt_short_enter' or 'dante_sdt_enter' end
        exceed_text=stock and tostring(stock) or 'unavailable'
        if cfg.exceed and stock and previous_exceed and stock>previous_exceed and not event then event='exceed_charge' end
        previous_exceed=stock
        bringer={}
        if stock~=nil then
            for key,method in pairs({buster_timer='get_busterTimer',snatch_hit_timer='get_rightSnatchHitTimer',buster_hit_timer='get_reqBusterHitTimer'}) do
                local read_ok,timer=pcall(function() return player:call(method) end)
                if read_ok and type(timer)=='number' and timer==timer then bringer[key]=timer end
            end
        end
        if cfg.bringer and not damaged then
            if timer_started(bringer.snatch_hit_timer,previous_bringer.snatch_hit_timer) then event='bringer_snatch' end
            if pending_buster then event='bringer_buster' end
        end
        pending_buster=false
        previous_bringer=bringer
        special_action=nil
        if stock~=nil then
            local action_ok,action=pcall(function() return player:call('get_nowActionNameFull') end)
            if action_ok and type(action)=='string' then special_action=action end
        end
        local step_ok,step_action=pcall(function() return player:call('get_nowActionNameFull') end)
        local stepping=step_ok and is_enemy_step(step_action)
        if cfg.enemy_step and stepping and previous_enemy_step==false and not event then event='enemy_step' end
        previous_enemy_step=stepping
        if cfg.nero_specials and special_action and previous_special_action and special_action~=previous_special_action and not event then
            if special_action=='RedQueenSkill.MaximumBet.RQ_Skill_Maxbet_Set' then event='maximum_bet_prepare'
            elseif special_action=='RedQueenSkill.MaximumBet.RQ_Skill_Maxbet_Charge' then event='maximum_bet_charge'
            elseif special_action=='RedQueenSkill.MaximumBet.RQ_Skill_Maxbet_LaunchLv1' then event='maximum_bet_release_lv1'
            elseif special_action=='RedQueenSkill.MaximumBet.RQ_Skill_Maxbet_LaunchLv2' then event='maximum_bet_release_lv2'
            elseif special_action=='RedQueenSkill.MaximumBet.RQ_Skill_Maxbet_LaunchLv3' then event='maximum_bet_release'
            elseif special_action=='RedQueenSkill.ShowDown.RQ_Skill_Showdown_First' then event='showdown_start'
            elseif special_action=='RedQueenSkill.ShowDown.RQ_Skill_Showdown_Miss' or (maximum_bet_preparing(previous_special_action) and not maximum_bet_preparing(special_action)) then event='special_cancel' end
        end
        -- Managed SDK level field, gated to the validated Maximum Bet charge action.
        -- Read just one primitive; no diagnostic field enumeration or per-frame log.
        if cfg.nero_specials and special_action=='RedQueenSkill.MaximumBet.RQ_Skill_Maxbet_Charge' then
            local level_ok,level=pcall(function()
                local checker=player:get_field('<motionCharge>k__BackingField')
                return checker and checker:get_field('<currentLevel>k__BackingField')
            end)
            if level_ok and type(level)=='number' and level>=0 and level<=2 then
                if previous_maxbet_level~=nil and level>previous_maxbet_level then pending_maxbet_level=level end
                previous_maxbet_level=level
            end
            if pending_maxbet_level and not event and not damaged then
                event=pending_maxbet_level==1 and 'maximum_bet_level2' or 'maximum_bet_level3'
                pending_maxbet_level=nil
            end
        else previous_maxbet_level=nil; pending_maxbet_level=nil end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.space_slash_cancel and not damaged then event='vergil_space_slash_cancel';vergil_strong_until=0 end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.jce_prepare and not damaged then event='vergil_jce_prepare' end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.jce_finish and not damaged then event='vergil_jce_finish' end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.judgment_cut and not damaged then event='vergil_judgment_cut' end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.jce_slashes and not damaged then event='vergil_jce_slashes' end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.deep_stinger_start and not damaged then event='vergil_deep_stinger_start';vergil_strong_until=os.clock()+2 end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.deep_stinger_advance_haptic and not damaged then event='vergil_deep_stinger_advance_haptic';vergil_strong_until=os.clock()+2 end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.deep_stinger_advance and not damaged then event='vergil_deep_stinger_advance';vergil_strong_until=os.clock()+2 end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.deep_stinger_finish and not damaged then event='vergil_deep_stinger_finish';vergil_strong_until=os.clock()+1.6 end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.deep_stinger_cancel and not damaged then event='vergil_deep_stinger_cancel';vergil_strong_until=0 end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.space_slash_haptic and not event and not damaged then event='vergil_space_slash_haptic_'..dmc5_vergil.state.space_slash_haptic end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.space_slash_start and not damaged then event='vergil_space_slash';vergil_strong_until=os.clock()+4.8 end
        if cfg.vergil_sdt_transform and dmc5_vergil and dmc5_vergil.state.sdt_entered and not damaged then event='vergil_sdt_enter' end
        if not game_paused and cfg.dante_sdt_transform and dmc5_dante_sdt and dmc5_dante_sdt.ready_sound and not event and not damaged then event='dante_sdt_ready' end
        if not game_paused and cfg.vergil_sdt_transform and dmc5_vergil and dmc5_vergil.state.sdt_ready_sound and not event and not damaged then event='vergil_sdt_ready' end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.world_of_v_haptic and not event and not damaged then event='vergil_world_of_v_haptic_'..dmc5_vergil.state.world_of_v_haptic end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.world_of_v and not damaged then event='vergil_world_of_v';vergil_strong_until=os.clock()+4.713 end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.hell_on_earth_cancel then event='vergil_hell_on_earth_cancel';vergil_strong_until=0 end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.hell_on_earth_haptic and not event and not damaged then event='vergil_hell_on_earth_haptic_'..dmc5_vergil.state.hell_on_earth_haptic end
        if cfg.vergil_specials and dmc5_vergil and dmc5_vergil.state.hell_on_earth and not damaged then event='vergil_hell_on_earth';vergil_strong_until=os.clock()+5.8 end
        if cfg.vergil_doppel and dmc5_vergil and dmc5_vergil.event and not event then event=dmc5_vergil.event end
        if pending_vergil_hit and (cfg.vergil_normal_hits or cfg.vergil_beowulf_charge) and not event and not damaged then event=pending_vergil_hit end
        if cfg.vergil_beowulf_charge and dmc5_vergil and dmc5_vergil.state.charge_event and os.clock()>=vergil_strong_until and not event and not damaged then event=dmc5_vergil.state.charge_event end
        if cfg.vergil_normal_hits and dmc5_vergil and dmc5_vergil.state.rapid_attack and os.clock()>=vergil_strong_until and not event and not damaged then event='vergil_combo_hit' end
        pending_vergil_hit=false
        if pending_normal_hit and cfg.normal_sword_hits and not event and not damaged then event='nero_sword_hit' end
        pending_normal_hit=false
        if cfg.nero_specials and pending_showdown_hit and not damaged then event='showdown_hit' end
        if cfg.exceed_hits and pending_exceed_hit and not damaged and event~='showdown_hit' then event=pending_exceed_hit end
        if pending_maxact and cfg.max_act and not damaged then event='max_act';pending_maxact=false end
        if pending_parry and cfg.parry~=false and not damaged then event='sword_parry' end
        pending_parry=false
        pending_exceed_hit=false
        pending_showdown_hit=false; previous_special_action=special_action
        if dmc5_dante_combat then
            if event=='dante_sdt_short_enter' then dmc5_dante_combat.block(.12) end
            if event=='dante_devil_trigger_enter' or event=='dante_sdt_enter' then dmc5_dante_combat.block(.95) end
            if dmc5_dante_sdt and dmc5_dante_sdt.transforming then dmc5_dante_combat.block(.15) end
            local pulse=dmc5_dante_combat.poll()
            local release=pulse and (pulse=='dante_royal_release' or pulse=='dante_royal_devil_counter' or pulse:find('dante_normal_release_',1,true)==1)
            if pulse and not damaged and (not event or (release and event~='dante_devil_trigger_enter' and event~='dante_sdt_enter' and event~='dante_sdt_short_enter') or (pulse=='dante_royal_block' and event=='sword_parry')) then event=pulse end
        end
        if event then emit(event) end
        control(cfg.enabled and cfg.triggers and cfg.adaptive_exceed and stock~=nil,stock,true)
        if os.clock()-last_telemetry>=0.25 then
            last_telemetry=os.clock()
            json.dump_file(dir..'telemetry.json',{player=id,hp=value,exceed_stock=stock,devil_trigger=devil_trigger,dt_gauge=dt_gauge,bringer=bringer,buster_starts=buster_starts,buster_hook_error=buster_hook_error,buster_input=buster_input,special_action=special_action,showdown_hits=showdown_hits,exceed_hits=exceed_hits,sword_contacts=sword_contacts,dante_combat=dmc5_dante_combat and dmc5_dante_combat.state or nil,special_hook_error=special_hook_error,time=os.time(),event=last_event})
        end
    end)
    error_text=ok and '' or tostring(err)
    if not ok then control(false) end
end)
re.on_draw_ui(function()
    if not imgui.tree_node('DMC5 DualSense experimental') then return end
    local fresh=status.heartbeat and os.time()-status.heartbeat<3
    imgui.text('Controller: '..(fresh and status.connected and 'USB connected' or 'offline'))
    local input_ok,input_status=pcall(json.load_file,dir..'input_status.json')
    if input_ok and type(input_status)=='table' then
        imgui.text('Native controls: '..(input_status.enabled and (input_status.connected and 'USB connected' or 'waiting for USB') or 'disabled'))
        imgui.text('Native input packets: '..tostring(input_status.translated or 0))
    end
    if fresh and status.simulation then imgui.text('Test mode: no physical controller output') end
    imgui.text('Audio haptics: '..(fresh and status.audio_haptics_connected and 'USB connected' or 'unavailable'))
    imgui.text('Audio active: '..tostring(status.audio_haptics_active or false)..' / underruns '..tostring(status.audio_haptics_underruns or 0))
    if status.audio_haptics_error and status.audio_haptics_error~='' then imgui.text(status.audio_haptics_error) end
    imgui.text('Game event: '..last_event)
    if dmc5_vergil and dmc5_vergil.state.action then
        imgui.text('Vergil / arma: '..tostring(dmc5_vergil.state.weapon)..' / SDT: '..tostring(dmc5_vergil.state.sdt_active))
        imgui.text('Combo / fase actual: '..tostring(dmc5_vergil.state.action))
        imgui.text('Ultimo remate SDT: '..vergil_last_finisher_effect)
        if dmc5_vergil.state.beowulf_charging then imgui.text('Beowulf / carga: '..tostring(dmc5_vergil.state.beowulf_charge_level or 'nivel no disponible')) end
    end
    imgui.text('Last effect: '..tostring(status.last_effect or 'none'))
    if imgui.tree_node('Detalle del estado') then
    imgui.text('Player: '..tostring(previous_player or 'none'))
    imgui.text('HP: '..tostring(previous_hp or 'not configured'))
    imgui.text('Exceed stock: '..exceed_text)
    imgui.text('Devil Trigger: '..tostring(devil_trigger)..' / gauge '..tostring(dt_gauge))
    if dmc5_dante_combat and dmc5_dante_combat.state.weapon_s then
        local combat=dmc5_dante_combat.state
        imgui.text('Royal Block perfectos: '..tostring(combat.royal_blocks or 0)..' / contactos: '..tostring(combat.guard_contacts or 0)..' / detector: '..tostring(combat.royal_hook or 'no disponible'))
        imgui.text('Release normales: '..tostring(combat.normal_releases or 0)..' / Royal Release: '..tostring(combat.royal_releases or 0)..' / carga usada: '..tostring(combat.release_charge_percent or 0)..'%')
        if dmc5_dante_combat.errors.royal_block or dmc5_dante_combat.errors.royal_block_pre or dmc5_dante_combat.errors.royal_block_post then imgui.text('Royal Block: '..tostring(dmc5_dante_combat.errors.royal_block or dmc5_dante_combat.errors.royal_block_pre or dmc5_dante_combat.errors.royal_block_post)) end
        imgui.text('Dante accion: '..tostring(combat.action)..' / estilo: '..tostring(combat.style))
        if combat.weapon_l=='FaustHat' then imgui.text('Dr. Faust: carga '..tostring(combat.faust_charging)..' / nivel '..tostring(combat.faust_level or '-')..' / impactos '..tostring(combat.faust_impacts or 0)) end
        imgui.text('Ignition: '..(combat.ignition==nil and 'sin identificar' or tostring(combat.ignition))..' / ultimo pulso: '..tostring(combat.effect or 'none'))
    end
    if dante_dt~=nil then imgui.text('Dante DT: '..tostring(dante_dt)..' / Sin DT: '..tostring(dante_sdt)) end
    imgui.text('Adaptive L2: '..(status.adaptive_exceed_active and 'active' or 'released'))
    imgui.text('L2 force: '..tostring(status.adaptive_exceed_force or 0))
    imgui.text('Exceed fire LED: '..(status.exceed_fire_active and 'active' or 'off'))
    imgui.text('Bringer timers: Buster '..tostring(bringer.buster_timer)..' / Snatch '..tostring(bringer.snatch_hit_timer))
    imgui.text('Buster starts: '..tostring(buster_starts))
    imgui.text('R2 ready force: '..tostring(status.adaptive_bringer_force or 0))
    imgui.text('R2 depth: '..tostring(buster_input.depth))
    imgui.text('Nero action: '..tostring(special_action or 'unavailable'))
    imgui.text('Showdown hits: '..tostring(showdown_hits))
    imgui.text('Exceed hits: '..tostring(exceed_hits))
    imgui.text('MAX-Act: '..tostring(maxact_count))
    imgui.text('Sword parrys: '..tostring(parry_count))
    if parry_last.character then imgui.text('Last parry: '..parry_last.character..' / '..tostring(parry_last.action)..' / accepted '..tostring(parry_last.accepted)) end
    if parry_error~='' then imgui.text(parry_error) end
    if maxact_hook_error~='' then imgui.text(maxact_hook_error) end
    if special_hook_error~='' then imgui.text(special_hook_error) end
    if buster_input.error then imgui.text(buster_input.error) end
    if buster_hook_error~='' then imgui.text(buster_hook_error) end
    if error_text~='' then imgui.text(error_text) end
    imgui.tree_pop()
    end
    if imgui.tree_node('Funciones habilitadas') then
    for _,group in ipairs({
        {label='Vergil',keys={'vergil_weapons','vergil_doppel','vergil_sdt_charge','vergil_sdt_transform','vergil_specials','vergil_normal_hits','vergil_beowulf_charge'}},
        {label='Dante',keys={'dante_weapons','dante_normal_hits','dante_normal_block','dante_royal_block','dante_royal_release','dante_normal_release','dante_devil_counter','dante_gunfire','dante_devil_trigger','dante_sdt_charge','dante_sdt_transform','dante_sdt_attacks','dante_sdt_triggers'}},
        {label='Generales',keys={'enabled','rumble','haptics','speaker','lightbar','triggers','parry','enemy_step'}},
        {label='Nero',keys={'exceed','exceed_hits','normal_sword_hits','adaptive_exceed','exceed_fire','bringer','adaptive_bringer','devil_trigger','nero_specials','max_act'}}
    }) do
        if imgui.tree_node(group.label) then
            if group.label=='Generales' then draw_speaker_volume() end
            for _,key in ipairs(group.keys) do
                local changed,value=imgui.checkbox(key,cfg[key])
                if changed then cfg[key]=value; json.dump_file(dir..'config.json',cfg) end
            end
            imgui.tree_pop()
        end
    end
    imgui.tree_pop()
    end
    if imgui.tree_node('Buscar sonidos / desarrollo') then
        if dmc5_audio_studio then
            local ok,err=pcall(dmc5_audio_studio.draw)
            if not ok then imgui.text('Explorador: '..tostring(err)) end
        else imgui.text('Explorador no cargado. Usa Reset scripts.') end
        imgui.tree_pop()
    end
    if dmc5_dante_weapons and imgui.tree_node('Dante / Armas') then
        local ok,err=pcall(dmc5_dante_weapons.draw)
        if not ok then imgui.text(tostring(err)) end
        if dmc5_dante_sdt then dmc5_dante_sdt.draw() end
        imgui.tree_pop()
    end
    if dmc5_vergil and imgui.tree_node('Vergil / Armas y Doppelganger') then dmc5_vergil.draw();imgui.tree_pop() end
    if imgui.tree_node('Pruebas del mando') then
    if imgui.button('Test damage pulse') then emit('damage') end
    if imgui.button('Probar Royal Block: altavoz + haptica') then emit('dante_royal_block') end
    imgui.text('Speaker: '..(fresh and status.speaker_connected and 'USB connected' or 'unavailable')..' / active '..tostring(status.speaker_active or false))
    if imgui.button('Test controller speaker') then emit('speaker_test') end
    if imgui.button('Haptica desde audio: Nero DT') then emit('preview_nero_dt') end
    if imgui.button('Test audio haptics') then emit('haptic_test') end
    if imgui.button('Test MAX-Act pulse') then emit('max_act') end
    if imgui.button('Test sword parry') then emit('sword_parry') end
    if imgui.button('Test salto sobre enemigo') then emit('enemy_step') end
    if imgui.button('Test golpe normal Nero') then emit('nero_sword_hit') end
    if imgui.button('Test Exceed pulse') then emit('exceed_charge') end
    if imgui.button('Test Snatch pulse') then emit('bringer_snatch') end
    if imgui.button('Test Buster pulse') then emit('bringer_buster') end
    if imgui.button('Test Dante DT rojo') then emit('dante_devil_trigger_enter') end
    if imgui.button('Test Devil Trigger LED') then emit('devil_trigger_enter') end
    if imgui.button('Test Devil Trigger exit sound') then emit('devil_trigger_exit') end
    if imgui.button('Test trigger (1 second)') then emit('trigger_test') end
    imgui.tree_pop()
    end
    if imgui.tree_node('Configuracion e inspector') then
    if imgui.button('Reload config') then cfg=normalize(json.load_file(dir..'config.json')); previous_hp=nil; previous_exceed=nil; previous_bringer={} end
    if imgui.button('Inspect player SDK') then inspect_player=not inspect_player end
    if inspect_player then
        local manager=sdk.get_managed_singleton(sdk.game_namespace('PlayerManager'))
        local player=manager and manager:call('get_manualPlayer')
        if player then
            local ok,err=pcall(function() object_explorer:handle_address(player:get_address()) end)
            if not ok then imgui.text('Inspector: '..tostring(err)) end
        else imgui.text('No local player available') end
    end
    imgui.tree_pop()
    end
    imgui.tree_pop()
end)

