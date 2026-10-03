-- Bounded read-only probe. No effects until a real sword-parry result is verified.
if reframework:get_game_name()~='dmc5' then return end
local started=os.clock()
local owner_id, last_poll=nil, 0
local ring, rows, errors, metadata, pending={},{},{},{},{}
local dirty=true
local enum_values={}
local result_type=sdk.find_type_definition('app.HitController.ParryResultEnum')
if result_type then
    for _,field in ipairs(result_type:get_fields()) do
        local ok,value=pcall(function() return field:get_data(nil) end)
        if ok and type(value)=='number' then enum_values[field:get_name()]=value end
    end
end
local data_fields={}
local data_type=sdk.find_type_definition('app.HitController.ParryData')
if data_type then
    for _,field in ipairs(data_type:get_fields()) do
        data_fields[#data_fields+1]={name=field:get_name(),type=field:get_type():get_full_name()}
    end
end
local function active() return os.clock()-started<180 and #rows<40 end
local function remember(row)
    ring[#ring+1]=row
    if #ring>128 then table.remove(ring,1) end
end
-- Native one-argument event slot validated by the previous MAX-Act trace.
local audio=nil -- This follow-up needs combat results only, not a sound trace.
if audio then
    for _,m in ipairs(audio:get_methods()) do
        if m:get_name()=='trigger' or m:get_name()=='triggerByFsm' then
            local index
            for i,t in ipairs(m:get_param_types()) do if t:get_full_name()=='System.UInt32' then index=i+1; break end end
            if index then
            local ok,err=pcall(function()
                sdk.hook(m,function(args)
                    if active() then remember({time=os.clock()-started,event=sdk.to_int64(args[index]) & 0xffffffff,method=m:get_name()..':'..m:get_num_params()}) end
                end,function(retval) return retval end)
            end)
            if not ok then errors.audio=tostring(err) end
            end
        end
    end
end
local hooked={}
for _,type_name in ipairs({'app.PlayerNero','app.PlayerDante','app.PlayerVergil','app.Player','app.character.Character'}) do
    local td=sdk.find_type_definition(type_name)
    if td then
        for _,m in ipairs(td:get_methods()) do
            local name=m:get_name()
            if name=='setParryAction' or name=='setParryStylishBonus' or name=='setRepelled' or name=='onGuard' then
                local label=type_name..':'..name
                local params={}
                for _,t in ipairs(m:get_param_types()) do params[#params+1]=t:get_full_name() end
                metadata[#metadata+1]={method=label,params=params,returns=m:get_return_type():get_full_name()}
                local identity=tostring(m:get_function())
                if not hooked[identity] then
                    hooked[identity]=true
                    local ok,err=pcall(function()
                        sdk.hook(m,function(args)
                            if not active() then return end
                            local ok2,err2=pcall(function()
                                local obj=sdk.to_managed_object(args[2])
                                if not obj or tostring(obj:get_address())~=owner_id then return end
                                local row={time=os.clock()-started,method=label,action=obj:call('get_nowActionNameFull'),args={}}
                                row.character=obj:get_type_definition():get_full_name()
                                local short_ok,short=pcall(function() return obj:call('get_isShortRangeAttack') end)
                                if short_ok then row.short_range=short end
                                for i,typ in ipairs(params) do
                                    local value={type=typ}
                                    if typ=='System.Boolean' or typ=='System.Int32' or typ=='System.UInt32' or typ=='app.HitController.ParryResultEnum' then value.raw=sdk.to_int64(args[i+2]) end
                                    if typ=='app.HitController.ParryData' then
                                        local good,data=pcall(sdk.to_managed_object,args[i+2])
                                        if good and data then
                                            local read_ok,true_parry=pcall(function() return data:get_field('<isTrueParry>k__BackingField') end)
                                            if read_ok and type(true_parry)=='boolean' then row.true_parry=true_parry end
                                        end
                                    end
                                    row.args[#row.args+1]=value
                                end
                                local good,flag=pcall(function() return obj:call('get_isParry') end)
                                if good then row.is_parry=flag end
                                pending[#pending+1]=row
                                if #pending>40 then table.remove(pending,1) end
                            end)
                            if not ok2 then errors[label]=tostring(err2); dirty=true end
                        end,function(retval) return retval end)
                    end)
                    if not ok then errors[label]=tostring(err) end
                end
            end
        end
    end
end
json.dump_file('dmc5_dualsense/parry_sdk.json',{methods=metadata,result_enum=enum_values,data_fields=data_fields})
re.on_frame(function()
    local now=os.clock()-started
    if active() and now-last_poll>.1 then
        last_poll=now
        local ok,err=pcall(function()
            local manager=sdk.get_managed_singleton(sdk.game_namespace('PlayerManager'))
            local player=manager and manager:call('get_manualPlayer')
            owner_id=player and tostring(player:get_address()) or nil
        end)
        if not ok then errors.player=tostring(err); dirty=true end
    end
    for i=#pending,1,-1 do
        local row=pending[i]
        if now-row.time>.4 then
            row.sounds={}
            for _,sound in ipairs(ring) do
                if sound.time>=row.time-.35 and sound.time<=row.time+.4 then row.sounds[#row.sounds+1]=sound end
            end
            rows[#rows+1]=row; table.remove(pending,i); dirty=true
        end
    end
    if dirty then
        dirty=false
        json.dump_file('dmc5_dualsense/parry_probe.json',{rows=rows,errors=errors,active=active(),elapsed=now})
    end
end)
re.on_draw_ui(function()
    if imgui.tree_node('Sword parry diagnostic') then
        imgui.text('Active: '..tostring(active())..' / results: '..#rows)
        imgui.text('Read-only; stops after 3 minutes. Reset scripts to restart.')
        imgui.tree_pop()
    end
end)
