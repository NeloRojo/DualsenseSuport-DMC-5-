-- Temporary read-only diagnostic: keep only sounds around successful local MAX-Act.
if reframework:get_game_name() ~= 'dmc5' then return end
local started = os.clock()
local ring, captures, errors = {}, {}, {}
local pending, dirty = nil, true
local function active() return os.clock()-started < 120 and #captures < 4 end
local function observe(name)
local base = sdk.find_type_definition(name)
if base then
    for _, method in ipairs(base:get_methods()) do
        if method:get_name() == 'trigger' or method:get_name() == 'triggerByFsm' then
            local index, kind
            for i, typ in ipairs(method:get_param_types()) do
                local full=typ:get_full_name()
                if full == 'System.UInt32' or (name=='app.WwiseContainerApp' and full=='System.String') then index = i+2; kind=full; break end
            end
            if index then
                local label = name..':'..method:get_name()..':'..method:get_num_params()..':'..kind
                local ok, err = pcall(function()
                    sdk.hook(method, function(args)
                        if not active() then return end
                        local ok2, err2 = pcall(function()
                            local event
                            if kind=='System.UInt32' then event=sdk.to_int64(args[index]) & 0xffffffff
                            else local obj=sdk.to_managed_object(args[index]); event=obj and obj:call('ToString') end
                            -- Native wrappers can omit the thread-context slot. Keep both
                            -- numeric layouts for comparison against real bank event IDs.
                            local native_event
                            if name=='via.wwise.WwiseContainer' and kind=='System.UInt32' then
                                native_event=sdk.to_int64(args[index-1]) & 0xffffffff
                            end
                            ring[#ring+1] = {time=os.clock()-started, event=event, native_event=native_event, method=label}
                            if #ring > 128 then table.remove(ring, 1) end
                        end)
                        if not ok2 then errors[label]=tostring(err2); dirty=true end
                    end, function(retval) return retval end)
                end)
                if not ok then errors[label]=tostring(err) end
            end
        end
    end
end
end
observe('via.wwise.WwiseContainer')
observe('app.WwiseContainerApp')
local holder=sdk.find_type_definition('app.player.SoundHolder')
local holder_start=holder and holder:get_method('start')
if holder_start and holder_start:get_num_params()==1 then
    sdk.hook(holder_start,function(args)
        if not active() then return end
        local ok,err=pcall(function()
            local obj=sdk.to_managed_object(args[2])
            if obj then
                ring[#ring+1]={time=os.clock()-started,event=obj:call('get_startID'),trigger=obj:call('get_triggerID'),method='SoundHolder:start'}
                if #ring>128 then table.remove(ring,1) end
            end
        end)
        if not ok then errors.holder=tostring(err); dirty=true end
    end,function(retval) return retval end)
end
local nero = sdk.find_type_definition('app.PlayerNero')
local method = nero and nero:get_method('setMaxAct')
if method and method:get_num_params()==1 and method:get_param_types()[1]:get_full_name()=='System.Boolean' then
    sdk.hook(method, function(args)
        local storage=thread.get_hook_storage(); storage.maxact_sound_owner=nil
        if not active() or sdk.to_int64(args[3])==0 then return end
        local ok, err = pcall(function()
            local owner=sdk.to_managed_object(args[2])
            local manager=sdk.get_managed_singleton(sdk.game_namespace('PlayerManager'))
            local player=manager and manager:call('get_manualPlayer')
            if owner and player and owner:get_address()==player:get_address() then storage.maxact_sound_owner=owner end
        end)
        if not ok then errors.maxact=tostring(err); dirty=true end
    end, function(retval)
        local storage=thread.get_hook_storage(); local owner=storage.maxact_sound_owner; storage.maxact_sound_owner=nil
        if owner then
            local ok,err=pcall(function()
                if owner:call('get_exceedStock')==3 then pending={time=os.clock()-started,action=owner:call('get_nowActionNameFull')} end
            end)
            if not ok then errors.maxact=tostring(err); dirty=true end
        end
        return retval
    end)
else errors.maxact='Expected setMaxAct(Boolean) unavailable' end
re.on_frame(function()
    local now=os.clock()-started
    if pending and now-pending.time>.4 then
        pending.sounds={}
        for _, row in ipairs(ring) do
            if row.time>=pending.time-.35 and row.time<=pending.time+.4 then pending.sounds[#pending.sounds+1]=row end
        end
        captures[#captures+1]=pending; pending=nil; dirty=true
    end
    if dirty then
        dirty=false
        json.dump_file('dmc5_dualsense/maxact_sounds.json',{captures=captures,errors=errors,active=active(),observed=#ring})
    end
end)
