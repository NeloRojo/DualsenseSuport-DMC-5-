-- Development-only, read-only SDK service. No arbitrary Lua/method execution.
if reframework:get_game_name()~='dmc5' then return end
local dir='dmc5_dualsense/'
local B={enabled=true,session=tostring(os.time())..':'..tostring(os.clock()),rows={},recording=false,error=nil}
_G.dmc5_dev_bridge=B
local last_seq,last_poll,last_sample,last_publish=-1,-1,-1,-1
local deadline,limit=0,256
local trace_token=nil
local function player()
    local manager=sdk.get_managed_singleton(sdk.game_namespace('PlayerManager'))
    return manager and manager:call('get_manualPlayer')
end
local function get(obj,name)
    local ok,value=pcall(function() return obj:call(name) end)
    if ok then return value end
end
local function scalar(value)
    local kind=type(value)
    if kind=='string' then return value:sub(1,512) end
    if kind=='boolean' or (kind=='number' and value==value and math.abs(value)<math.huge) then return value end
    if value~=nil then
        local ok,td=pcall(function() return value:get_type_definition() end)
        return ok and {type=td:get_full_name()} or {type=kind}
    end
end
local function snapshot()
    local p=player()
    local control=json.load_file(dir..'control.json') or {}
    local result={available=p~=nil,paused=control.game_paused==true}
    if p then
        result.character=p:get_type_definition():get_full_name()
        result.action=scalar(get(p,'get_nowActionNameFull'))
        result.sin_dt=scalar(get(p,'get_isTheDevilTrigger'))
        result.dt=scalar(get(p,'get_isDevilTrigger'))
        result.style=scalar(get(p,'get_currentStyle'))
        result.weapon_l=scalar(get(p,'get_currentWeaponL'))
        result.weapon_s=scalar(get(p,'get_currentWeaponS'))
    end
    return result
end
local function describes(td,obj,filter)
    if not td then error('SDK type/object unavailable') end
    filter=type(filter)=='string' and filter:lower() or ''
    local result={type=td:get_full_name(),fields={},methods={}}
    for _,field in ipairs(td:get_fields()) do
        local name=field:get_name()
        if #result.fields<256 and name:lower():find(filter,1,true) then
            local row={name=name,type=field:get_type():get_full_name()}
            if obj then local ok,value=pcall(function() return field:get_data(obj) end);if ok then row.value=scalar(value) end end
            result.fields[#result.fields+1]=row
        end
    end
    for _,method in ipairs(td:get_methods()) do
        local name=method:get_name()
        if #result.methods<300 and name:lower():find(filter,1,true) then
            local row={name=name,returns=method:get_return_type():get_full_name(),parameters={}}
            for _,param in ipairs(method:get_param_types() or {}) do row.parameters[#row.parameters+1]=param:get_full_name() end
            result.methods[#result.methods+1]=row
        end
    end
    return result
end
local function command(request,now)
    local name=request.command
    if name=='snapshot' then return snapshot() end
    if name=='inspect_type' then
        if type(request.type_name)~='string' or #request.type_name>200 then error('type_name required') end
        return describes(sdk.find_type_definition(request.type_name),nil,request.filter)
    end
    if name=='inspect_object' then
        local obj=player();local path=request.path or {}
        if type(path)~='table' or #path>5 then error('At most five SDK field names') end
        for _,key in ipairs(path) do
            if not obj or type(key)~='string' or #key>150 then error('Object field unavailable') end
            obj=obj:get_field(key)
        end
        if not obj then error('Player/object unavailable') end
        return describes(obj:get_type_definition(),obj,request.filter)
    end
    if name=='start_trace' then
        local seconds=request.seconds or 30
        if type(seconds)~='number' or seconds~=seconds or seconds<1 or seconds>120 then error('Trace duration 1..120 seconds') end
        B.rows={};B.recording=true;deadline=now+seconds;trace_token=nil
        return {recording=true,seconds=seconds,max_rows=limit}
    end
    if name=='stop_trace' then B.recording=false;return {recording=false,count=#B.rows} end
    if name=='get_trace' then return {recording=B.recording,rows=B.rows} end
    if name=='clear_trace' then B.rows={};B.recording=false;return {count=0} end
    error('Unsupported read-only command')
end
local function service(now)
    if B.recording and (now>=deadline or #B.rows>=limit) then B.recording=false end
    if B.recording and now-last_sample>=.03 then
        last_sample=now
        local state=snapshot();local token=tostring(state.character)..':'..tostring(state.sin_dt)..':'..tostring(state.action)
        if token~=trace_token then trace_token=token;state.time=now;B.rows[#B.rows+1]=state end
    end
    if now-last_poll<.2 then return end
    last_poll=now
    local request=json.load_file(dir..'dev_request.json')
    if type(request)=='table' and request.session==B.session and type(request.seq)=='number' and request.seq%1==0 and request.seq>last_seq then
        last_seq=request.seq
        local ok,result=pcall(command,request,now)
        json.dump_file(dir..'dev_response.json',{session=B.session,seq=request.seq,command=request.command,ok=ok,result=ok and result or nil,error=not ok and tostring(result) or nil})
    end
    if now-last_publish>=.2 then
        last_publish=now
        json.dump_file(dir..'dev_live.json',{session=B.session,heartbeat=os.time(),enabled=true,state=snapshot(),recording=B.recording,trace_count=#B.rows,error=B.error})
    end
end
re.on_frame(function()
    if not B.enabled then return end
    local ok,err=pcall(service,os.clock())
    B.error=not ok and tostring(err) or nil
end)
re.on_draw_ui(function()
    if not imgui.tree_node('DMC5 desarrollo: conexion en vivo') then return end
    local changed,value=imgui.checkbox('Habilitar puente de desarrollo',B.enabled)
    if changed then B.enabled=value;if not value then B.recording=false end end
    imgui.text('Estado: '..(B.enabled and 'lectura activa' or 'desactivado'))
    imgui.text('Fases en memoria: '..#B.rows..' / '..limit)
    if B.error then imgui.text(B.error) end
    imgui.tree_pop()
end)
