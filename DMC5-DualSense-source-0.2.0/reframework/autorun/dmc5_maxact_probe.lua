-- Temporary event-only MAX-Act diagnostic; no game writes or effect output.
if reframework:get_game_name()~='dmc5' then return end
local dir='dmc5_dualsense/'
local started=os.clock();local rows={};local errors={};local metadata={};local dirty=true;local saved=0
local td=sdk.find_type_definition('app.PlayerNero')
if td then
    for index,m in ipairs(td:get_methods()) do
        if m:get_name()=='setMaxAct' then
            local params={};local supported=true
            for _,t in ipairs(m:get_param_types()) do
                local name=t:get_full_name();params[#params+1]=name
                if name~='System.Boolean' and name~='System.Int32' and name~='System.UInt32' then supported=false end
            end
            local label='setMaxAct_'..tostring(index)
            metadata[#metadata+1]={name=m:get_name(),params=params,returns=m:get_return_type():get_full_name(),observed=supported}
            if supported and m:get_return_type():get_full_name()=='System.Void' then
                local ok,err=pcall(function()
                    sdk.hook(m,function(args)
                        local storage=thread.get_hook_storage();storage[label]=nil
                        if os.clock()-started>180 or #rows>=200 then return end
                        local success,message=pcall(function()
                            local owner=sdk.to_managed_object(args[2])
                            local manager=sdk.get_managed_singleton(sdk.game_namespace('PlayerManager'))
                            local player=manager and manager:call('get_manualPlayer')
                            if not owner or not player or owner:get_address()~=player:get_address() then return end
                            local values={}
                            for i,name in ipairs(params) do values[i]={type=name,raw=sdk.to_int64(args[i+2])} end
                            storage[label]={owner=owner,row={time=os.clock()-started,action=owner:call('get_nowActionNameFull'),before=owner:call('get_exceedStock'),args=values}}
                        end)
                        if not success then errors[label]=tostring(message);dirty=true end
                    end,function(retval)
                        local storage=thread.get_hook_storage();local pending=storage[label];storage[label]=nil
                        if pending then
                            local ok,err=pcall(function()
                                pending.row.after=pending.owner:call('get_exceedStock')
                                rows[#rows+1]=pending.row;dirty=true
                            end)
                            if not ok then errors[label]=tostring(err);dirty=true end
                        end
                        return retval
                    end)
                end)
                if not ok then errors[label]=tostring(err) end
            end
        end
    end
end
json.dump_file(dir..'maxact_sdk.json',metadata)
re.on_frame(function()
    local now=os.clock()
    if dirty and now-saved>.5 then
        saved=now;dirty=false
        json.dump_file(dir..'maxact_probe.json',{rows=rows,errors=errors,elapsed=now-started,active=now-started<180 and #rows<200})
    end
end)
