-- Optional read-only sound diagnostic; starts armed, bounded to five minutes.
if reframework:get_game_name()~='dmc5' then return end
local dir='dmc5_dualsense/'
local rows={}; local errors={}; local started=os.clock(); local armed_until=started+300; local last_save=0
local player=nil; local action=nil; local dt=nil
local type_dump={}
for _,name in ipairs({'app.WwiseContainerApp','app.player.SoundHolder','app.fsm2.player.pl0000.NeroSoundTrigger.TriggerData'}) do
    local td=sdk.find_type_definition(name); local depth=0
    while td and depth<4 do
        local row={type=td:get_full_name(),methods={},fields={}}
        for _,m in ipairs(td:get_methods()) do
            local params={}; for _,t in ipairs(m:get_param_types()) do params[#params+1]=t:get_full_name() end
            row.methods[#row.methods+1]={name=m:get_name(),params=params,returns=m:get_return_type():get_full_name()}
        end
        for _,f in ipairs(td:get_fields()) do row.fields[#row.fields+1]={name=f:get_name(),type=f:get_type():get_full_name()} end
        type_dump[#type_dump+1]=row; td=td:get_parent_type(); depth=depth+1
    end
end
json.dump_file(dir..'audio_types.json',type_dump)
local function record(row)
    if os.clock()>armed_until or #rows>=600 then return end
    row.time=os.clock()-started; row.action=action; row.dt=dt
    rows[#rows+1]=row
end
local nero=sdk.find_type_definition('app.fsm2.player.pl0000.NeroSoundTrigger')
local target=nero and nero:get_method('getTarget')
if target and target:get_num_params()==1 then
    sdk.hook(target,function(args)
        if os.clock()>armed_until or #rows>=600 then return end
        local ok,err=pcall(function()
            local data=sdk.to_managed_object(args[3])
            if data then record({kind='nero_sound',name=data:get_field('Name'),timing=data:get_field('Timing')}) end
        end)
        if not ok then errors.nero=tostring(err) end
    end,function(retval) return retval end)
end
-- Observe the engine's final overload and FSM entry as well as app wrappers.
local base=sdk.find_type_definition('via.wwise.WwiseContainer')
if base then
    for _,m in ipairs(base:get_methods()) do
        if (m:get_name()=='trigger' and m:get_num_params()==9) or m:get_name()=='triggerByFsm' then
            local types=m:get_param_types(); local index=nil
            for i,t in ipairs(types) do if t:get_full_name()=='System.UInt32' then index=i+2; break end end
            if index then
                local label='engine:'..m:get_name()..':'..tostring(#types)
                local ok,err=pcall(function()
                    sdk.hook(m,function(args)
                        if os.clock()>armed_until or #rows>=600 then return end
                        record({kind='engine',method=label,event=sdk.to_int64(args[index]) & 0xffffffff})
                    end,function(retval) return retval end)
                end)
                if not ok then errors[label]=tostring(err) end
            end
        end
    end
end
local holder=sdk.find_type_definition('app.player.SoundHolder')
local method=holder and holder:get_method('start')
if method and method:get_num_params()==1 and method:get_param_types()[1]:get_full_name()=='app.GameModel' then
    sdk.hook(method,function(args)
        if os.clock()>armed_until or #rows>=600 then return end
        local ok,err=pcall(function()
            local obj=sdk.to_managed_object(args[2]); local model=sdk.to_managed_object(args[3])
            if obj then record({kind='holder',start_id=obj:call('get_startID'),trigger_id=obj:call('get_triggerID'),model=model and tostring(model:get_address()),local_player=player and tostring(player:get_address())}) end
        end)
        if not ok then errors.holder=tostring(err) end
    end,function(retval) return retval end)
end
local td=sdk.find_type_definition('app.WwiseContainerApp')
if td then
    for _,m in ipairs(td:get_methods()) do
        if m:get_name()=='trigger' or m:get_name()=='triggerByFsm' then
            local types=m:get_param_types(); local index=nil; local kind=nil
            for i,t in ipairs(types) do
                local name=t:get_full_name()
                if name=='System.UInt32' or name=='System.String' then index=i+2; kind=name; break end
            end
            if index and m:get_return_type():get_full_name()=='System.Void' then
                local label=m:get_name()..':'..kind..':'..tostring(#types)
                local ok,err=pcall(function()
                    sdk.hook(m,function(args)
                        if os.clock()>armed_until or #rows>=600 then return end
                        local success,message=pcall(function()
                            local value
                            if kind=='System.UInt32' then value=sdk.to_int64(args[index]) & 0xffffffff
                            else local obj=sdk.to_managed_object(args[index]); value=obj and obj:call('ToString') end
                            record({kind='wwise',method=label,event=value,container=tostring(args[2])})
                        end)
                        if not success then errors[label]=tostring(message) end
                    end,function(retval) return retval end)
                end)
                if not ok then errors[label]=tostring(err) end
            end
        end
    end
end
re.on_frame(function()
    local now=os.clock()
    if now>armed_until then return end
    pcall(function()
        local manager=sdk.get_managed_singleton(sdk.game_namespace('PlayerManager'))
        player=manager and manager:call('get_manualPlayer')
        if player then
            action=player:call('get_nowActionNameFull')
            local new_dt=player:call('get_isDevilTrigger')
            if new_dt~=dt then dt=new_dt; record({kind='dt_state',enabled=dt}) end
        end
    end)
    if now-last_save>.25 then
        last_save=now
        json.dump_file(dir..'audio_probe.json',{rows=rows,errors=errors,active=now<armed_until,elapsed=now-started})
    end
end)
re.on_draw_ui(function()
    if imgui.tree_node('Nero audio diagnostic') then
        if imgui.button('Record DT sound (5 minutes)') then rows={}; started=os.clock(); armed_until=started+300 end
        imgui.text('Events: '..tostring(#rows)..' / armed '..tostring(os.clock()<armed_until))
        imgui.tree_pop()
    end
end)
