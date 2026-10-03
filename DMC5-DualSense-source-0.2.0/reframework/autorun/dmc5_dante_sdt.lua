-- Read-only Dante SDT state; thresholds verified with the local SDK trace.
if reframework:get_game_name()~='dmc5' then return end
local D={held=false,percent=0,preparing=false,progress=0,entered=false,transforming=false,error=nil}
local previous_sin,previous_player=nil,nil
local was_ready=nil
local pending_enter=nil
_G.dmc5_dante_sdt=D
function D.update(player)
    D.active=false;D.short=false;D.action=nil;D.held=false;D.percent=0;D.preparing=false;D.progress=0;D.entered=false;D.transforming=false;D.ready_sound=false;D.error=nil
    if not player or player:get_type_definition():get_full_name()~='app.PlayerDante' then previous_sin=nil;previous_player=nil;was_ready=nil;pending_enter=nil;return end
    local ok,err=pcall(function()
        local id=tostring(player:get_address())
        if id~=previous_player then previous_sin=nil;previous_player=id;was_ready=nil;pending_enter=nil end
        local gauge=player:call('get_theDTGauge')
        local sin=player:call('get_isTheDevilTrigger')
        local pad=player:call('get_padInput')
        local buttons=pad and pad:call('get_buttonOnFlags')
        if type(gauge)~='number' or gauge~=gauge or gauge<0 or gauge>10000 or type(buttons)~='number' or type(sin)~='boolean' then previous_sin=nil;was_ready=nil;pending_enter=nil;return end
        D.percent=gauge/10000
        D.held=not sin and (buttons & 65536)~=0
        if sin and previous_sin==false then pending_enter=os.clock() end
        D.active=sin
        previous_sin=sin
        local action=player:call('get_nowActionNameFull')
        D.action=action
        local compact=type(action)=='string' and action:lower():gsub('[^a-z]','') or ''
        D.short=sin and (compact:find('tdtinvocationshort',1,true)~=nil or compact:find('tdtivocationshort',1,true)~=nil)
        D.transforming=sin and not D.short and compact:find('tdtinvocation',1,true)~=nil
        if pending_enter and sin and (D.short or D.transforming or os.clock()-pending_enter>.12) then
            if not D.short and not D.transforming then
                local ok,request=pcall(function() return player:get_field('IsShortTheDevilTriggerRequest') end)
                D.short=ok and request==true
            end
            D.entered=true;pending_enter=nil
        elseif not sin then pending_enter=nil end
        if D.held and gauge>=10000 then
            local charge=player:call('get_theDevilGaugeCharge')
            local timer=player:call('get_devilTriggerPressTimer')
            if (charge==1 or charge==2) and type(timer)=='number' and timer==timer then
                D.preparing=true;D.progress=math.max(0,math.min(1,timer/90))
            end
        end
        local ready=D.preparing and D.progress>=1
        -- A script reload while already ready does not replay the roar.
        D.ready_sound=ready and was_ready==false
        was_ready=ready
    end)
    if not ok then previous_sin=nil;was_ready=nil;D.error=tostring(err) end
end
function D.draw()
    imgui.text('SDT activo: '..tostring(D.active)..' / entrada corta: '..tostring(D.short))
    imgui.text('Sin DT: '..math.floor(D.percent*100)..'% / boton mantenido: '..tostring(D.held))
    imgui.text('Preparacion: '..math.floor(D.progress*100)..'% / activa: '..tostring(D.preparing))
    if D.error then imgui.text(D.error) end
end
