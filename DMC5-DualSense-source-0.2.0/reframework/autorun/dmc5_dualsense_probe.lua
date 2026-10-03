-- Optional, bounded, read-only Nero diagnostics. Does not send controller effects.
if reframework:get_game_name()~='dmc5' then return end
local dir='dmc5_dualsense/'
local getters={'get_nowActionName','get_nowActionNameFull','get_isAttackHit','get_isAttack','get_isShortRangeAttack','get_isLongRangeAttack','get_currentWeaponType','get_exceedStock','get_exceedLevel','get_exceedGauge','get_exceedTimer','get_isExceedComp','get_actionTimer','get_attackTimer','get_shortRangeAttackTimer','get_hitAttackID'}
local state={rows={},errors={},signatures={},phase='idle'}
local nonce=nil
local started=0
local duration=0
local poll=0
local flushed=0
local inspected=nil
local hook_errors={}
local function primitive(v)
    local t=type(v)
    if t=='boolean' or t=='string' or (t=='number' and v==v) then return v end
end
local function inspect(player)
    local types={}
    for _,name in ipairs({'app.BlueRose','app.WeaponRedQueen','app.fsm2.player.pl0000.NeroSoundTrigger','app.player.SoundHolder','app.WwiseContainerApp'}) do
        local td=sdk.find_type_definition(name)
        if td then
            local row={type=name,fields={},methods={}}
            for _,field in ipairs(td:get_fields()) do
                table.insert(row.fields,{name=field:get_name(),type=field:get_type():get_full_name()})
            end
            for _,m in ipairs(td:get_methods()) do
                local params={}
                for _,p in ipairs(m:get_param_types()) do table.insert(params,p:get_full_name()) end
                table.insert(row.methods,{name=m:get_name(),params=params,returns=m:get_return_type():get_full_name()})
            end
            table.insert(types,row)
        end
    end
    json.dump_file(dir..'audio_sdk.json',types)
    local td=player:get_type_definition()
    local depth=0
    while td and depth<12 do
        for _,m in ipairs(td:get_methods()) do
            local name=m:get_name()
            if name:find('AttackHit') or name=='attackHitCore' or name=='onAtkCalcDamageEnd' or name=='setupBlueRoseAttack' or name=='onRedQueenChargeComplete' then
                local params={}
                for _,p in ipairs(m:get_param_types()) do table.insert(params,p:get_full_name()) end
                table.insert(state.signatures,{owner=td:get_full_name(),name=name,params=params,returns=m:get_return_type():get_full_name()})
            end
        end
        td=td:get_parent_type();depth=depth+1
    end
end
-- Observe verified signatures only, preserving arguments and return values.
for _,candidate in ipairs({{'app.PlayerNero','attackHitCore'},{'app.Player','onAttackHit'},{'app.Player','onAtkCalcDamageEnd'}}) do
    local label=candidate[1]..':'..candidate[2]
    local ok,err=pcall(function()
        local td=sdk.find_type_definition(candidate[1])
        local method=td and td:get_method(candidate[2])
        if not method or method:get_num_params()~=1 or method:get_param_types()[1]:get_full_name()~='app.HitController.DamageInfo' or method:get_return_type():get_full_name()~='System.Void' then error('Unexpected hit signature') end
        sdk.hook(method,function(args)
            if not state.active or #state.rows>=2400 then return end
            local success,message=pcall(function()
                local player=sdk.to_managed_object(args[2])
                if not player or tostring(player:get_address())~=inspected then return end
                local row={kind='hit_hook',method=label,time=os.clock()-started,player=inspected}
                for _,name in ipairs({'get_nowActionNameFull','get_isShortRangeAttack','get_isLongRangeAttack','get_currentWeaponType'}) do
                    local read_ok,value=pcall(function() return player:call(name) end)
                    if read_ok then row[name]=primitive(value) end
                end
                table.insert(state.rows,row)
            end)
            if not success then state.errors[label]=tostring(message) end
        end,function(retval) return retval end)
    end)
    if not ok then hook_errors[label]=tostring(err) end
end
re.on_frame(function()
    local now=os.clock()
    if now-poll<.025 then return end
    poll=now
    local command=json.load_file(dir..'probe_control.json')
    if type(command)=='table' and command.id~=nil and command.id~=nonce then
        nonce=command.id; started=now
        duration=math.max(1,math.min(60,tonumber(command.duration) or 30))
        state={id=nonce,phase=tostring(command.phase or 'attack'),rows={},errors={},hook_errors=hook_errors,signatures={}}
        inspected=nil
    end
    if nonce==nil then return end
    state.active=now-started<duration and #state.rows<2400
    if state.active then
        local ok,err=pcall(function()
            local manager=sdk.get_managed_singleton(sdk.game_namespace('PlayerManager'))
            local player=manager and manager:call('get_manualPlayer')
            if not player or player:get_type_definition():get_full_name()~='app.PlayerNero' then return end
            local id=tostring(player:get_address())
            if inspected~=id then
                inspected=id
                local success,message=pcall(function() inspect(player) end)
                if not success then state.errors.inspect=tostring(message) end
            end
            local row={time=now-started,player=id}
            for _,name in ipairs(getters) do
                local success,value=pcall(function() return player:call(name) end)
                if success then row[name]=primitive(value) else state.errors[name]=tostring(value) end
            end
            table.insert(state.rows,row)
        end)
        if not ok then state.errors.frame=tostring(err) end
    end
    if now-flushed>1 then
        flushed=now; json.dump_file(dir..'probe_result.json',state)
    end
end)
re.on_draw_ui(function()
    if imgui.tree_node('DualSense attack diagnostics') then
        imgui.text('Phase: '..state.phase..' / active '..tostring(state.active or false))
        imgui.text('Samples: '..tostring(#state.rows))
        for name,message in pairs(state.errors) do imgui.text(name..': '..message) end
        imgui.tree_pop()
    end
end)
