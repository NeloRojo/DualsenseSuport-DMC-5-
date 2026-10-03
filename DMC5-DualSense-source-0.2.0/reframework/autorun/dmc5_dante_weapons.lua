-- Read-only Dante weapon identities. No guessed numeric IDs or game writes.
if reframework:get_game_name()~='dmc5' then return end
local D={state={},errors={},enums={},rows={},started=os.clock(),active=false}
_G.dmc5_dante_weapons=D
for _,kind in ipairs({'S','L'}) do
    local values={}
    local td=sdk.find_type_definition('app.PlayerDante.Weapon'..kind)
    if td then
        for _,field in ipairs(td:get_fields()) do
            local ok,value=pcall(function() return field:get_data(nil) end)
            if ok and type(value)=='number' then values[tostring(value)]=field:get_name() end
        end
    end
    D.enums[kind]=values
end
local fields={}
local td=sdk.find_type_definition('app.PlayerDante')
if td then
    for _,method in ipairs(td:get_methods()) do
        if method:get_name():match('Weapon[SL]') and (method:get_name():match('^get_current') or method:get_name():match('^get_next') or method:get_name():match('^get_slot') or method:get_name():match('^get_weapon[SL]_ID')) then
            local params={}
            for _,t in ipairs(method:get_param_types()) do params[#params+1]=t:get_full_name() end
            fields[#fields+1]={name=method:get_name(),params=params,returns=method:get_return_type():get_full_name()}
        end
    end
end
json.dump_file('dmc5_dualsense/dante_weapon_sdk.json',{enums=D.enums,methods=fields})
local last_key,dirty,saved=nil,false,0
local function read(player,method)
    local ok,value=pcall(function() return player:call(method) end)
    if ok then return value end
    D.errors[method]=tostring(value)
end
local function slots(player,kind)
    local list=read(player,'get_slotWeapon'..kind)
    if not list then return {} end
    local ok,result=pcall(function()
        local count=list:call('get_Count')
        if type(count)~='number' or count<0 or count>16 then return {} end
        local result={}
        for i=0,count-1 do
            local id=list:call('get_Item(System.Int32)',i)
            result[#result+1]={id=id,name=D.enums[kind][tostring(id)]}
        end
        return result
    end)
    if ok then return result end
    D.errors['slots'..kind]=tostring(result);return {}
end
function D.update(player)
    if not player or player:get_type_definition():get_full_name()~='app.PlayerDante' then D.state={};return end
    local state={player=tostring(player:get_address())}
    for _,kind in ipairs({'S','L'}) do
        local current=read(player,'get_currentWeapon'..kind)
        local index=read(player,'get_weapon'..kind..'_ID')
        state[kind]={id=current,index=index,name=D.enums[kind][tostring(current)]}
    end
    local key=state.player..':'..tostring(state.S.id)..':'..tostring(state.S.index)..':'..tostring(state.L.id)..':'..tostring(state.L.index)
    if key~=last_key then
        for _,kind in ipairs({'S','L'}) do
            state[kind].slots=slots(player,kind)
            local list=state[kind].slots
            -- Only report next after validating the slot index against the current enum.
            local found=nil
            for i,item in ipairs(list) do
                if item.id==state[kind].id then
                    if found then found=nil;break end
                    found=i
                end
            end
            if found then state[kind].next=list[found%#list+1] end
        end
        last_key=key
        if D.active and os.clock()-D.started<90 and #D.rows<80 then
            D.rows[#D.rows+1]={time=os.clock()-D.started,state=state};dirty=true
        end
    else
        state.S.slots=D.state.S and D.state.S.slots
        state.S.next=D.state.S and D.state.S.next
        state.L.slots=D.state.L and D.state.L.slots
        state.L.next=D.state.L and D.state.L.next
    end
    D.state=state
end
re.on_frame(function()
    local now=os.clock()
    if D.active and (now-D.started>=90 or #D.rows>=80) then D.active=false;dirty=true end
    if dirty and now-saved>.25 then
        dirty=false;saved=now
        json.dump_file('dmc5_dualsense/dante_weapon_probe.json',{enums=D.enums,rows=D.rows,errors=D.errors,active=D.active})
    end
end)
function D.draw()
    for _,item in ipairs({{'L','L2 / Armas de fuego'},{'S','R2 / Armas cuerpo a cuerpo'}}) do
        local state=D.state[item[1]]
        if state then
            imgui.text(item[2]..': '..tostring(state.name or state.id or 'no disponible'))
            imgui.text('Siguiente: '..tostring(state.next and (state.next.name or state.next.id) or 'sin validar'))
        end
    end
    imgui.text('Registro de identificadores: '..tostring(D.active)..' / cambios '..#D.rows)
    if imgui.button('Registrar cambios de armas (90 s)') then D.rows={};D.started=os.clock();D.active=true;last_key=nil end
    for name,message in pairs(D.errors) do imgui.text(name..': '..message) end
end
