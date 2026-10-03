-- Development-only audio selection. No SDK hooks or retained game objects.
if reframework:get_game_name()~='dmc5' then return end
local A={error=''}
_G.dmc5_audio_studio=A
local dir='dmc5_dualsense/'
local sequence=0
local seconds=12
local first,last,length=0,0,0
local page=0
local selected=nil
local selected_start,selected_end=0,0
local volume=50
local layer_delay,layer_volume=0,100
local include_other=false
local limit_candidates=true
local reference_limit=true
local candidate_max_ms=4000
local function candidate_limit()
    if not limit_candidates then return 0 end
    return (reference_limit and math.max(80,last-first) or candidate_max_ms)/1000
end
local label='Nueva habilidad'
local function send(event,fields)
    local ok,err=pcall(function()
        local status=json.load_file(dir..'status.json')
        if type(status)~='table' or not status.session or not status.heartbeat or os.time()-status.heartbeat>4 then error('Helper desconectado; espera a que vuelva a conectar.') end
        sequence=sequence+1
        local request={session=status.session,seq=-os.time()*100000-sequence,event=event}
        for k,v in pairs(fields or {}) do request[k]=v end
        json.dump_file(dir..'request.json',request)
    end)
    A.error=ok and '' or tostring(err)
end
local function slider(name,current,min,max)
    local changed,value=imgui.slider_int(name,current,min,max)
    return changed and value or current
end
function A.draw()
    local ok,status=pcall(json.load_file,dir..'status.json')
    status=ok and type(status)=='table' and status or {}
    local cap=status.capture or {}
    local finder=status.finder or {}
    imgui.text('1. Haz una accion y recorta el sonido que buscas.')
    seconds=slider('Duracion maxima (s)',seconds,3,30)
    if cap.state~='grabando' and cap.state~='preparando' then
        if imgui.button('Grabar audio de mi proxima accion') then
            selected=nil;length=0
            send('preview_capture_start',{capture_seconds=seconds})
        end
    else
        imgui.text('Captura: '..tostring(cap.state)..' / '..tostring(cap.elapsed or 0)..' s')
        if imgui.button('Termine la accion / detener grabacion') then send('preview_capture_stop') end
    end
    imgui.text('Solo audio del juego en memoria. Puede incluir voces, musica y efectos juntos.')
    if cap.error and cap.error~='' then imgui.text(cap.error) end
    if (cap.duration or 0)>=.08 then
        local size=math.floor(cap.duration*1000)
        if size~=length then length=size;first=0;last=size end
        first=slider('Inicio de la referencia (ms)',first,0,math.max(0,size-80))
        last=slider('Final de la referencia (ms)',last,80,size)
        imgui.text(string.format('Referencia: %.2f a %.2f segundos',first/1000,last/1000))
        local changed,value=imgui.checkbox('Limitar duracion de candidatos',limit_candidates)
        if changed then limit_candidates=value;selected=nil;page=0 end
        if limit_candidates then
            changed,value=imgui.checkbox('Usar duracion de mi referencia',reference_limit)
            if changed then reference_limit=value;selected=nil;page=0 end
            if not reference_limit then candidate_max_ms=slider('Duracion maxima del candidato (ms)',candidate_max_ms,80,30000) end
            imgui.text(string.format('Solo sonidos de %.2f segundos o menos.',candidate_limit()))
        else imgui.text('Incluye sonidos mas largos que contienen parte de la referencia.') end
        if imgui.button('Escuchar mi referencia en audifonos') then send('preview_capture_play',{capture_start=first/1000,capture_end=last/1000,capture_mode='pc'}) end
        if last-first>=80 and not finder.busy and imgui.button('Buscar sonidos originales parecidos') then
            selected=nil;page=0
            send('finder_search',{capture_start=first/1000,capture_end=last/1000,include_other=include_other,max_candidate_seconds=candidate_limit()})
        end
    end
    imgui.text('2. Escucha los candidatos y elige el sonido correcto.')
    if not finder.available then imgui.text('Buscador no disponible: '..tostring(finder.error or 'esperando helper'))
    else
        imgui.text('Buscador: '..tostring(finder.state or 'esperando'))
        imgui.text('Sonidos unicos preparados: '..tostring(finder.indexed or 0))
        if finder.busy then
            imgui.text('Progreso: '..tostring(finder.done or 0)..' / '..tostring(finder.total or 0))
            if finder.current and finder.current~='' then imgui.text(finder.current) end
            if imgui.button('Pausar tarea') then send('finder_pause') end
        elseif (finder.indexed or 0)==0 and imgui.button('Preparar indice de sonidos (una vez)') then send('finder_prepare',{include_other=include_other}) end
        if finder.error and finder.error~='' then imgui.text(finder.error) end
        if finder.message and finder.message~='' then imgui.text(finder.message) end
        volume=slider('Volumen de las pruebas en audifonos (%)',volume,0,100)
        local visible={}
        local maximum=candidate_limit()
        for _,row in ipairs(finder.results or {}) do if not row.rejected and (maximum==0 or row.duration<=maximum+.001) then visible[#visible+1]=row end end
        if selected and maximum>0 and selected.duration>maximum+.001 then selected=nil end
        page=math.min(page,math.max(0,math.ceil(#visible/8)-1))
        if #visible>0 then
            imgui.text('Candidatos: '..#visible..' / pagina '..(page+1)..'. El orden es orientativo.')
            if page>0 and imgui.button('Pagina anterior') then page=page-1 end
            if (page+1)*8<#visible and imgui.button('Mas candidatos') then page=page+1 end
        end
        for i=page*8+1,math.min(#visible,(page+1)*8) do
            local row=visible[i]
            imgui.text(string.format('Candidato %d / %.2f s / %s',i,row.duration,row.correlation>=.65 and 'coincidencia de onda fuerte' or 'sonido parecido'))
            if not finder.busy and imgui.button('Escuchar sonido completo##listen_'..row.key) then send('finder_listen',{key=row.key,gain=volume/100}) end
            if imgui.button('Examinar / recortar este##select_'..row.key) then
                selected=row
                selected_start=row.inside and math.floor(row.offset*1000) or 0
                selected_end=row.inside and math.min(math.floor(row.duration*1000),selected_start+last-first) or math.floor(row.duration*1000)
            end
            if imgui.button('Descartar##reject_'..row.key) then send('finder_reject',{key=row.key});if selected and selected.key==row.key then selected=nil end end
        end
        if selected then
            if imgui.tree_node('Sonido elegido / recorte y destino') then
                imgui.text(selected.name..' / muestra '..selected.media)
                local size=math.max(1,math.floor(selected.duration*1000))
                selected_start=slider('Inicio del sonido elegido (ms)',selected_start,0,size-1)
                selected_end=slider('Final del sonido elegido (ms)',selected_end,1,size)
                local changed,value=imgui.input_text('Nombre de la accion / habilidad',label)
                if changed then label=value:sub(1,100) end
                if selected_end>selected_start and not finder.busy then
                    if imgui.button('Escuchar este recorte') then send('finder_listen',{key=selected.key,start=selected_start/1000,finish=selected_end/1000,gain=volume/100}) end
                    for _,target in ipairs({{'Elegir para haptica','haptics'},{'Elegir para altavoz del mando','speaker'},{'Elegir para ambos','both'}}) do
                        if imgui.button(target[1]) then send('finder_confirm',{key=selected.key,start=selected_start/1000,finish=selected_end/1000,label=label,destination=target[2]}) end
                    end
                    if imgui.tree_node('Este sonido es solo una parte / combinar capas') then
                        layer_delay=slider('Retraso de esta capa (ms)',layer_delay,0,10000)
                        layer_volume=slider('Intensidad de esta capa (%)',layer_volume,0,200)
                        if imgui.button('Agregar recorte a la mezcla') then send('finder_layer',{key=selected.key,start=selected_start/1000,finish=selected_end/1000,offset=layer_delay/1000,gain=layer_volume/100}) end
                        imgui.tree_pop()
                    end
                end
                imgui.text('Elegir guarda la fuente y el recorte para desarrollo. Yo integro despues el efecto al gameplay.')
                imgui.tree_pop()
            end
        end
        local layers=finder.layers or {}
        if #layers>0 then
            imgui.text('Mezcla: '..#layers..' / 6 capas')
            if not finder.busy then
                if imgui.button('Escuchar las capas juntas') then send('finder_mix',{gain=volume/100}) end
                if imgui.button('Elegir mezcla para haptica') then send('finder_confirm',{label=label,destination='haptics'}) end
                if imgui.button('Elegir mezcla para altavoz') then send('finder_confirm',{label=label,destination='speaker'}) end
                if imgui.button('Elegir mezcla para ambos') then send('finder_confirm',{label=label,destination='both'}) end
                if imgui.button('Vaciar mezcla') then send('finder_clear_layers') end
            end
        end
        if imgui.tree_node('Opciones de busqueda / mantenimiento') then
            local changed,value=imgui.checkbox('Incluir voces y musica',include_other)
            if changed then include_other=value end
            imgui.text('La busqueda de efectos incluye personajes, enemigos y sonidos generales.')
            if not finder.busy then
                if imgui.button('Preparar / continuar / actualizar indice') then send('finder_prepare',{include_other=include_other}) end
                if (finder.failed or 0)>0 and imgui.button('Reintentar muestras no compatibles') then send('finder_retry',{include_other=include_other}) end
                if length>0 and last-first>=80 and imgui.button('Buscar mas a fondo con esta referencia') then send('finder_search',{capture_start=first/1000,capture_end=last/1000,include_other=include_other,deep=true,max_candidate_seconds=candidate_limit()}) end
            end
            imgui.text('Muestras no compatibles: '..tostring(finder.failed or 0))
            imgui.text('Paquetes no compatibles: '..tostring(finder.container_errors or 0))
            imgui.text('La primera preparacion tarda. Despues reutiliza un indice numerico; no guarda WAV.')
            imgui.tree_pop()
        end
        if #(finder.choices or {})>0 and imgui.tree_node('Mis sonidos elegidos') then
            for _,choice in ipairs(finder.choices) do
                imgui.text('Seleccion '..choice.id..': '..choice.label..' / '..choice.destination)
                if not finder.busy and imgui.button('Escuchar esta seleccion##saved_'..choice.id) then send('finder_saved',{choice=choice.id,gain=volume/100}) end
            end
            imgui.tree_pop()
        end
    end
    if imgui.button('Detener escucha') then send('finder_silence') end
    if imgui.button('Borrar grabacion de memoria') then send('preview_capture_release');length=0 end
    if status.pc_preview then imgui.text('Escucha: '..tostring(status.pc_preview.output or 'salida del PC'));if status.pc_preview.error~='' then imgui.text(status.pc_preview.error or '') end end
    if A.error~='' then imgui.text(A.error) end
end
