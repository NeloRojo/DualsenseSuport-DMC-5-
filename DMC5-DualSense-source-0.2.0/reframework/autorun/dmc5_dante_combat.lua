-- Actual damage contacts and projectile creation, independent of combo names/styles.
if reframework:get_game_name()~='dmc5' then return end
local C={state={},errors={},settings={}}
_G.dmc5_dante_combat=C
local current=nil
local current_object=nil
local pending=nil
local last_hit,last_shot=-1,-1
local last_sdt_pulse=-1
local sdt_action=nil
local last_luce_impact=-1
local luce_shell_id=nil
do
    local td=sdk.find_type_definition('app.ShellID')
    if td then for _,f in ipairs(td:get_fields()) do
        if f:get_name()=='TDT_TheLuce' then local ok,value=pcall(function() return f:get_data(nil) end);if ok then luce_shell_id=value end;break end
    end end
end
local blocked_until=0
local weak_blocked_until=0

local last_ignition=-1
local last_faust_charge=-1
local last_meteor_hit=-1
local last_royal_block=-1
local last_guard_contact=-1
local normal_guard_due=nil
local last_royal_release=-1
local last_normal_release=-1
local release_phase=nil
local stored_guard_rate=0
local last_counter_hit=-1
local enums={}
for _,kind in ipairs({'S','L'}) do
    enums[kind]={}
    local td=sdk.find_type_definition('app.PlayerDante.Weapon'..kind)
    if td then for _,f in ipairs(td:get_fields()) do
        local ok,v=pcall(function() return f:get_data(nil) end)
        if ok and type(v)=='number' then enums[kind][v]=f:get_name() end
    end end
end
local function read(obj,name)
    local ok,value=pcall(function() return obj:call(name) end)
    if ok then return value end
end
local function local_player(obj)
    return obj and current and tostring(obj:get_address())==current and obj:get_type_definition():get_full_name()=='app.PlayerDante'
end
local function balrog(player)
    for _,getter in ipairs({'get_weaponS_00','get_weaponS_01'}) do
        local data=read(player,getter)
        if data then
            local ok,obj=pcall(function() return data:get_field('Obj') end)
            if ok and obj and obj:get_type_definition():get_full_name()=='app.WeaponBalrog' then return obj end
        end
    end
end
local function ignition(player)
    local obj=balrog(player)
    if obj then
        local active=read(obj,'get_isBurningMode')
        if type(active)=='boolean' then return active end
    end
end
local function queue(effect,weight)
    if not pending or weight>pending.weight then pending={event=effect,weight=weight} end
end
function C.on_counter_hit(player)
    if not C.settings.enabled or C.settings.dante_devil_counter==false or C.state.paused or not local_player(player) or os.clock()<blocked_until then return end
    if last_counter_hit>=0 and os.clock()-last_counter_hit<.08 then return end
    last_counter_hit=os.clock();normal_guard_due=nil
    C.state.devil_counters=(C.state.devil_counters or 0)+1
    C.state.last_counter_hit_action=read(player,'get_nowActionNameFull')
    queue('dante_royal_devil_counter',8);weak_blocked_until=os.clock()+.35
end
local function in_sdt(player) return read(player,'get_isTheDevilTrigger')==true end
local function sdt_effect(action,contact)
    local name=type(action)=='string' and action:lower() or ''
    if name:find('demolition',1,true) then return contact and 'dante_sdt_demolition_hit' or 'dante_sdt_demolition_charge' end
    if name:find('luce',1,true) then return 'dante_sdt_luce' end
    return contact and 'dante_sdt_hit' or 'dante_sdt_shot'
end
function C.on_luce_impact(player)
    if not C.settings.enabled or C.state.paused or not local_player(player) or not in_sdt(player) or os.clock()<blocked_until then return end
    local now=os.clock();if last_luce_impact>=0 and now-last_luce_impact<.035 then return end
    last_luce_impact=now;C.state.sdt_luce_hits=(C.state.sdt_luce_hits or 0)+1;C.state.luce_shell_id=luce_shell_id
    if C.settings.dante_sdt_attacks~=false then queue('dante_sdt_luce_hit',5) end
end
function C.on_sdt_shell(shell)
    local owner=read(shell,'get_cachedOwnerPlayer')
    if not local_player(owner) or not in_sdt(owner) then return end
    local ok,id=pcall(function() return shell:get_field('ShellID') end)
    if ok and luce_shell_id~=nil and id==luce_shell_id then C.on_luce_impact(owner)
    else C.on_hit(owner) end
end
function C.on_hit(player)
    if not C.settings.enabled or C.state.paused or not local_player(player) or os.clock()<blocked_until then return end
    local action=read(player,'get_nowActionNameFull')
    local compact=type(action)=='string' and action:lower():gsub('[^a-z]','') or ''
    if compact:find('devilcounter',1,true) then
        C.on_counter_hit(player)
        return
    end
    if in_sdt(player) then
        if compact:find('luce',1,true) then C.on_luce_impact(player);return end
        if C.settings.dante_sdt_attacks==false then return end
        local now=os.clock();if last_hit>=0 and now-last_hit<.065 then return end
        last_hit=now;C.state.last_hit_action=action;C.state.sdt_hits=(C.state.sdt_hits or 0)+1
        queue(sdt_effect(action,true),5);return
    end
    if not C.settings.dante_normal_hits or read(player,'get_isShortRangeAttack')~=true then return end
    local now=os.clock();if last_hit>=0 and now-last_hit<.04 then return end
    last_hit=now
    C.state.last_hit_action=action
    if C.state.weapon_s=='Balrog' and compact:find('realimpact',1,true) then
        queue('dante_balrog_real_impact',5)
        weak_blocked_until=now+.4
        C.state.hits=(C.state.hits or 0)+1
        return
    end
    if now<weak_blocked_until then return end
    if C.state.weapon_s=='Balrog' then C.state.ignition=ignition(player) end
    local effect=C.state.weapon_s=='Balrog' and C.state.ignition==true and 'dante_balrog_ignition_hit' or 'dante_melee_hit'
    queue(effect,effect=='dante_melee_hit' and 1 or 2)
    C.state.hits=(C.state.hits or 0)+1
end
-- Direct Faust weapon/control metadata; never infer levels from elapsed time.
local function field(obj,name)
    local ok,value=pcall(function() return obj:get_field(name) end)
    if ok then return value end
end
function C.on_devil_counter_shell(shell)
    if field(shell,'ShellID')==88 then -- app.ShellID.RoyalGuard_DevilCounter
        C.on_counter_hit(read(shell,'get_cachedOwnerPlayer'))
    end
end
local function faust_weapon(player)
    local obj=read(player,'get_cachedWeaponFaustHat')
    if obj and obj:get_type_definition():get_full_name()=='app.WeaponFaustHat' then return obj end
end
local function meteor_level(weapon)
    local control=read(weapon,'get_orbMeteoControl')
    local consumed=control and read(control,'get_MeteoChargeConsumed')
    local level
    if type(consumed)=='number' then
        local ok,value=pcall(function() return weapon:call('calcMeteoLv',math.max(0,consumed)) end)
        if ok then level=value end
    end
    if type(level)~='number' then level=read(weapon,'get_orbMeteoLv') end
    return math.max(1,math.min(3,type(level)=='number' and level or 1)),control
end
function C.on_faust_weapon(weapon)
    if weapon and weapon:get_type_definition():get_full_name()=='app.WeaponFaustHat' then
        C.on_shot(read(weapon,'get_owner'))
    end
end
function C.on_faust_shell(shell)
    if not C.settings.enabled or not C.settings.dante_gunfire or C.state.paused or os.clock()<blocked_until then return end
    if field(shell,'ShellID')~=85 then return end -- app.ShellID.FH_OrbMeteorite
    local owner=read(shell,'get_cachedOwnerPlayer')
    if not local_player(owner) then return end
    local now=os.clock();if last_meteor_hit>=0 and now-last_meteor_hit<.08 then return end
    last_meteor_hit=now
    local raw=read(shell,'get_level');C.state.faust_shell_level=raw
    local level=type(raw)=='number' and raw>=1 and raw<=3 and raw or C.state.faust_release_level or 1
    queue('dante_faust_meteor_hit_'..level,6);weak_blocked_until=now+({.2,.3,.42})[level]
    C.state.faust_impacts=(C.state.faust_impacts or 0)+1
end
local function update_faust(player,paused)
    if paused or in_sdt(player) or not C.settings.enabled or not C.settings.dante_gunfire or C.state.weapon_l~='FaustHat' then
        C.state.faust_charging=false;last_faust_charge=-1;return
    end
    local weapon=faust_weapon(player);if not weapon then return end
    local level,control=meteor_level(weapon)
    local charging=control and field(control,'orbConsumingFlag')==true and read(control,'get_ForceEndMeteoCharge')~=true
    C.state.faust_charging=charging==true;C.state.faust_level=level
    if charging then
        C.state.faust_release_level=level
        local now=os.clock()
        if now>=blocked_until and now>=weak_blocked_until and (last_faust_charge<0 or now-last_faust_charge>=.18) then
            last_faust_charge=now;queue('dante_faust_charge_'..level,4)
        end
    else last_faust_charge=-1 end
end
function C.on_shot(player)
    if not C.settings.enabled or C.state.paused or not local_player(player) or os.clock()<blocked_until then return end
    if in_sdt(player) then
        if C.settings.dante_sdt_attacks==false then return end
        local now=os.clock();if last_shot>=0 and now-last_shot<.09 then return end
        last_shot=now;queue(sdt_effect(read(player,'get_nowActionNameFull'),false),5)
        C.state.sdt_shots=(C.state.sdt_shots or 0)+1;return
    end
    if not C.settings.dante_gunfire then return end
    if os.clock()<weak_blocked_until then return end
    local gun=enums.L[read(player,'get_currentWeaponL')]
    local key=({Ebony_Ivory='pistol',CoyoteA='shotgun',KalinaMk1='kalina',KalinaMk2='kalina',DoubleKalinaAnn='kalina',FaustHat='faust'})[gun]
    if not key then return end
    local now=os.clock();local gap=key=='kalina' and .075 or .045
    if last_shot>=0 and now-last_shot<gap then return end
    last_shot=now;queue('dante_gun_'..key,key=='kalina' and 3 or 1)
    C.state.shots=(C.state.shots or 0)+1
end
function C.block(seconds) blocked_until=os.clock()+seconds;pending=nil;normal_guard_due=nil end
-- Called only after the engine accepts a real block. A timing window alone
-- must never emit feedback; Release actions remain separate.
function C.on_guard_result(player,accepted,royal,releasing)
    if not C.settings.enabled or C.settings.dante_royal_block==false or C.state.paused or not local_player(player) then return end
    if accepted~=true or releasing==true then return end
    C.state.last_guard_royal=royal==true
    if royal~=true then C.state.normal_blocks=(C.state.normal_blocks or 0)+1;return end
    local now=os.clock();if last_royal_block>=0 and now-last_royal_block<.08 then return end
    last_royal_block=now
    normal_guard_due=nil
    C.state.royal_blocks=(C.state.royal_blocks or 0)+1
    C.state.last_guard_action=read(player,'get_nowActionNameFull')
    queue('dante_royal_block',6);weak_blocked_until=now+.4
end
local function classify_release(action)
    local lower=type(action)=='string' and action:lower() or ''
    if not lower:find('royalguard',1,true) or not lower:find('release',1,true) or lower:find('devilcounter',1,true) then return nil end
    if lower:find('reception',1,true) or lower:find('wait',1,true) then return nil end
    local phasepath=lower:gsub('royalguard','')
    local air=lower:find('air',1,true) or lower:find('aerial',1,true)
    if phasepath:find('royal',1,true) then return 'royal' end
    if lower:find('normal',1,true) then return air and 'air' or 'normal' end
    if air then return 'air' end
end
function C.on_release(player,phase)
    if not C.settings.enabled or C.state.paused or not local_player(player) or read(player,'get_currentStyle')~=3 or os.clock()<blocked_until then return end
    local now=os.clock()
    if phase=='royal' then
        if C.settings.dante_royal_release==false or (last_royal_release>=0 and now-last_royal_release<.15) then return end
        last_royal_release=now;normal_guard_due=nil
        C.state.royal_releases=(C.state.royal_releases or 0)+1
        C.state.last_release_action=read(player,'get_nowActionNameFull')
        queue('dante_royal_release',7);weak_blocked_until=now+2
    elseif phase=='normal' or phase=='air' then
        if C.settings.dante_normal_release==false or (last_normal_release>=0 and now-last_normal_release<.15) then return end
        last_normal_release=now;normal_guard_due=nil
        local ctrl=field(player,'RoyalGuardCtrl')
        local gauge=ctrl and read(ctrl,'get_currentRoyalGauge');local max=ctrl and read(ctrl,'get_maxRoyalGauge')
        local rate=type(gauge)=='number' and type(max)=='number' and max>0 and math.max(0,math.min(1,gauge/max)) or 0
        rate=math.max(rate,stored_guard_rate)
        local level=math.floor(rate*4+.5)
        queue((phase=='air' and 'dante_normal_release_air_' or 'dante_normal_release_')..level,6)
        C.state.normal_releases=(C.state.normal_releases or 0)+1
        C.state.release_charge_percent=math.floor(rate*100+.5);C.state.release_level=level;C.state.release_air=phase=='air'
        C.state.last_normal_release_action=read(player,'get_nowActionNameFull')
        weak_blocked_until=now+.35
    end
end
function C.update(player,paused,settings)
    C.settings=settings;C.state.paused=paused==true
    local id=player and player:get_type_definition():get_full_name()=='app.PlayerDante' and tostring(player:get_address()) or nil
    local player_changed=id~=current
    if id~=current then current=id;pending=nil;last_hit=-1;last_shot=-1;last_ignition=-1;blocked_until=0;weak_blocked_until=0;last_faust_charge=-1;last_meteor_hit=-1;last_royal_block=-1;C.state={paused=paused==true} end
    if player_changed then last_guard_contact=-1;normal_guard_due=nil;last_royal_release=-1;last_normal_release=-1;release_phase=nil;stored_guard_rate=0;last_counter_hit=-1 end
    current_object=id and player or nil
    C.state.royal_hook=C.royal_hook
    if not id then return end
    C.state.action=read(player,'get_nowActionNameFull');C.state.style=read(player,'get_currentStyle')
    local guard=field(player,'RoyalGuardCtrl')
    local gauge=guard and read(guard,'get_currentRoyalGauge')
    local maximum=guard and read(guard,'get_maxRoyalGauge')
    local rate=type(gauge)=='number' and type(maximum)=='number' and maximum>0 and math.max(0,math.min(1,gauge/maximum)) or stored_guard_rate
    C.state.royal_gauge_percent=math.floor(rate*100+.5)
    local phase=classify_release(C.state.action)
    if phase and phase~=release_phase then C.on_release(player,phase) end
    release_phase=phase
    if not phase and not (type(C.state.action)=='string' and C.state.action:lower():find('release',1,true)) then stored_guard_rate=rate end
    C.state.weapon_s=enums.S[read(player,'get_currentWeaponS')];C.state.weapon_l=enums.L[read(player,'get_currentWeaponL')]
    if C.state.weapon_s=='Balrog' and (last_ignition<0 or os.clock()-last_ignition>=.15) then
        last_ignition=os.clock();C.state.ignition=ignition(player)
    elseif C.state.weapon_s~='Balrog' then C.state.ignition=nil;last_ignition=-1 end
    C.state.sdt=in_sdt(player)
    if C.state.sdt and not paused and C.settings.enabled and C.settings.dante_sdt_attacks~=false and os.clock()>=blocked_until then
        local action=type(C.state.action)=='string' and C.state.action:lower() or ''
        local now=os.clock()
        if not action:find('ivocation',1,true) and not action:find('invocation',1,true) then
            if (action:find('luce',1,true) or action:find('demolition',1,true)) and not action:find('end',1,true) and not action:find('finish',1,true) then
                if last_sdt_pulse<0 or now-last_sdt_pulse>=.18 then
                    last_sdt_pulse=now;queue(sdt_effect(action,false),4)
                end
            elseif C.state.action~=sdt_action and read(player,'get_isShortRangeAttack')==true then
                queue('dante_sdt_swing',3)
            end
        end
    else last_sdt_pulse=-1 end
    sdt_action=C.state.sdt and C.state.action or nil
    update_faust(player,paused)
    if paused then pending=nil;normal_guard_due=nil end
end
function C.poll()
    if normal_guard_due and os.clock()>=normal_guard_due then
        normal_guard_due=nil
        if C.settings.enabled and C.settings.dante_normal_block~=false and not C.state.paused and os.clock()>=blocked_until then
            queue('dante_normal_block',5)
            C.state.normal_blocks=(C.state.normal_blocks or 0)+1
        end
    end
    local result=pending;pending=nil
    if result and not C.state.paused and os.clock()>=blocked_until and (result.weight>=5 or os.clock()>=weak_blocked_until) then C.state.effect=result.event;return result.event end
end
local function bind(type_name,method_name,param,callback)
    local td=sdk.find_type_definition(type_name);local method=td and td:get_method(method_name)
    if not method then return end
    local params=method:get_param_types()
    if method:get_num_params()~=1 or not params or params[1]:get_full_name()~=param or method:get_return_type():get_full_name()~='System.Void' then return end
    sdk.hook(method,function(args)
        local ok,err=pcall(function() callback(sdk.to_managed_object(args[2])) end)
        if not ok then C.errors[method_name]=tostring(err) end
    end,function(retval) return retval end)
end
bind('app.PlayerDante','onAtkCalcDamageEnd','app.HitController.DamageInfo',C.on_hit)
bind('app.PlayerDante','createShell','app.ShellTrack',C.on_shot)

-- The perfect-block sound is hit-confirmed. checkBlock's timing predicate
-- does not reliably run through the hooked managed path in the live game.
-- Native Wwise UInt32 arguments start at slot 2 (no managed-this slot).
function C.on_guard_contact(player)
    if not local_player(player) then return end
    local now=os.clock()
    if last_guard_contact>=0 and now-last_guard_contact<.035 then return end
    last_guard_contact=now
    C.state.guard_contacts=(C.state.guard_contacts or 0)+1
    if not C.settings.enabled or C.settings.dante_normal_block==false or C.state.paused or now<blocked_until or read(player,'get_currentStyle')~=3 then return end
    local track=read(player,'get_royalGuardTrack')
    if track and (field(track,'GuardRelease')==true or field(track,'RoyalRelease')==true) then return end
    if last_royal_block>=0 and now-last_royal_block<.08 then return end
    -- Allow the perfect-block cue from this contact to replace the soft pulse.
    normal_guard_due=now+.05
end
function C.on_guard_sound(event)
    if (event~=2799462876 and event~=4018642914 and event~=2262021573 and event~=769959643) or not current_object then return end
    local player=current_object
    if read(player,'get_currentStyle')~=3 then return end
    local track=read(player,'get_royalGuardTrack')
    local action=read(player,'get_nowActionNameFull')
    local lower=type(action)=='string' and action:lower() or ''
    if event~=2799462876 then
        local phase=classify_release(action)
        if (phase=='royal' and (event==4018642914 or event==769959643)) or ((phase=='normal' or phase=='air') and event==2262021573) then
            C.state.last_release_sound=event
            C.on_release(player,phase)
        end
        return
    end
    if (track and (field(track,'GuardRelease')==true or field(track,'RoyalRelease')==true)) or lower:find('release',1,true) then return end
    local guarding=lower:find('guard',1,true) or lower:find('block',1,true) or (track and field(track,'JustGuard')==true)
    if not guarding and (last_guard_contact<0 or os.clock()-last_guard_contact>.25) then return end
    C.state.last_guard_sound=event
    normal_guard_due=nil
    C.on_guard_result(player,true,true,false)
end
bind('app.PlayerDante','setGuardReaction','app.HitController.DamageInfo',C.on_guard_contact)
bind('app.PlayerDante','setGuardReversReaction','app.HitController.DamageInfo',C.on_guard_contact)
do
    local ok,err=pcall(function()
        local td=sdk.find_type_definition('via.wwise.WwiseContainer')
        if not td then error('WwiseContainer unavailable') end
        local count=0
        for _,method in ipairs(td:get_methods()) do
            if method:get_name()=='trigger' or method:get_name()=='triggerByFsm' then
                for i,param in ipairs(method:get_param_types() or {}) do
                    if param:get_full_name()=='System.UInt32' then
                        local slot=i+1
                        sdk.hook(method,function(args)
                            local success,message=pcall(function() C.on_guard_sound(sdk.to_int64(args[slot]) & 0xffffffff) end)
                            if not success then C.errors.royal_block_pre=tostring(message) end
                        end,function(retval) return retval end)
                        count=count+1;break
                    end
                end
            end
        end
        if count==0 then error('Royal Block audio hook unavailable') end
        C.royal_hook=count
    end)
    if not ok then C.errors.royal_block=tostring(err) end
end

-- Additional Faust creation path covers weapon-owned attacks omitted by Player.createShell.
do
    local td=sdk.find_type_definition('app.WeaponFaustHat')
    local method=td and td:get_method('createShell')
    local params=method and method:get_param_types()
    if method and method:get_num_params()==5 and params[1]:get_full_name()=='app.ShellTrack' and params[4]:get_full_name()=='System.Int32' and method:get_return_type():get_full_name()=='System.Void' then
        sdk.hook(method,function(args)
            local ok,err=pcall(function() C.on_faust_weapon(sdk.to_managed_object(args[2])) end)
            if not ok then C.errors.faust_shell_create=tostring(err) end
        end,function(retval) return retval end)
    end
end
bind('app.WeaponFaustHat','onDamageCalcEnd','app.HitController.DamageInfo',C.on_faust_weapon)
bind('app.Shell','onAttackHit','app.HitController.DamageInfo',function(shell) C.on_faust_shell(shell);C.on_devil_counter_shell(shell);C.on_sdt_shell(shell) end)
do
    local td=sdk.find_type_definition('app.Shell');local method=td and td:get_method('generateTerrainHitEffect')
    if method and method:get_num_params()==0 and method:get_return_type():get_full_name()=='System.Void' then
        sdk.hook(method,function(args)
            local ok,err=pcall(function() C.on_faust_shell(sdk.to_managed_object(args[2])) end)
            if not ok then C.errors.faust_terrain=tostring(err) end
        end,function(retval) return retval end)
    end
end
