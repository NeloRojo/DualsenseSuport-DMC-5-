-- Temporary, read-only charge diagnostic. No hooks, game writes or effects.
if reframework:get_game_name()~='dmc5' then return end
local dir='dmc5_dualsense/'
local started=os.clock(); local last_poll=0; local last_save=0; local rows={}; local errors={}; local previous=nil
local td=sdk.find_type_definition('app.ChargeChecker')
local metadata={type='app.ChargeChecker',fields={},methods={}}
if td then
    for _,f in ipairs(td:get_fields()) do metadata.fields[#metadata.fields+1]={name=f:get_name(),type=f:get_type():get_full_name()} end
    for _,m in ipairs(td:get_methods()) do
        local params={}; for _,t in ipairs(m:get_param_types()) do params[#params+1]=t:get_full_name() end
        metadata.methods[#metadata.methods+1]={name=m:get_name(),params=params,returns=m:get_return_type():get_full_name()}
    end
end
json.dump_file(dir..'maxbet_charge_sdk.json',metadata)
local function primitive(v)
    local t=type(v); return t=='number' or t=='string' or t=='boolean'
end
local function inspect(obj)
    local values={}
    if not obj then return values end
    local def=obj:get_type_definition();local depth=0
    while def and depth<3 do
        for _,f in ipairs(def:get_fields()) do
            local ok,v=pcall(function() return f:get_data(obj) end)
            if ok and primitive(v) then values[f:get_name()]=v end
        end
        def=def:get_parent_type();depth=depth+1
    end
    return values
end
re.on_frame(function()
    local now=os.clock(); if now-started>180 or #rows>=1600 or now-last_poll<.025 then return end
    last_poll=now
    local ok,err=pcall(function()
        local manager=sdk.get_managed_singleton(sdk.game_namespace('PlayerManager'))
        local player=manager and manager:call('get_manualPlayer')
        if not player then return end
        local action=player:call('get_nowActionNameFull')
        if type(action)~='string' or not action:find('RedQueenSkill.MaximumBet.',1,true) then previous=nil;return end
        local redqueen=player:get_field('RedQueenCharge')
        local motion=player:get_field('<motionCharge>k__BackingField')
        local row={time=now-started,action=action,redqueen=inspect(redqueen),motion=inspect(motion)}
        rows[#rows+1]=row
    end)
    if not ok then errors.capture=tostring(err) end
    if now-last_save>.25 then last_save=now;json.dump_file(dir..'maxbet_charge_probe.json',{rows=rows,errors=errors,elapsed=now-started}) end
end)
