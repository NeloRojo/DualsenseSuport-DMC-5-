-- One-shot read-only SDK catalog. No hooks or audio capture.
if reframework:get_game_name()~='dmc5' then return end
local done=false
re.on_frame(function()
    if done then return end
    local ok,err=pcall(function()
        local manager=sdk.get_managed_singleton(sdk.game_namespace('PlayerManager'))
        local player=manager and manager:call('get_manualPlayer')
        if not player or player:get_type_definition():get_full_name()~='app.PlayerVergilPL' then return end
        done=true
        local rows={};local seen={}
        local function dump(td,obj)
            if not td or seen[td:get_full_name()] then return end
            seen[td:get_full_name()]=true
            local row={type=td:get_full_name(),fields={},methods={}}
            for _,f in ipairs(td:get_fields()) do
                local item={name=f:get_name(),type=f:get_type():get_full_name()}
                if item.type=='System.UInt32' or item.type=='System.String' then
                    local good,value=pcall(function() return f:get_data(obj) end)
                    if good and (type(value)=='number' or type(value)=='string') then item.value=value end
                end
                row.fields[#row.fields+1]=item
            end
            for _,m in ipairs(td:get_methods()) do
                row.methods[#row.methods+1]={name=m:get_name(),params=m:get_num_params(),returns=m:get_return_type():get_full_name()}
            end
            rows[#rows+1]=row
        end
        local td=player:get_type_definition();dump(td,player)
        for _,m in ipairs(td:get_methods()) do
            local name=m:get_name()
            if m:get_num_params()==0 and name:match('^get_cached') then
                local good,obj=pcall(function() return player:call(name) end)
                if good and obj then
                    local good_td,object_td=pcall(function() return obj:get_type_definition() end)
                    if good_td then dump(object_td,obj) end
                end
            end
        end
        json.dump_file('dmc5_dualsense/vergil_audio_catalog.json',{types=rows})
    end)
    if not ok then done=true;json.dump_file('dmc5_dualsense/vergil_audio_catalog.json',{error=tostring(err)}) end
end)
