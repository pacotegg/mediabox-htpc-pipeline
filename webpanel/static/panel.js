// ==========================================================================
//  panel.js - toda la logica de interfaz del panel de MediaBox.
// ==========================================================================
//  Estaba INCRUSTADO en templates/index.html hasta el 31/08/2026: 83 KB de
//  JavaScript dentro de un HTML de 145 KB. La plantilla no llevaba ni una
//  etiqueta de Jinja, asi que este codigo nunca dependio del renderizado del
//  servidor y sacarlo fuera no cambia nada.
//
//  SIGUE CARGANDOSE AL FINAL DEL BODY, en el mismo sitio exacto que ocupaba el
//  <script> incrustado: hay codigo aqui que toca el DOM al vuelo y moverlo al
//  <head> lo romperia.
//
//  SE CARGA CON ?v=<mtime>. Sin esa marca el navegador serviria la version
//  vieja despues de cada cambio, y un panel que ignora tus ediciones en
//  silencio es peor que uno que no arranca.
//
//  DOS CONTRATOS QUE NO SE VEN LEYENDO ESTE FICHERO:
//    - openLogModal(titulo, url) hace r.text(), NO r.json(): el endpoint tiene
//      que devolver texto plano.
//    - escJs() para cualquier valor que acabe dentro de un onclick, nunca
//      esc(): esc() no escapa la comilla simple y un apostrofo en el nombre de
//      una pelicula (Ocean's Eleven) deja el boton muerto sin ningun aviso.
// ==========================================================================
// ── Helpers ───────────────────────────────────────────────────────────────────
// esc: para texto que se PINTA, y también para lo que va dentro de un atributo
// entre comillas dobles (title="...", value="..."), que es la mitad de los usos.
// Por eso escapa también la comilla doble: sin ella, un título de pista con un '"'
// -y los metadatos de un MKV son texto libre- cerraba el atributo. En un nodo de
// texto un &quot; se pinta como '"', así que añadirlo no estropea nada.
// Para un valor que acaba dentro de un onclick, esto NO basta: ahí va escJs().
function esc(s){return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;")
  .replace(/>/g,"&gt;").replace(/"/g,"&quot;");}
// escJs: para un valor que va DENTRO de un string JS entre comillas simples que a
// su vez vive en un atributo HTML, o sea onclick="f('AQUI')".
// esc() no basta ahi porque no toca la comilla simple: "Ocean's Twelve" cerraba
// el string y el onclick quedaba con un error de sintaxis -el boton dejaba de
// hacer nada, en silencio-. Pasaba de verdad con los reordenar-cola y con el
// modal de log (habia un log de "...(Michael O'Keefe, Chevy Chase).log").
// Y NO se arregla con &#39;: el navegador decodifica las entidades ANTES de
// parsear el JS, asi que la comilla volveria a aparecer. Hay que escaparla para
// JS (\') y ademas escapar & < > " para no romper el atributo ni el HTML.
// El orden importa: primero la barra invertida, luego la comilla, luego las
// entidades; al reves, las barras que se meten aqui se volverian a escapar.
function escJs(s){return String(s).replace(/\\/g,"\\\\").replace(/'/g,"\\'")
  .replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}
function setStat(id,val){const el=document.getElementById(id);if(!el)return;
  if(val&&val!=="N/A"&&val!=="0.0kbits/s"){el.textContent=val;el.className="stat-value";}
  else{el.textContent="—";el.className="stat-value empty";}}
// Nombre de fichero seguro en Windows y Linux (corta por \ y por /)
function baseName(p){if(!p)return"";return String(p).split(/[\\/]/).pop();}
function stripExt(n){return String(n).replace(/\.[^.]+$/,"");}

// ── Tab switching ─────────────────────────────────────────────────────────────
let currentTab = "enc";
function switchTab(tab){
  document.querySelectorAll(".tab-panel").forEach(p=>p.classList.remove("active"));
  document.querySelectorAll(".tab-btn").forEach(b=>b.classList.remove("active"));
  document.getElementById("panel-"+tab).classList.add("active");
  document.querySelector(".tab-btn.tab-"+tab).classList.add("active");
  currentTab = tab;
  // Refresco inmediato al entrar: los sondeos de fondo van lentos a propósito, y
  // sin esto la pestaña recién abierta enseña datos de hasta 15 s antes.
  if(tab==="sync") syncPoll();
  if(tab==="audio") audioPoll();
  if(tab==="subs") subsPoll();
  if(tab==="remux") rmxPoll();
}

// ── Modals ────────────────────────────────────────────────────────────────────
function closeModal(id){document.getElementById(id).classList.remove("open");}
document.querySelectorAll(".modal-overlay").forEach(el=>{
  el.addEventListener("click",e=>{
    if(e.target===el) el.classList.remove("open");
  });
});

async function openLogModal(title, url){
  document.getElementById("log-modal-title").textContent = title;
  document.getElementById("log-modal-body").textContent = "Loading...";
  document.getElementById("log-modal").classList.add("open");
  try{
    const r = await fetch(url);
    const text = await r.text();
    const body = document.getElementById("log-modal-body");
    body.innerHTML = text.split("\n").map(line=>{
      const l=esc(line);
      if(/error|fail|ERR/i.test(line)) return `<span class="log-err">${l}</span>`;
      if(/✓|done|COMPLETE|100%/i.test(line)) return `<span class="log-ok">${l}</span>`;
      return l;
    }).join("\n");
    body.scrollTop=body.scrollHeight;
  }catch(e){document.getElementById("log-modal-body").textContent="Error: "+e;}
}

// ── File browser ──────────────────────────────────────────────────────────────
let browserTarget = "sync"; // which input to populate
let browserPath   = "C:\\Media";  // arranque por defecto (Windows)

function openBrowser(target){
  browserTarget = target;
  document.getElementById("browser-modal").classList.add("open");
  // path vacio -> el backend usa BASE (C:\Media) por defecto
  browseTo("");
}
async function browseTo(path){
  browserPath = path;
  document.getElementById("browser-path").textContent = path || "C:\\Media";
  document.getElementById("browser-body").innerHTML='<div class="browser-loading">Loading...</div>';
  try{
    const r=await fetch("/api/browse",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({path})});
    const d=await r.json();
    // "::unidades" es la pseudo-carpeta que lista las unidades del equipo (ver
    // DRIVES_ROOT en app.py); se enseña con nombre legible, no con el centinela.
    document.getElementById("browser-path").textContent=
      d.path==="::unidades" ? "Equipo — unidades disponibles" : d.path;
    browserPath=d.path;
    if(!d.entries||!d.entries.length){
      document.getElementById("browser-body").innerHTML='<div class="browser-loading">Empty</div>';return;
    }
    document.getElementById("browser-body").innerHTML=d.entries.map(e=>{
      const icon=e.type==="dir"?"📁":"🎬";
      const cls=e.type==="dir"?"is-dir":"is-file";
      // escJs() y no el escapado a mano de antes, que solo trataba \ y ' y se
      // dejaba & < > ": una carpeta llamada "R&amp;B" o "Tom & Jerry;" se
      // decodificaba como entidad ANTES de que el JS la viera, y el clic llevaba
      // a una ruta que no existe. Es la misma función que ya usa el resto del
      // panel; aquí quedaba la última copia artesanal.
      const click=e.type==="dir"
        ?`browseTo('${escJs(e.path)}')`
        :`browserSelect('${escJs(e.path)}')`;
      return`<div class="browser-entry ${cls}" onclick="${click}">
        <span class="browser-icon">${icon}</span>
        <span class="browser-name">${esc(e.name)}</span>
        <span class="browser-size">${e.size}</span>
      </div>`;
    }).join("");
  }catch(e){
    document.getElementById("browser-body").innerHTML=`<div class="browser-loading" style="color:var(--red)">Error: ${e}</div>`;
  }
}
function browserSelect(path){
  const targets={sync:"sync-file-input",audio:"audio-file-input",subs:"subs-file-input",sanear:"san-file-input"};
  // remux<N>: N ranuras dinamicas, se escribe tambien en el array de estado
  const mr = /^remux(\d+)$/.exec(browserTarget||"");
  if(mr){ const n=+mr[1]; rmxSlots[n]=path; rmxRenderSlots(); closeModal("browser-modal"); return; }
  const inputId=targets[browserTarget];
  if(inputId){
    document.getElementById(inputId).value=path;
  }
  closeModal("browser-modal");
}

// ══════════════════════════════════════════════════════════════════════════════
// ENCODER
// ══════════════════════════════════════════════════════════════════════════════

// Color de la barra por fase. El post-proceso (reconstruir el contenedor y
// escribir etiquetas) NO es el encode, y verlo cambiar de color explica por que
// la barra sigue moviendose cuando ffmpeg ya termino.
const ENC_FASE_COLOR={rebuild:"#4fc3f7",finalizing:"#4fc3f7"};
// Que se esta haciendo en cada fase. Sube aqui -estaba dentro de updateEnc-
// porque ahora la usan la barra de la ranura 1 Y las de las ranuras 2+: dos
// tablas separadas se habrian desincronizado en cuanto se anyadiera una fase.
const ENC_STAGE_TXT={extract:"extrayendo pista",truehdd:"decodificando TrueHD → Atmos",dee:"codificando DD+ JOC",ddp:"codificando DD+",subs:"OCR de subtítulos",analizando:"analizando fuente",verificando:"verificando fuente",
  // Post-proceso. Antes no tenian texto y la barra se movia sin decir de que:
  // son las dos fases que se comian hasta 20 min escondidas en el ultimo 3 %.
  rebuild:"reconstruyendo contenedor",finalizing:"escribiendo etiquetas"};

// El HTML que se pinto la ultima vez en #enc-slots. Sirve para NO reescribir
// innerHTML en cada tick del SSE (una vez por segundo): al recrear los nodos,
// la transicion CSS de .bar-fill se reinicia y la barra de la ranura 2 avanza a
// tirones en vez de deslizarse como la de la 1. En una variable y no en un
// data-* del propio div, que ahi acabaria duplicado dentro del DOM.
let _encSlotsHtml = null;
// Misma trampa que las ranuras (ver comentario arriba) pero con el <select> de
// modo: reescribir enc-queue-list en cada tick del SSE recreaba el nodo y
// CERRABA EL DESPLEGABLE justo cuando el usuario intentaba elegir ICQ/QVBR,
// porque el siguiente % de progreso llegaba antes de que le diera tiempo a
// hacer clic. Solo se toca el DOM si el HTML de verdad cambió.
let _encQueueHtml = null;

// Misma regla que setStat() (arriba) pero devuelta como HTML en vez de
// escrita en un elemento fijo: las ranuras 2+ se reconstruyen enteras como
// cadena en cada tick, no tienen id propio en el DOM.
function statBoxHtml(etiqueta,val){
  const ok=val&&val!=="N/A"&&val!=="0.0kbits/s";
  return '<div class="stat"><div class="stat-label">'+etiqueta+'</div><div class="stat-value'+(ok?'':' empty')+'">'+(ok?esc(val):'—')+'</div></div>';
}

// UNA RANURA 2+, pintada EXACTAMENTE como la de arriba (igualadas el
// 21/09/2026: con $MaxSlots=2 corriendo de verdad, ninguna de las dos es "la
// principal"): su nombre, su barra, su ETA y las mismas 4 cajas de
// FPS/Speed/Bitrate/Encoded. Los campos llegan de enc_job_view (app.py), o
// sea de LA MISMA cuenta que alimenta la barra de la ranura 1.
// esc() en TODO lo que se concatena: esto va a innerHTML y en esta biblioteca
// hay peliculas con & y con apostrofe en el titulo.
function encHtmlRanura(s){
  const pct=parseFloat(s.pct)||0;
  const col=ENC_FASE_COLOR[s.stage]||"";
  const estilo="width:"+pct.toFixed(1)+"%"+(col?";background:"+col:"");
  let der="";
  if(s.eta){der="ETA <span>"+esc(s.eta)+"</span>";}
  else{
    let t=ENC_STAGE_TXT[s.stage]||"";
    if(t&&(s.stage==="rebuild"||s.stage==="finalizing")&&s.pct_fase!=null){
      t+=" "+Math.round(parseFloat(s.pct_fase)||0)+"%";
    }
    if(t){der="<span>"+esc(t)+"</span>";}
  }
  return '<div class="slot-job">'+
           '<div class="slot-head">'+
             '<span class="slot-tag">Ranura '+esc(s.slot)+'</span>'+
             '<span class="slot-name">'+esc(s.file)+'</span>'+
           '</div>'+
           '<div class="progress-row slot-row">'+
           '<div class="pct-label">'+(pct>0?pct.toFixed(1)+'%':'...')+'</div>'+
             '<div class="bar-wrap"><div class="bar-fill bar-green" style="'+estilo+'"></div></div>'+
             '<div class="eta-label">'+der+'</div>'+
           '</div>'+
           '<div class="stats-row">'+
             statBoxHtml('FPS',s.fps)+
             statBoxHtml('Speed',s.speed)+
             statBoxHtml('Bitrate',s.bitrate)+
             statBoxHtml('Encoded',s.out_time?String(s.out_time).split('.')[0]:'')+
           '</div>'+
         '</div>';
}

function updateEnc(d){
  const isEnc=d.status==="encoding", isErr=d.status==="error";
  const dot=document.getElementById("dot-enc");
  dot.className="tab-dot"+(isEnc?" on":"");

  // PAUSA GLOBAL. Se pinta desde aquí porque este payload llega por SSE de forma
  // continua, se mire la pestaña que se mire, y la pausa afecta a los tres
  // pipelines y al remux, no solo al encoder.
  document.getElementById("global-pause").style.display = d.global_paused ? "block" : "none";

  const fn=document.getElementById("enc-filename");
  if(d.file&&isEnc){fn.textContent=d.file;fn.className="big-filename";}
  else if(d.paused){fn.textContent="⏸ Cola en PAUSA — pulsa Reanudar para seguir";fn.className="big-filename idle-text";}
  else{fn.textContent=isErr?"Encode failed":"No active encode";fn.className="big-filename idle-text";}

  // BARRA UNIFICADA (19/08/2026). Antes llegaba al 99,99 % con ffmpeg, RETROCEDIA
  // al 97 % y se quedaba ahi entre 13 y 20 minutos: el reparto lo hace ahora
  // app.py (ENC_BANDAS) con tramos proporcionales a lo que tarda cada fase de
  // verdad, asi que esto solo pinta. El 100 % significa TERMINADO y a por el
  // siguiente fichero.
  const pct=d.pct||0;
  const barEl=document.getElementById("enc-bar");
  barEl.style.width=pct+"%";
  // Color por fase: el post-proceso (reconstruir el contenedor y escribir tags)
  // no es el encode, y verlo cambiar de color explica por que la barra sigue
  // moviendose cuando ffmpeg ya termino.
  const col=ENC_FASE_COLOR[d.stage]||"";
  if(col){ barEl.classList.remove("bar-green"); barEl.style.background=col; }
  else   { barEl.style.background=""; barEl.classList.add("bar-green"); }
  const pctEl=document.getElementById("enc-pct");
  if(isEnc&&pct>0){pctEl.textContent=pct.toFixed(1)+"%";pctEl.className="pct-label";}
  else{pctEl.textContent=isEnc?"...":"—";pctEl.className="pct-label idle";}
  // Fase de AUDIO (DDP+Atmos): el backend manda stage=extract|truehdd|dee y no
  // hay ETA (ffmpeg todavia no ha arrancado, asi que no hay nada que estimar).
  // Se reutiliza el hueco vacio del ETA para decir en que paso va: si no, la
  // barra se mueve durante ~20 min sin explicar de que.
  const STAGE_TXT=ENC_STAGE_TXT;
  // En el post-proceso se enseña ademas el % DENTRO de la fase: la barra global va
  // por el 80 % y esto dice "reconstruyendo contenedor 34%", que es lo que de
  // verdad se quiere saber para estimar cuanto falta.
  let stageTxt=STAGE_TXT[d.stage]||"";
  if(stageTxt&&(d.stage==="rebuild"||d.stage==="finalizing")&&d.pct_fase!=null){
    stageTxt+=" "+Math.round(parseFloat(d.pct_fase)||0)+"%";
  }
  const etaEl=document.getElementById("enc-eta");
  // Audio en PARALELO con el video (encode.ps1 con $ParallelAudioVideo): llega
  // en campos aparte para no pisar la barra del video, y se pinta detras del
  // ETA. Sin esto, el panel no daba ninguna senyal de que el audio -que puede
  // tardar 20 min- estuviera avanzando.
  const audTxt=(d.audio_stage&&isEnc)
    ? ` · audio: <span>${STAGE_TXT[d.audio_stage]||d.audio_stage}${d.audio_pct?" "+Math.round(parseFloat(d.audio_pct)||0)+"%":""}</span>`
    : "";
  if(d.eta){etaEl.innerHTML=`ETA <span>${d.eta}</span>${audTxt}`;}
  else if(isEnc&&stageTxt){etaEl.innerHTML=`<span>${stageTxt}</span>${audTxt}`;}
  else if(audTxt){etaEl.innerHTML=audTxt;}
  else{etaEl.innerHTML="";}
  document.getElementById("enc-prog-card").className="progress-card pc-enc"+(isEnc?" active":"");

  setStat("enc-fps",d.fps);setStat("enc-speed",d.speed);setStat("enc-bitrate",d.bitrate);
  setStat("enc-time",d.out_time?d.out_time.split(".")[0]:"");

  // RANURAS 2+ (04/09/2026). encode.ps1 admite -Slot y el watcher puede correr
  // dos trabajos de video a la vez (1,45x medido, salidas bit a bit identicas).
  // La ranura 1 se queda con la tarjeta grande; cada una de las demas se pinta
  // debajo CON SU PROPIA BARRA (ver encHtmlRanura).
  const extras = d.slots || [];
  const cajaSlots = document.getElementById("enc-slots");
  if (cajaSlots) {
    const html = extras.map(encHtmlRanura).join('');
    if (html !== _encSlotsHtml) { cajaSlots.innerHTML = html; _encSlotsHtml = html; }
  }

  // EL STOP TIENE QUE ESTAR VIVO SI HAY ALGO CORRIENDO, este en la ranura que
  // este. Con '!isEnc' a secas, un trabajo que corriera solo en la ranura 2
  // dejaba el boton deshabilitado y no habia forma de pararlo desde el panel.
  const algoVivo = isEnc || extras.length > 0;
  document.getElementById("enc-btn-stop").disabled=!algoVivo;
  document.getElementById("enc-btn-skip").disabled=!algoVivo;
  document.getElementById("enc-btn-resume").style.display=d.paused?"flex":"none";
  // El checkbox lo pinta el servidor, no el clic: asi dos pestanyas abiertas no
  // se contradicen y sobrevive a recargar.
  const hb=document.getElementById("enc-hold");
  if(hb && hb.checked!==!!d.hold) hb.checked=!!d.hold;


  const qArr=d.queue||[];
  document.getElementById("enc-q-count").textContent=qArr.length;
  const ql=document.getElementById("enc-queue-list");
  const queueHtml=qArr.length
    ?qArr.map((q,i)=>`<div class="list-item">
        <div class="q-actions">
          <button class="q-btn" onclick="encQueueMove('${escJs(q.file)}','up')" ${i===0?'disabled':''}title="Move up">▲</button>
          <button class="q-btn" onclick="encQueueMove('${escJs(q.file)}','down')" ${i===qArr.length-1?'disabled':''}title="Move down">▼</button>
        </div>
        <span class="item-name" title="${esc(q.display)}">${esc(q.display)}</span>
        ${q.audio_tag==="ddp_atmos"
            ?`<span class="item-badge badge-purple" title="TrueHD+Atmos → se convertirá a DDP+Atmos">→ DDP+Atmos</span>`
          :q.audio_tag==="truehd"
            ?`<span class="item-badge badge-amber" title="TrueHD sin Atmos → DD+ 640k (DEE)">TrueHD</span>`
            :""}
        ${q.size?`<span class="item-size">${q.size}</span>`:""}
        <select class="q-modo${q.mode&&q.mode!=="auto"?" q-modo-set":""}"
                title="Cómo se controla el bitrate de ESTA película.&#10;&#10;auto — el perfil de su resolución (hoy QVBR en las dos).&#10;ICQ — manda el GQ: da más bits a lo complejo y menos a lo fácil, pero el tamaño queda LIBRE, sin techo posible.&#10;QVBR — target previsible, pero infla las escenas fáciles hasta llenarlo.&#10;&#10;Los dos sesgos son opuestos: QVBR castiga por duración, ICQ castiga por grano.&#10;Poner Mbps implica QVBR."
                onchange="encSetOpts('${escJs(q.file)}',{mode:this.value},this)">
          <option value="auto"${(!q.mode||q.mode==="auto")?" selected":""}>auto</option>
          <option value="icq"${q.mode==="icq"?" selected":""}>ICQ</option>
          <option value="qvbr"${q.mode==="qvbr"?" selected":""}>QVBR</option>
        </select>
        <input class="q-mbps${q.target_mbps?" q-mbps-set":""}" type="number" step="0.5" min="1" max="30"
               value="${q.target_mbps||""}" placeholder="auto"
               title="Bitrate de vídeo para ESTA película, en Mbps. Vacío = automático.&#10;&#10;En 4K es la única palanca real: el GQ está medido y es inerte (cuatro puntos mueven el 1,3 % del tamaño).&#10;Manda por encima del suelo de calidad y del techo de tamaño, así que es tu criterio el que decide.&#10;Referencia medida sobre material exigente: 10,5 indistinguible · 8,5 casi nada · 5,8 pérdida clara."
               onchange="encSetOpts('${escJs(q.file)}',{target_mbps:this.value},this)">
      </div>`).join("")
    :'<div class="list-item empty-item">Empty</div>';
  if(queueHtml!==_encQueueHtml){ql.innerHTML=queueHtml;_encQueueHtml=queueHtml;}

  document.getElementById("enc-done-count").textContent=(d.done||[]).length;
  const dl=document.getElementById("enc-done-list");
  dl.innerHTML=(d.done||[]).length
    ?d.done.map(item=>{
        // ✓ verde si todo OK; ⚠ ambar si se descartaron subtitulos; · gris si no hay registro
        const dropped=item.subs_dropped||0;
        const resync=item.subs_resync||[];
        let tick;
        if(dropped>0){
          tick=`<span class="tick-warn" title="${dropped} subtitulo(s) descartado(s) en OCR">⚠</span>`;
        } else if(item.logged){
          tick=`<span class="tick-ok">✓</span>`;
        } else {
          tick=`<span class="tick-unk">·</span>`;
        }
        const sizeInfo=item.size?`<span class="item-size">${item.size}</span>`:"";
        const redInfo=item.reduction?`<span class="item-size" style="color:var(--green-dim)">${item.reduction}</span>`:"";
        const dropBadge=dropped>0?`<span class="item-badge badge-amber" title="Faltan ${dropped} subs">-${dropped} sub</span>`:"";
        // Subtitulo nativo corregido antes del mux (verificacion de sync,
        // 25/09/2026): mismo patron que dropBadge, en azul para no confundirlo
        // con un aviso. El titulo lista idioma + lo que hizo falta corregir.
        const resyncTitle=resync.map(r=>`${r.lang}: ${r.informe}`).join(" | ");
        const resyncBadge=resync.length>0?`<span class="item-badge badge-blue" title="${esc(resyncTitle)}">↻${resync.length} sub</span>`:"";
        return`<div class="list-item">${tick}<span class="item-name" title="${esc(item.name)}">${esc(item.name)}</span>${dropBadge}${resyncBadge}${redInfo}${sizeInfo}</div>`;
      }).join("")
    :'<div class="list-item empty-item">—</div>';

  const ep=document.getElementById("enc-error-panel");
  if(isErr){ep.classList.add("visible");document.getElementById("enc-error-body").textContent=d.error||"Unknown error";}
}
async function encKill(){if(!confirm("STOP: mata el encode actual y PAUSA la cola entera (no se coge el siguiente hasta pulsar Reanudar). No se borra ninguna fuente. ¿Continuar?"))return;await fetch("/api/enc/kill",{method:"POST"});}
async function encSkip(){if(!confirm("SKIP: mata el encode actual y el watcher pasa AL SIGUIENTE de la cola. No se borra ninguna fuente (queda en encode_running). ¿Continuar?"))return;await fetch("/api/enc/skip",{method:"POST"});}
async function encResume(){await fetch("/api/enc/resume",{method:"POST"});}
function encDismissError(){document.getElementById("enc-error-panel").classList.remove("visible");}

async function encLoadLogs(){
  try{
    const r=await fetch("/api/enc/logs");
    const logs=await r.json();
    const el=document.getElementById("enc-log-list");
    document.getElementById("enc-log-count").textContent=logs.length;
    if(!logs.length){el.innerHTML='<div class="list-item empty-item">No logs yet</div>';return;}
    el.innerHTML=logs.map(l=>{
      const d=new Date(l.mtime*1000);
      const t=d.toLocaleDateString("es-ES",{day:"2-digit",month:"2-digit"})+" "+d.toLocaleTimeString("es-ES",{hour:"2-digit",minute:"2-digit"});
      const icon=l.name.includes("checkfix")?"🔍":"🎬";
      return`<div class="log-entry" onclick="openLogModal('${escJs(l.name)}','/api/enc/log/${encodeURIComponent(l.name)}')">
        <span>${icon}</span><span class="log-entry-name">${esc(l.name)}</span>
        <span class="log-entry-time">${t}</span></div>`;
    }).join("");
  }catch{}
}
encLoadLogs();
setInterval(()=>{ if(currentTab==="enc") encLoadLogs(); },10000);


// ══════════════════════════════════════════════════════════════════════════════
// SYNC
// ══════════════════════════════════════════════════════════════════════════════
let syncActiveId = null;

// Slider ↔ fine-tune input sync
function syncSliderSetup(sliderId, valId, fineId){
  const slider=document.getElementById(sliderId);
  const valEl=document.getElementById(valId);
  const fine=document.getElementById(fineId);
  const fmt=v=>parseFloat(v).toFixed(2)+"s";
  slider.addEventListener("input",()=>{fine.value=parseFloat(slider.value).toFixed(2);valEl.textContent=fmt(slider.value);});
  fine.addEventListener("input",()=>{
    let v=parseFloat(fine.value)||0;
    v=Math.max(-10,Math.min(10,v));
    slider.value=Math.max(-5,Math.min(5,v));
    valEl.textContent=fmt(v);
  });
}
syncSliderSetup("sync-audio-slider","sync-audio-val","sync-audio-fine");
syncSliderSetup("sync-sub-slider","sync-sub-val","sync-sub-fine");

async function syncProbe(){
  const fp=document.getElementById("sync-file-input").value.trim();
  if(!fp){alert("Enter a file path first.");return;}
  const btn=document.getElementById("sync-probe-btn");
  btn.disabled=true;btn.textContent="Probing...";
  try{
    const r=await fetch("/api/sync/probe",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({filepath:fp})});
    const d=await r.json();
    if(!d.ok){alert("Error: "+(d.error||"Could not probe file"));return;}
    buildSyncStreamSelects(d.streams, fp);
    document.getElementById("sync-streams-area").style.display="flex";
  }catch(e){alert("Probe failed: "+e);}
  finally{btn.disabled=false;btn.textContent="⟳ Probe";}
}

// esc(label) Y NO ${label} A SECAS (01/09/2026): el label incluye s.title,
// que es el TITULO DE PISTA del MKV, o sea texto libre de quien hizo el
// fichero. Sin escapar, un titulo con "&" o "<" rompe el <option>. Es la
// misma clase de fallo que el apostrofo en los onclick, y el propio esc()
// documenta arriba que "los metadatos de un MKV son texto libre".
function buildSyncStreamSelects(streams, fp){
  const audioSel=document.getElementById("sync-audio-sel");
  const subSel=document.getElementById("sync-sub-sel");
  const audioStreams=streams.filter(s=>s.codec_type==="audio");
  const subStreams=streams.filter(s=>s.codec_type==="subtitle");

  audioSel.innerHTML=audioStreams.map(s=>{
    const label=[s.codec_name.toUpperCase(), s.language, s.title].filter(Boolean).join(" · ");
    return`<option value="${s.index}">${esc(label)} [stream ${s.index}]</option>`;
  }).join("") || '<option value="">— No audio streams —</option>';

  subSel.innerHTML=subStreams.map(s=>{
    const label=[s.codec_name.toUpperCase(), s.language, s.title].filter(Boolean).join(" · ");
    return`<option value="${s.index}">${esc(label)} [stream ${s.index}]</option>`;
  }).join("") || '<option value="">— No subtitle streams —</option>';

  // Etiquetas: "Tracks to adjust" en plural, y pista de como marcar varias.
  // El caso tipico es un ripeo alternativo que trae audio + varios subs, todos
  // con el mismo desfase: antes habia que pasar el fichero una vez por pista.
  document.querySelectorAll("#sync-audio-row .field-label, #sync-sub-row .field-label")
    .forEach(el=>{ el.textContent="Tracks to adjust (Ctrl/Shift para varias)"; });

  document.getElementById("sync-audio-row").style.opacity=audioStreams.length?"1":"0.4";
  document.getElementById("sync-sub-row").style.opacity=subStreams.length?"1":"0.4";
  document.getElementById("sync-audio-enabled").checked=audioStreams.length>0;
  document.getElementById("sync-sub-enabled").checked=false;
  // Por defecto, la primera pista de audio marcada (comportamiento de siempre).
  if(audioStreams.length) audioSel.options[0].selected=true;

  // Nombre Windows-safe + ruta de salida real (encoded/)
  const noext=stripExt(baseName(fp));
  document.getElementById("sync-output-hint").textContent=`Output → encoded\\${noext}.synced.mkv`;
}

async function syncAdd(){
  const fp=document.getElementById("sync-file-input").value.trim();
  if(!fp){alert("No file selected.");return;}
  const audioEnabled=document.getElementById("sync-audio-enabled").checked;
  const subEnabled=document.getElementById("sync-sub-enabled").checked;
  // Selectores multiples: se recogen TODAS las opciones marcadas. Todas las
  // pistas de un grupo comparten el desfase de ese grupo.
  const selValues=id=>Array.from(document.getElementById(id).selectedOptions)
                            .map(o=>parseInt(o.value)).filter(v=>!isNaN(v));
  const audioStreams=audioEnabled?selValues("sync-audio-sel"):[];
  const audioOffset=parseFloat(document.getElementById("sync-audio-fine").value)||0;
  const subStreams=subEnabled?selValues("sync-sub-sel"):[];
  const subOffset=parseFloat(document.getElementById("sync-sub-fine").value)||0;

  const btn=document.getElementById("sync-add-btn");
  btn.disabled=true;btn.textContent="Adding...";
  try{
    const r=await fetch("/api/sync/add",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({filepath:fp,audio_streams:audioStreams,audio_offset:audioOffset,
        sub_streams:subStreams,sub_offset:subOffset})});
    const d=await r.json();
    if(d.ok){
      document.getElementById("sync-file-input").value="";
      document.getElementById("sync-streams-area").style.display="none";
      syncPoll();
    } else { alert("Error: "+(d.error||"Unknown")); }
  }catch(e){alert("Error: "+e);}
  finally{btn.disabled=false;btn.textContent="▲ Queue Encode";}
}

async function syncCancel(){
  if(!syncActiveId)return;
  await fetch(`/api/sync/cancel/${syncActiveId}`,{method:"POST"});
}

async function syncPoll(){
  try{
    const r=await fetch("/api/sync/status");
    const d=await r.json();
    updateSync(d);
  }catch{}
}
// Tab-aware: poll fast when visible, slow when in background
let _syncTick=0;
setInterval(()=>{ _syncTick++; if(currentTab==="sync"||_syncTick%5===0) syncPoll(); },1000);

function updateSync(d){
  const active=d.active;
  const dot=document.getElementById("dot-sync");
  dot.className="tab-dot"+(active?" on":"");

  const card=document.getElementById("sync-prog-card");
  const fn=document.getElementById("sync-filename");

  if(active){
    syncActiveId=active.id;
    card.className="progress-card pc-sync active";
    fn.textContent=active.file;fn.className="big-filename";
    const logCard=document.getElementById("sync-log-card");
    const logBody=document.getElementById("sync-log-body");
    const lines=active.log||[];
    document.getElementById("sync-log-count").textContent=lines.length+" lines";
    if(lines.length){
      logCard.style.display="block";
      logBody.innerHTML=lines.map(l=>{
        const cls=/error|fail/i.test(l)?"log-line err":"log-line";
        return`<div class="${cls}">${esc(l)}</div>`;
      }).join("");
      logBody.scrollTop=logBody.scrollHeight;
    }
    document.getElementById("sync-btn-cancel").disabled=false;
  } else {
    syncActiveId=null;
    card.className="progress-card pc-sync";
    fn.textContent="No active sync job";fn.className="big-filename idle-text";
    document.getElementById("sync-log-card").style.display="none";
    document.getElementById("sync-btn-cancel").disabled=true;
  }

  const jobs=d.jobs||[];
  // 'waiting' cuenta como pendiente. Es un estado NUEVO (20/08/2026): desde que
  // el worker de Sync pide el pipeline.lock antes de tocar nada, un trabajo pasa
  // por aquí siempre que haya un encode en marcha. Sin esta línea no salía en
  // ninguna de las dos listas y el trabajo parecía haberse evaporado.
  const pending=jobs.filter(j=>j.status==="pending"||j.status==="waiting");
  const done=jobs.filter(j=>j.status==="done"||j.status==="error");

  document.getElementById("sync-q-count").textContent=pending.length;
  const ql=document.getElementById("sync-queue-list");
  ql.innerHTML=pending.length
    ?pending.map(j=>{
        const esp=j.status==="waiting";
        return `<div class="sync-job-item">
        <span class="item-name">${esc(j.file)}</span>
        <span class="item-badge ${esp?"badge-amber":"badge-pending"}"
              title="${esp?"Hay otro trabajo del pipeline en marcha (o una pausa global). Este espera turno; no se pierde.":""}"
              >${esp?"esperando turno":"pending"}</span>
        <button class="item-cancel" onclick="fetch('/api/sync/cancel/${j.id}',{method:'POST'})">✕</button>
      </div>`;}).join("")
    :'<div class="list-item empty-item">Empty</div>';

  document.getElementById("sync-done-count").textContent=done.length;
  const dl=document.getElementById("sync-done-list");
  dl.innerHTML=done.length
    ?done.map(j=>{
        const ok=j.status==="done";
        return`<div class="sync-job-item">
          <span class="${ok?"tick-ok":"tick-err"}">${ok?"✓":"✗"}</span>
          <span class="item-name" title="${esc(j.output)}">${esc(j.file)}</span>
          ${!ok?`<span class="item-badge badge-error" title="${esc(j.error)}">error</span>`:""}
        </div>`;
      }).join("")
    :'<div class="list-item empty-item">—</div>';
}


// ══════════════════════════════════════════════════════════════════════════════
// AUDIO  (TrueHD -> DDP+Atmos / EAC3)
// ══════════════════════════════════════════════════════════════════════════════
// (Aquí había además un 'audioStreams' global que no leía nadie: resto de cuando
//  esta pestaña enseñaba la lista de pistas. Peor que inútil, porque otras dos
//  funciones declaran una variable local con ese mismo nombre.)
let audioActiveId=null;

// Copias en curso hacia una cola. Se pintan ARRIBA DEL TODO de la lista de
// pendientes: un MKV de 40 GB tarda varios minutos en copiarse y, hasta que
// termina, no existe en la carpeta que vigila el watcher. Sin esto el usuario
// pulsaba "Añadir" y no pasaba nada visible durante minutos.
function copyRows(copias){
  return (copias||[]).map(c=>{
    const err = c.estado==="error";
    const fin = c.estado==="listo";
    const col = err?"badge-error":(fin?"badge-pending":"badge-blue");
    const txt = err?"error al copiar":(fin?"copiado":`copiando ${c.pct.toFixed(0)}%`);
    // El botón "a cola de vídeo" vive en esta pestaña pero copia a OTRA cola: hay
    // que decirlo o parece que el fichero se ha quedado aquí.
    const dst = {encoder:" → cola de vídeo",audio:"",subs:""}[c.dest]||"";
    return `<div class="sync-job-item">
      <span class="item-name" title="${esc(c.error||"")}">${esc(c.name)}${dst}</span>
      <span class="item-badge ${col}">${txt}</span>
    </div>`;
  }).join("");
}

async function audioAdd(){
  const fp=document.getElementById("audio-file-input").value.trim();
  if(!fp){alert("Introduce una ruta o usa Browse.");return;}
  const btn=document.getElementById("audio-add-btn");
  btn.disabled=true;btn.textContent="Añadiendo...";
  try{
    const r=await fetch("/api/audio/add",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({filepath:fp})});
    const d=await r.json();
    if(d.ok){ document.getElementById("audio-file-input").value=""; audioPoll(); }
    else { alert("Error: "+(d.error||"Desconocido")); }
  }catch(e){alert("Error: "+e);}
  finally{btn.disabled=false;btn.textContent="▲ Añadir a la cola";}
}

async function audioToEncoder(){
  const fp=document.getElementById("audio-file-input").value.trim();
  if(!fp){alert("Introduce una ruta o usa Browse.");return;}
  const btn=document.getElementById("audio-to-enc-btn");
  btn.disabled=true;btn.textContent="Enviando...";
  try{
    const r=await fetch("/api/audio/to_encoder",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({filepath:fp})});
    const d=await r.json();
    if(d.ok){ document.getElementById("audio-file-input").value=""; audioPoll();
              alert("Copiando a la cola del Encoder de vídeo: "+d.queued+" ("+(d.size||"")+")."
                   +"\nEl avance se ve aquí abajo; el watcher lo recogerá al terminar la copia."); }
    else { alert("Error: "+(d.error||"Desconocido")); }
  }catch(e){alert("Error: "+e);}
  finally{btn.disabled=false;btn.textContent="⚙ A cola de vídeo";}
}

async function audioCancel(){ if(!audioActiveId)return; await fetch(`/api/audio/cancel/${audioActiveId}`,{method:"POST"}); }
// El id de un trabajo PENDIENTE de esta cola es el NOMBRE DEL FICHERO, no un
// uuid. Por eso hace falta lo mismo que ya hace la pestaña Subs y aquí faltaba:
//   · escJs() al meterlo en el onclick — un apóstrofo ("Ocean's Eleven") cerraba
//     el string y dejaba el botón muerto, sin ningún aviso;
//   · encodeURIComponent() al meterlo en la URL — un # o un ? en el nombre
//     cortaban la ruta y el borrado se iba a otra parte.
// El backend ya hace basename() sobre lo que llegue, así que la ruta es segura.
async function audioCancelJob(id){
  await fetch("/api/audio/cancel/"+encodeURIComponent(id),{method:"POST"});
  audioPoll();
}

async function audioPoll(){
  try{ const r=await fetch("/api/audio/status"); const d=await r.json(); updateAudio(d); }catch{}
}
let _audioTick=0;
setInterval(()=>{ _audioTick++; if(currentTab==="audio"||_audioTick%5===0) audioPoll(); },1000);

function updateAudio(d){
  const active=d.active;
  const dot=document.getElementById("dot-audio");
  dot.className="tab-dot"+(active?" on":"");
  const card=document.getElementById("audio-prog-card");
  const fn=document.getElementById("audio-filename");

  if(active){
    audioActiveId=active.id;
    card.className="progress-card pc-ups active";
    fn.textContent=active.file;fn.className="big-filename";
    // Modo + fase juntos en la etiqueta que ya existe (audio-mode-label). La
    // fase evita que parezca colgado durante los ~10 min de truehdd, donde
    // truehdd no da un % util y la barra se queda en 0 aunque este trabajando.
    // stage llega como 'extract'|'truehdd'|'dee' + ' a:N' -> se corta el espacio.
    const modeTxt=active.mode==="auto"?"DDP+Atmos":"EAC3";
    const rawStage=(active.stage||"").split(" ")[0];
    const stageTxt={extract:"extrayendo pista",truehdd:"decodificando TrueHD → Atmos",dee:"codificando DD+ JOC",ddp:"codificando DD+",subs:"OCR de subtítulos",analizando:"analizando fuente",verificando:"verificando fuente"}[rawStage]||"";
    document.getElementById("audio-mode-label").innerHTML=
      `<span>${modeTxt}${stageTxt?" · "+stageTxt:""}</span>`;
    const pct=active.pct||0;
    document.getElementById("audio-bar").style.width=pct+"%";
    const pctEl=document.getElementById("audio-pct");
    if(pct>0){pctEl.textContent=pct.toFixed(1)+"%";pctEl.className="pct-label";}
    else{pctEl.textContent="...";pctEl.className="pct-label idle";}
    const lines=active.log||[];
    const lc=document.getElementById("audio-log-card");
    if(lines.length){
      lc.style.display="block";
      document.getElementById("audio-log-count").textContent=lines.length+" líneas";
      const lb=document.getElementById("audio-log-body");
      lb.innerHTML=lines.map(l=>`<div class="log-line${/error|fail|fallo/i.test(l)?" err":""}">${esc(l)}</div>`).join("");
      lb.scrollTop=lb.scrollHeight;
    } else { lc.style.display="none"; }
    document.getElementById("audio-btn-cancel").disabled=false;
  } else {
    audioActiveId=null;
    card.className="progress-card pc-ups";
    fn.textContent="Sin conversión activa";fn.className="big-filename idle-text";
    document.getElementById("audio-mode-label").innerHTML="";
    const pctEl=document.getElementById("audio-pct");
    pctEl.textContent="—";pctEl.className="pct-label idle";
    document.getElementById("audio-bar").style.width="0%";
    document.getElementById("audio-log-card").style.display="none";
    document.getElementById("audio-btn-cancel").disabled=true;
  }

  const jobs=d.jobs||[];
  const pending=jobs.filter(j=>j.status==="pending");
  const done=jobs.filter(j=>j.status==="done"||j.status==="error");

  const copias=d.copying||[];
  document.getElementById("audio-q-count").textContent=pending.length+copias.length;
  const ql=document.getElementById("audio-queue-list");
  ql.innerHTML=(copyRows(copias) + (pending.length
    ?pending.map(j=>`<div class="sync-job-item">
        <span class="item-name">${esc(j.file)}</span>
        <span class="item-badge ${j.mode==="auto"?"badge-purple":"badge-amber"}">${j.mode==="auto"?"DDP+Atmos":"EAC3"}</span>
        <button class="item-cancel" onclick="audioCancelJob('${escJs(j.id)}')">✕</button>
      </div>`).join("")
    :(copias.length?"":'<div class="list-item empty-item">Vacía</div>')));

  document.getElementById("audio-done-count").textContent=done.length;
  const dl=document.getElementById("audio-done-list");
  dl.innerHTML=done.length
    ?done.map(j=>{
        const ok=j.status==="done";
        return`<div class="sync-job-item">
          <span class="${ok?"tick-ok":"tick-err"}">${ok?"✓":"✗"}</span>
          <span class="item-name" title="${esc(j.output)}">${esc(j.file)}</span>
          ${!ok?`<span class="item-badge badge-error" title="${esc(j.error)}">error</span>`:""}
        </div>`;
      }).join("")
    :'<div class="list-item empty-item">—</div>';
}


// ══════════════════════════════════════════════════════════════════════════════
// SUBS  (encode.ps1 -SubsOnly: OCR de subtítulos, vídeo y audio en copy)
// ══════════════════════════════════════════════════════════════════════════════
let subsActiveId=null;

async function subsAdd(){
  const fp=document.getElementById("subs-file-input").value.trim();
  if(!fp){alert("Introduce una ruta o usa Browse.");return;}
  const btn=document.getElementById("subs-add-btn");
  btn.disabled=true;btn.textContent="Añadiendo...";
  try{
    const r=await fetch("/api/subs/add",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({filepath:fp})});
    const d=await r.json();
    if(d.ok){ document.getElementById("subs-file-input").value=""; subsPoll(); }
    else { alert("Error: "+(d.error||"Desconocido")); }
  }catch(e){alert("Error: "+e);}
  finally{btn.disabled=false;btn.textContent="▲ Añadir a la cola";}
}

// BUSCAR SUBTITULOS A PETICION. Es el MISMO subsfetch.py que dispara solo
// encode.ps1 cuando una pelicula no trae subtitulos de texto; aqui se le pide a
// mano para un fichero concreto. Coge el pipeline.lock, asi que si hay un encode
// en marcha se queda esperando y lo dice.
async function subsFetch(){
  const fp=document.getElementById("subs-file-input").value.trim();
  if(!fp){alert("Introduce una ruta o usa Browse.");return;}
  const btn=document.getElementById("subs-fetch-btn");
  btn.disabled=true;btn.textContent="Buscando...";
  try{
    const r=await fetch("/api/subs/fetch",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({filepath:fp,idiomas:"es,en",forzados:true})});
    const d=await r.json();
    if(d.ok){ document.getElementById("subs-file-input").value=""; subsFetchPoll(); }
    else { alert("Error: "+(d.error||"Desconocido")); }
  }catch(e){alert("Error: "+e);}
  finally{btn.disabled=false;btn.textContent="🔍 Buscar subtítulos";}
}

const FETCH_TXT={pending:"en cola",waiting:"esperando al pipeline",running:"buscando",
                 done:"listo",warn:"parcial",empty:"sin resultados",error:"error"};
// 'empty' va en gris, NO en rojo: no encontrar subtitulos para una película es
// una respuesta legítima, no una avería. Pintarlo de rojo manda a buscar un
// problema que no existe.
const FETCH_COL={done:"var(--green)",warn:"var(--amber)",error:"var(--red)",
                 empty:"var(--muted)",running:"var(--amber)",
                 waiting:"var(--muted)",pending:"var(--muted)"};
async function subsFetchPoll(){
  try{
    const r=await fetch("/api/subs/fetch/status"); const d=await r.json();
    const jobs=d.jobs||[];
    document.getElementById("subs-fetch-card").style.display = jobs.length?"":"none";
    document.getElementById("subs-fetch-list").innerHTML = jobs.map(j=>{
      const col=FETCH_COL[j.status]||"var(--muted)";
      const est=FETCH_TXT[j.status]||j.status;
      const err=j.error?` — <span style="color:var(--amber)">${esc(j.error)}</span>`:"";
      return `<div class="list-item">
        <div style="flex:1;min-width:0">
          <div style="font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(j.name)}</div>
          <div style="font-size:11px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(j.last_log||"")}</div>
        </div>
        <span class="item-badge" style="border-color:${col};color:${col}">${est}${err}</span>
        <button class="btn" style="padding:2px 8px;font-size:11px"
          onclick="openLogModal('${escJs(j.name)}','/api/subs/fetch/log/${j.id}')">log</button>
      </div>`;
    }).join("");
  }catch{}
}

async function subsCancel(){ if(!subsActiveId)return; await fetch(`/api/subs/cancel/${subsActiveId}`,{method:"POST"}); }

async function subsPoll(){
  subsFetchPoll();
  try{ const r=await fetch("/api/subs/status"); const d=await r.json(); updateSubs(d); }catch{}
}
let _subsTick=0;
setInterval(()=>{ _subsTick++; if(currentTab==="subs"||_subsTick%5===0) subsPoll(); },1000);

function updateSubs(d){
  const active=d.active;
  const dot=document.getElementById("dot-subs");
  dot.className="tab-dot"+(active?" on":"");
  const card=document.getElementById("subs-prog-card");
  const fn=document.getElementById("subs-filename");

  if(active){
    subsActiveId=active.id;
    card.className="progress-card pc-subs active";
    fn.textContent=active.file;fn.className="big-filename";
    // Tras la copia de ffmpeg viene el post-proceso (reconstruir contenedor +
    // recalcular tags), que en un 4K tarda bastante mas que la copia. El backend
    // manda stage=rebuild|finalizing para que no parezca colgado.
    const subStageTxt={rebuild:"reconstruyendo contenedor",finalizing:"finalizando (tags/HDR)"}[active.stage]||"";
    document.getElementById("subs-mode-label").innerHTML=`<span>solo subtítulos${subStageTxt?" · "+subStageTxt:""}</span>`;
    const pct=active.pct||0;
    document.getElementById("subs-bar").style.width=pct+"%";
    const pctEl=document.getElementById("subs-pct");
    if(pct>0){pctEl.textContent=pct.toFixed(1)+"%";pctEl.className="pct-label";}
    else{pctEl.textContent="...";pctEl.className="pct-label idle";}
    const lines=active.log||[];
    const lc=document.getElementById("subs-log-card");
    if(lines.length){
      lc.style.display="block";
      document.getElementById("subs-log-count").textContent=lines.length+" líneas";
      const lb=document.getElementById("subs-log-body");
      lb.innerHTML=lines.map(l=>`<div class="log-line${/error|fail|fallo/i.test(l)?" err":""}">${esc(l)}</div>`).join("");
      lb.scrollTop=lb.scrollHeight;
    } else { lc.style.display="none"; }
    document.getElementById("subs-btn-cancel").disabled=false;
  } else {
    subsActiveId=null;
    card.className="progress-card pc-subs";
    fn.textContent="Sin trabajo activo";fn.className="big-filename idle-text";
    document.getElementById("subs-mode-label").innerHTML="";
    const pctEl=document.getElementById("subs-pct");
    pctEl.textContent="—";pctEl.className="pct-label idle";
    document.getElementById("subs-bar").style.width="0%";
    document.getElementById("subs-log-card").style.display="none";
    document.getElementById("subs-btn-cancel").disabled=true;
  }

  const jobs=d.jobs||[];
  const pending=jobs.filter(j=>j.status==="pending");
  const done=jobs.filter(j=>j.status==="done"||j.status==="error");

  const copias=d.copying||[];
  document.getElementById("subs-q-count").textContent=pending.length+copias.length;
  const ql=document.getElementById("subs-queue-list");
  ql.innerHTML=(copyRows(copias) + (pending.length
    ?pending.map(j=>`<div class="sync-job-item">
        <span class="item-name">${esc(j.file)}</span>
        <span class="item-badge badge-amber">subs</span>
        <button class="item-cancel" onclick="fetch('/api/subs/cancel/'+encodeURIComponent('${escJs(j.id)}'),{method:'POST'})">✕</button>
      </div>`).join("")
    :(copias.length?"":'<div class="list-item empty-item">Vacía</div>')));

  document.getElementById("subs-done-count").textContent=done.length;
  const dl=document.getElementById("subs-done-list");
  dl.innerHTML=done.length
    ?done.map(j=>{
        const ok=j.status==="done";
        return`<div class="sync-job-item">
          <span class="${ok?"tick-ok":"tick-err"}">${ok?"✓":"✗"}</span>
          <span class="item-name" title="${esc(j.output||"")}">${esc(j.file)}</span>
        </div>`;
      }).join("")
    :'<div class="list-item empty-item">—</div>';
}


// ══════════════════════════════════════════════════════════════════════════════
// YT-DLP
// ══════════════════════════════════════════════════════════════════════════════
let ytActiveId=null, ytFetchTimer=null;

document.getElementById("yt-url").addEventListener("input",()=>{
  clearTimeout(ytFetchTimer);
  const url=document.getElementById("yt-url").value.trim();
  const prev=document.getElementById("yt-title-preview");
  if(!url||!url.startsWith("http")){prev.textContent="Paste a URL to fetch title...";prev.className="title-preview";return;}
  prev.textContent="Fetching title...";prev.className="title-preview loading";
  ytFetchTimer=setTimeout(async()=>{
    try{
      const r=await fetch("/api/ytdlp/fetch_title",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({url})});
      const d=await r.json();
      if(d.ok&&d.title){prev.textContent="→ "+d.title;prev.className="title-preview loaded";}
      else{prev.textContent="Could not fetch title — URL may still be valid";prev.className="title-preview";}
    }catch{prev.textContent="Error";prev.className="title-preview";}
  },800);
});
document.getElementById("yt-url").addEventListener("keydown",e=>{if(e.key==="Enter")ytAdd();});

async function ytAdd(){
  const url=document.getElementById("yt-url").value.trim();
  const quality=document.getElementById("yt-quality").value;
  const prev=document.getElementById("yt-title-preview");
  const title=prev.className.includes("loaded")?prev.textContent.replace(/^→ /,""):"";
  if(!url)return;
  const btn=document.getElementById("yt-btn-add");
  btn.disabled=true;btn.textContent="Adding...";
  try{
    const r=await fetch("/api/ytdlp/add",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({url,quality,title})});
    const d=await r.json();
    if(d.ok){document.getElementById("yt-url").value="";prev.textContent="Paste a URL to fetch title...";prev.className="title-preview";}
    else{alert("Error: "+(d.error||"Unknown"));}
  }catch(e){alert("Error: "+e);}
  btn.disabled=false;btn.textContent="↓ Download";
}
async function ytCancel(){if(!ytActiveId)return;if(!confirm("Cancel?"))return;await fetch(`/api/ytdlp/cancel/${ytActiveId}`,{method:"POST"});}
async function ytCancelJob(id){await fetch(`/api/ytdlp/cancel/${id}`,{method:"POST"});}
async function ytClearHistory(){await fetch("/api/ytdlp/clear_history",{method:"POST"});}

function updateYtdlp(d){
  const active=d.active;
  const isMerging=active&&active.merging;
  const isDl=active&&!active.merging;
  const dot=document.getElementById("dot-ytdlp");
  dot.className="tab-dot"+(active?" on":"");

  const card=document.getElementById("yt-prog-card");
  const titleEl=document.getElementById("yt-title");
  if(active){
    ytActiveId=active.id;card.className="progress-card pc-ytdlp active";
    titleEl.textContent=active.title||active.url;titleEl.className="big-filename";
    document.getElementById("yt-url-display").textContent=active.url;
  } else {
    ytActiveId=null;card.className="progress-card pc-ytdlp";
    titleEl.textContent="No active download";titleEl.className="big-filename idle-text";
    document.getElementById("yt-url-display").textContent="";
  }
  const pct=active?(active.pct||0):0;
  document.getElementById("yt-bar").style.width=pct+"%";
  const pctEl=document.getElementById("yt-pct");
  if(isMerging){pctEl.textContent="MERGING";pctEl.className="pct-label";pctEl.style.fontSize="17px";}
  else if(isDl){pctEl.textContent=pct.toFixed(1)+"%";pctEl.className="pct-label";pctEl.style.fontSize="";}
  else{pctEl.textContent="—";pctEl.className="pct-label idle";pctEl.style.fontSize="";}
  document.getElementById("yt-eta").innerHTML=active&&active.eta?`ETA <span>${active.eta}</span>`:"";

  setStat("yt-speed",active?active.speed:"");setStat("yt-size",active?active.size:"");
  setStat("yt-quality-stat",active?active.quality:"");
  setStat("yt-status-stat",active?(isMerging?"Merging…":"Downloading"):"");

  // Live log
  const logBox=document.getElementById("yt-live-log");
  const logBody=document.getElementById("yt-log-body");
  if(active&&(active.log||[]).length){
    logBox.style.display="block";
    const lines=(active.log||[]).slice(-20);
    document.getElementById("yt-log-lines").textContent=(active.log||[]).length+" lines";
    logBody.innerHTML=lines.map(l=>`<div class="log-line${/error|fail/i.test(l)?" err":""}">${esc(l)}</div>`).join("");
    logBody.scrollTop=logBody.scrollHeight;
  } else {logBox.style.display="none";}

  document.getElementById("yt-btn-cancel").disabled=!active;

  // Queue
  const pending=(d.queue||[]).filter(j=>j.status==="pending");
  document.getElementById("yt-q-count").textContent=pending.length;
  const ql=document.getElementById("yt-queue-list");
  ql.innerHTML=pending.length
    ?pending.map(j=>`<div class="list-item">
        <span class="item-name" title="${esc(j.url)}">${esc(j.title||j.url)}</span>
        <span class="item-badge badge-blue">${esc(j.quality)}</span>
        <button class="item-cancel" onclick="ytCancelJob('${j.id}')">✕</button>
      </div>`).join("")
    :'<div class="list-item empty-item">Empty</div>';

  // Finished
  const finished=(d.queue||[]).filter(j=>j.status==="done"||j.status==="error");
  document.getElementById("yt-fin-count").textContent=finished.length;
  const fl=document.getElementById("yt-fin-list");
  fl.innerHTML=finished.length
    ?finished.map(j=>{
        const ok=j.status==="done";
        return`<div class="log-entry">
          <span class="${ok?"tick-ok":"tick-err"}">${ok?"✓":"✗"}</span>
          <span class="log-entry-name" style="color:${ok?"var(--text)":"var(--red)"}">${esc(j.title||j.url)}</span>
          <button class="item-cancel" onclick="openLogModal('${escJs(j.title||j.id)}','/api/ytdlp/log/${j.id}')" title="View log">📋</button>
        </div>`;
      }).join("")
    :'<div class="list-item empty-item">No finished jobs</div>';

  // History
  const hItems=d.history||[];
  document.getElementById("yt-h-count").textContent=hItems.length;
  const hl=document.getElementById("yt-hist-list");
  hl.innerHTML=hItems.length
    ?hItems.map(h=>{
        const ok=h.status==="done";
        const logBtn=h.log_file
          ?`<button class="item-cancel" onclick="openLogModal('${escJs(h.title||h.id)}','/api/ytdlp/log/${h.id}')" title="Log">📋</button>`:"";
        return`<div class="list-item">
          <span class="${ok?"tick-ok":"tick-err"}">${ok?"✓":"✗"}</span>
          <span class="item-name" title="${esc(h.url)}">${esc(h.title||h.url)}</span>
          <span class="item-badge badge-blue">${esc(h.quality)}</span>
          ${!ok?'<span class="item-badge badge-error">failed</span>':""}
          ${logBtn}
        </div>`;
      }).join("")
    :'<div class="list-item empty-item">—</div>';
}


// ══════════════════════════════════════════════════════════════════════════════
// UNIFIED SSE
// ══════════════════════════════════════════════════════════════════════════════
// Ajustes por pelicula (modo y/o bitrate). Escriben el sidecar '<fichero>.opts'
// que lee encode-watch.ps1 y traduce a -RateMode / -TargetMbps.
// Se manda SOLO lo que cambia: el backend conserva lo otro, asi que tocar el
// desplegable no borra los Mbps que ya habias puesto.
// NO se refresca la lista a mano: el SSE la repinta en <=1 s con lo que haya
// quedado en disco, asi que lo que se ve es siempre lo que se va a aplicar.
async function encSetOpts(file, campos, el){
  el.disabled = true;
  try{
    const r = await fetch("/api/enc/queue/opts",{method:"POST",
      headers:{"Content-Type":"application/json"},
      body:JSON.stringify(Object.assign({file:file}, campos))});
    const d = await r.json();
    if(!d.ok) alert(d.error||"no se pudo guardar el ajuste");
  }catch(e){ alert("error: "+e); }
  el.disabled = false;
}

// Retencion: que no arranque nada sin que elijas modo. No es una pausa.
async function encSetHold(on){
  try{
    await fetch("/api/enc/hold",{method:"POST",
      headers:{"Content-Type":"application/json"},
      body:JSON.stringify({on:on})});
  }catch(e){ alert("error: "+e); }
}

async function encQueueMove(file, direction) {
  try {
    await fetch("/api/enc/queue/move", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({file, direction})
    });
  } catch(e) { console.error("Queue move error:", e); }
}

const conn=document.getElementById("conn");
let evtSource;
function connect(){
  evtSource=new EventSource("/stream");
  evtSource.onopen=()=>{conn.className="live";conn.textContent="● LIVE";};
  evtSource.onmessage=e=>{
    try{
      const d=JSON.parse(e.data);
      if(d.enc)    updateEnc(d.enc);
      if(d.ytdlp)  updateYtdlp(d.ytdlp);
    }catch{}
  };
  evtSource.onerror=()=>{
    conn.className="dead";conn.textContent="● DISCONNECTED";
    evtSource.close();setTimeout(connect,3000);
  };
}
connect();
syncPoll();

// ══════════════════════════════════════════════════════════════════════════════
// REMUX
// ══════════════════════════════════════════════════════════════════════════════
let rmxSlots = ["", ""];
let rmxData  = [];
let rmxVideo = null;          // {fi, index}
let rmxPick  = {};            // "fi:index" -> opciones de la pista
let rmxEncodeAfter = false;   // encadenar con el pipeline de vídeo al terminar

function rmxKey(fi, ix){ return fi + ":" + ix; }

function rmxRenderSlots(){
  document.getElementById("rmx-slots").innerHTML = rmxSlots.map((p,i)=>`
    <div class="file-row" style="margin-bottom:6px">
      <input class="inp cyan" id="rmx-in-${i}" type="text" value="${esc(p)}"
             placeholder="Ruta del fichero ${i+1}" autocomplete="off"
             oninput="rmxSlots[${i}]=this.value">
      <button class="btn btn-amber" onclick="openBrowser('remux${i}')">📁</button>
      ${rmxSlots.length>1?`<button class="btn btn-red" onclick="rmxDelSlot(${i})">✕</button>`:``}
    </div>`).join("");
}
function rmxAddSlot(){ if(rmxSlots.length<6){ rmxSlots.push(""); rmxRenderSlots(); } }
function rmxDelSlot(i){ rmxSlots.splice(i,1); rmxRenderSlots(); }

async function rmxProbe(){
  const paths = rmxSlots.map(p=>p.trim()).filter(Boolean);
  if(!paths.length){ alert("Pon al menos un fichero"); return; }
  const btn=document.getElementById("rmx-probe-btn");
  btn.disabled=true; btn.textContent="Leyendo...";
  try{
    const r=await fetch("/api/remux/probe",{method:"POST",
      headers:{"Content-Type":"application/json"},body:JSON.stringify({paths})});
    const d=await r.json();
    rmxData=d.files||[]; rmxVideo=null; rmxPick={};
    // por defecto: el video del primer fichero que tenga uno
    for(let fi=0; fi<rmxData.length; fi++){
      const v=(rmxData[fi].tracks||[]).find(t=>t.type==="video");
      if(v){ rmxVideo={fi,index:v.index}; break; }
    }
    rmxRender();
  }catch(e){ alert("Error leyendo: "+e); }
  btn.disabled=false; btn.textContent="⟳ Leer pistas";
}

function rmxDesc(t){
  if(t.type==="video")
    return `${t.codec} ${t.width}x${t.height} ${t.hdr}`;
  if(t.type==="audio")
    return `${t.codec}${t.atmos?" <b style='color:var(--green)'>ATMOS</b>":""} ${t.channels||"?"}ch`
         + (t.bitrate?` ${Math.round(t.bitrate/1000)}k`:"");
  // Subtítulos: lo que importa de un vistazo es si ya es texto o hay que sacarlo
  // por OCR, que son minutos por pista y no segundos.
  if(t.type==="subtitle")
    return `${t.codec}` + (t.srt ? ` <span style="color:var(--green);font-size:11px">texto</span>`
          : t.ocr ? ` <span style="color:var(--amber);font-size:11px">imagen · OCR</span>`
          : t.text ? ` <span style="color:var(--dim);font-size:11px">texto</span>`
          : ` <span style="color:var(--red);font-size:11px">sin ruta a SRT</span>`);
  return t.codec;
}

function rmxRender(){
  const host=document.getElementById("rmx-tracks");
  if(!rmxData.length){ host.innerHTML=""; document.getElementById("rmx-launch").style.display="none"; return; }
  host.innerHTML = rmxData.map((f,fi)=>{
    // esc() en todo lo que venga del disco: los nombres de fichero y sobre todo
    // los TÍTULOS DE PISTA son texto libre metido en los metadatos del MKV, no
    // datos nuestros. Un título con un '<' rompía el HTML de la fila.
    if(f.error) return `<div class="card" style="border-color:var(--red)">
        <b>${esc(f.path)}</b><br><span style="color:var(--red)">${esc(f.error)}</span></div>`;
    const isBase = rmxVideo && rmxVideo.fi===fi;
    return `<div class="card" style="margin-bottom:10px;${isBase?"border-color:var(--cyan)":""}">
      <div style="font-weight:600;margin-bottom:8px">${esc(f.name)}
        ${isBase?'<span class="stream-type-badge stream-type-audio" style="margin-left:8px">BASE</span>':''}
        <span style="color:var(--dim);font-weight:400;font-size:12px;margin-left:8px">
          ${(f.duration/60).toFixed(1)} min</span></div>
      ${(f.tracks||[]).map(t=>rmxRow(fi,t)).join("")}
    </div>`;
  }).join("");
  document.getElementById("rmx-launch").style.display = rmxVideo ? "block" : "none";
}

function rmxRow(fi,t){
  const k=rmxKey(fi,t.index);
  const p=rmxPick[k];
  const on=!!p;
  if(t.type==="video"){
    const sel = rmxVideo && rmxVideo.fi===fi && rmxVideo.index===t.index;
    // Casilla de ENCADENADO: al terminar el remux, la salida se manda al pipeline
    // de vídeo en vez de quedarse en /encoded. Así se hace todo de una pasada
    // (sync + conversiones + remux + encode) en lugar de encolar a mano después.
    // Solo se ofrece en la pista de vídeo ELEGIDA, que es la que se encodearía.
    return `<div class="stream-row" style="padding:8px 10px">
      <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
        <label style="display:flex;gap:10px;align-items:center;cursor:pointer;flex:1">
          <input type="radio" name="rmxvid" ${sel?"checked":""}
                 onchange="rmxVideo={fi:${fi},index:${t.index}};rmxRender()">
          <span class="stream-type-badge">Vídeo</span>
          <span>${rmxDesc(t)}</span>
          <span style="color:var(--dim);font-size:12px">${t.fps||""}</span>
        </label>
        ${sel?`<label style="font-size:12px;color:var(--pink)" title="Al acabar el remux, la salida entra sola en la cola del encoder (C:\\Media\\encode_queue). El audio ya convertido y los subtítulos ya en SRT se copian, no se reprocesan.">
          <input type="checkbox" ${rmxEncodeAfter?"checked":""}
                 onchange="rmxEncodeAfter=this.checked;rmxRender()">
          → encodear vídeo al terminar</label>`:``}
      </div></div>`;
  }
  const isBase = rmxVideo && rmxVideo.fi===fi;
  // esc() SOBRE p.rec.text (26/08/2026). Era la unica cadena del panel que
  // llegaba a innerHTML sin escapar, y no es texto nuestro: rec.text incorpora
  // el TITULO DE PISTA del MKV -texto libre de los metadatos- cuando dice contra
  // que referencia se midio, y tambien los mensajes de error de remuxlib. En
  // esta misma funcion, tres lineas mas abajo, el titulo ya pasaba por esc();
  // aqui se habia quedado sin cubrir.
  // Escaparlo no rompe nada: rec.text es SIEMPRE texto plano -recommend() une
  // sus lineas con \n y el cliente solo concatena cadenas-, no lleva marcado
  // intencionado como si lo lleva rmxDesc().
  return `<div class="stream-row" style="padding:8px 10px">
    <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
      <input type="checkbox" ${on?"checked":""} onchange="rmxToggle(${fi},${t.index},this.checked)">
      <span class="stream-type-badge ${t.type==="audio"?"stream-type-audio":""}">${t.type==="audio"?"Audio":"Sub"}</span>
      <span style="min-width:190px">${rmxDesc(t)}</span>
      <span style="color:var(--dim);font-size:12px;flex:1">${esc(t.title||"")}</span>
      ${on?`
        <input class="inp" style="width:60px;padding:5px 7px;font-size:12px" value="${esc(p.lang||"")}"
               oninput="rmxPick['${k}'].lang=this.value" title="Idioma">
        <input class="inp" style="width:150px;padding:5px 7px;font-size:12px" value="${esc(p.title||"")}"
               oninput="rmxPick['${k}'].title=this.value" placeholder="título">
        <label style="font-size:12px"><input type="checkbox" ${p.def?"checked":""}
               onchange="rmxPick['${k}'].def=this.checked"> default</label>
        <label style="font-size:12px"><input type="checkbox" ${p.forced?"checked":""}
               onchange="rmxPick['${k}'].forced=this.checked"> forced</label>
        <input class="inp" style="width:82px;padding:5px 7px;font-size:12px" type="number" value="${p.sync_ms}"
               oninput="rmxPick['${k}'].sync_ms=parseInt(this.value||0)" title="Desfase en ms">
        ${!isBase?`<button class="btn btn-cyan" style="padding:5px 9px;font-size:12px"
               onclick="rmxMeasure(${fi},${t.index})">⇌ Medir</button>`:``}
        ${(t.type==="audio"&&t.nativo===false)?`<label style="font-size:12px;color:var(--amber)"
               title="${t.objects?"Conserva los objetos Atmos (JOC). Pasa por DEE: varios minutos.":"El TV no decodifica este códec; copiarlo hace que Plex transcodifique en cada reproducción."}">
               <input type="checkbox" ${p.convert?"checked":""}
               onchange="rmxPick['${k}'].convert=this.checked?'${t.objects?"ddp_atmos":"ddp"}':null;rmxRender()">
               → DD+${t.objects?" Atmos":""}</label>`:``}
        ${(t.type==="subtitle"&&t.srtable&&!t.srt)?`<label style="font-size:12px;color:var(--amber)"
               title="${t.ocr?"OCR con PgsToSrt: varios minutos por pista":"conversión con ffmpeg: segundos"}">
               <input type="checkbox" ${p.to_srt?"checked":""}
               onchange="rmxPick['${k}'].to_srt=this.checked;rmxRender()">
               → SRT${t.ocr?" (OCR)":""}</label>`:``}
        ${(t.type==="subtitle"&&!t.srtable&&!t.srt)?`<span style="font-size:12px;color:var(--red)"
               title="PgsToSrt solo entiende PGS">no convertible, se copia tal cual</span>`:``}
        ${p.convert?`<span style="font-size:12px;color:var(--muted);padding:5px 7px"
               title="${p.objects?"DD+ Atmos va siempre a 768k, igual que el pipeline de vídeo: es el bitrate que usan Netflix, Disney+, Apple TV+ y Amazon para este códec.":"Calculado por canales, o sobre el bitrate de origen si la fuente es lossy y bajo."}">${p.bitrate}k</span>`:``}
      `:``}
    </div>
    ${on&&p.rec?`<div style="margin:6px 0 0 30px;font-size:12px;padding:7px 10px;border-radius:6px;
        background:rgba(255,255,255,.04);border-left:3px solid var(--${p.rec.level==='ok'?'green':p.rec.level==='danger'?'red':'amber'})">
        ${esc(p.rec.text)}</div>`:``}
  </div>`;
}

// kbps de DD+ para una pista SIN objetos. Es el gemelo en JS de
// Get-DdpBitrateForLossy (atmos-lib.ps1): si se toca una, tocar la otra.
//
// Por canales de normal; sobre el ORIGEN cuando la fuente es lossy de bitrate
// bajo (Opus, Vorbis, MP2, WMA), porque ahí el techo de calidad ya lo puso el
// encoder original y gastar 256k en transportar un Opus de 128k es tirar bits.
// DTS queda fuera a propósito: es lossy pero de bitrate alto, y el DTS-HD MA es
// directamente sin pérdida. Los lossless (FLAC, PCM) también: un FLAC estéreo
// son ~800k y no por eso hacen falta.
const RMX_LOSSY_BAJO = ['opus','vorbis','mp2','wmav2','wmapro'];
// Rejilla de DEE (pcm_to_ddp). Ojo al tramo alto: después de 400 los saltos son
// 448/512/576/640, así que 416 o 480 NO son válidos aunque sean múltiplos de 32.
const RMX_DEE_GRID = [32,40,48,56,64,72,80,88,96,104,112,120,128,144,160,176,
                      192,200,208,216,224,232,240,248,256,272,288,304,320,336,
                      352,368,384,400,448,512,576,640,704,768,832,896,960,1008,1024];
function rmxDdpBitrate(t){
  const ch = t.channels || 2;
  const porCanales = ch>=6 ? 640 : 256;
  if(!RMX_LOSSY_BAJO.includes(t.codec) || !t.bitrate) return porCanales;
  const piso  = ch>=8 ? 384 : (ch>=6 ? 256 : 128);
  const techo = ch>=6 ? 640 : 256;
  let k = Math.ceil((t.bitrate/1000) * 1.5);
  if(k < piso)  k = piso;
  if(k > techo) k = techo;
  // Siempre hacia ARRIBA al primer valor válido: no quitar calidad por redondeo.
  return RMX_DEE_GRID.find(v => v >= k) || 640;
}

function rmxToggle(fi,ix,on){
  const k=rmxKey(fi,ix);
  if(!on){ delete rmxPick[k]; rmxRender(); return; }
  const t=(rmxData[fi].tracks||[]).find(x=>x.index===ix);
  // Un audio que el TV NO decodifica (DTS, TrueHD, FLAC, PCM, Opus...) viene
  // marcado para convertir POR DEFECTO, igual que los subtítulos no-SRT: copiarlo
  // no conserva nada útil, solo hace que Plex transcodifique en cada reproducción.
  // Antes esto solo se ofrecía para pistas con objetos (Atmos/TrueHD), así que un
  // DTS se copiaba sin que el panel diera siquiera la opción.
  // OJO con el ===false: si el backend es viejo y no manda 'nativo', undefined
  // haría true con un !t.nativo y se ofrecería convertir hasta un EAC3.
  const conv = (t.type==="audio" && t.nativo===false) ? (t.objects ? 'ddp_atmos' : 'ddp') : null;
  // Bitrate por defecto: la ruta Atmos no baja de 384 y usa 768/1024; la ruta sin
  // objetos va con los valores normales de DD+ (640 en 5.1+, 256 por debajo)...
  // ...salvo si el ORIGEN es lossy de bitrate bajo, donde se dimensiona sobre él
  // (05/08/2026). Era el último sitio donde no se aplicaba: los dos pipelines de
  // PowerShell ya usan Get-DdpBitrateForLossy desde el 04/08, y aquí un Opus de
  // 128k salía a 256k, el doble, sin recuperar un solo detalle.
  // La ruta ATMOS va SIEMPRE a 768k, igual que el pipeline de vídeo
  // (encode.ps1, $DeewBitrateAtmos). Antes aquí se ponía 1024 cuando la pista
  // tenía 8 canales, y eso dejaba la biblioteca desigual según por qué camino
  // hubiera pasado cada película, sin ningún criterio detrás.
  //
  // 768 no es un recorte: es lo que entregan Netflix, Disney+, Apple TV+ y
  // Amazon para este mismo códec, y es el punto sobre el que está afinado el
  // JOC. Auditada la biblioteca el 06/08/2026: de 56 pistas E-AC-3 JOC, 48 ya
  // estaban a 768k; las que subían de ahí eran rips de disco, no elecciones.
  // 1024 cuesta un 33 % más de tamaño (~230 MB por pista en una peli de 2 h)
  // sin una mejora que se distinga.
  const br = t.objects ? 768 : rmxDdpBitrate(t);
  rmxPick[k]={fi,index:ix,type:t.type,lang:t.lang,title:t.title,
              def:t.default,forced:t.forced,sync_ms:0,convert:conv,
              // measured=true SOLO si esta pista se midio POR SI MISMA (no
              // heredada de otra). Distingue un valor medido directamente de una
              // estimacion propagada, para no pisar el bueno con el estimado.
              measured:false,
              bitrate:br,objects:t.objects,nativo:t.nativo,rec:null,
              // Un subtítulo que no es SRT se convierte por defecto: es lo que se
              // quiere casi siempre. Desmarcar es un clic; darse cuenta después de
              // que se quedó en PGS son 20 GB remuxeados otra vez.
              to_srt:!!(t.srtable && !t.srt), ocr:!!t.ocr};
  rmxRender();
}

async function rmxMeasure(fi,ix){
  if(!rmxVideo){ alert("Elige primero la pista de vídeo"); return; }
  const k=rmxKey(fi,ix), p=rmxPick[k];
  const base=rmxData[rmxVideo.fi], src=rmxData[fi];
  // referencia: una pista de audio del fichero base, a ser posible del MISMO idioma
  const auds=(base.tracks||[]).filter(t=>t.type==="audio");
  if(!auds.length){ alert("El fichero base no tiene audio con el que comparar"); return; }
  const ref=auds.find(a=>a.lang===p.lang)||auds[0];

  // QUE PISTA SE MIDE DE VERDAD.
  // El desfase es CASI una propiedad de la linea de tiempo del fichero: casi
  // todas las pistas de un MKV comparten reloj... pero NO siempre al fotograma.
  // Una pista puede traer su propio retardo de contenedor (delay/codec_delay), y
  // entonces necesita un sync distinto del de sus hermanas. Caso real: Bitelchús
  // 2024, la pista inglesa del fuente tenia delay=43 ms y medida daba +624 frente
  // a los +667 de la española. Por eso cada AUDIO se mide por su cuenta y no se
  // pisa con el de otra pista (ver la propagacion mas abajo).
  // Un subtitulo SI no tiene forma de onda que correlacionar. Antes el boton
  // «Medir» se ofrecia tambien en los subtitulos y mandaba el indice del
  // subtitulo a una funcion que correlaciona audio: fallaba SIEMPRE con "pocas
  // ventanas validas". Ahora, si lo pedido es un subtitulo, se mide con una pista
  // de AUDIO del mismo fichero (preferiblemente del mismo idioma) y se hereda: un
  // fotograma arriba o abajo es inapreciable en texto.
  const srcAuds=(src.tracks||[]).filter(t=>t.type==="audio");
  const esSub = p.type==="subtitle";
  if(esSub && !srcAuds.length){
    p.rec={level:"danger",text:"Este fichero no trae audio, así que no hay con qué "
          +"medir su línea de tiempo. Un subtítulo no se puede medir por sí solo: "
          +"ajusta el desfase a mano, o mídelo en un fichero que sí tenga audio."};
    rmxRender(); return;
  }
  const medida = esSub ? (srcAuds.find(a=>a.lang===p.lang)||srcAuds[0]) : {index:ix};
  // OJO al texto: un subtitulo NO se mide contra el audio de su propio fichero
  // (eso daria 0 siempre). Se usa su audio [lang] solo como SELLO DE TIEMPO -el
  // subtitulo no tiene onda que correlacionar- y ese sello se compara contra el
  // audio del fichero del VIDEO (la 'ref' de abajo). El resultado es el desfase
  // ENTRE LOS DOS FICHEROS, no cero. Da por hecho que el subtitulo va en sincronia
  // con el audio de su propio fichero, que es lo normal (se creo para el).
  const viaTxt = esSub ? ` (el subtítulo no tiene onda: se usa su audio [${medida.lang}] como sello de tiempo, y ese sello se compara contra el vídeo)` : ``;

  // ¿Se ha pedido la segunda opinión por imagen? Cambia TODO el tiempo de espera:
  // medido el 07/08/2026 sobre un 4K de 2h25 -> audio solo 9,7 s, audio+imagen
  // 873,9 s (14,6 min). El mensaje decía «30-60 s» en los dos casos, así que con
  // la casilla marcada el panel parecía congelado durante un cuarto de hora y no
  // mencionaba la imagen por ningún lado: parecía que la casilla no hacía nada.
  const conImagen = !!(document.getElementById("rmx-video-check")||{}).checked;
  const conSubs   = !!(document.getElementById("rmx-subs-check")||{}).checked;
  const contraTxt = "«"+(ref.title||ref.codec)+"» ["+ref.lang+"]"+viaTxt;
  const t0 = Date.now();
  // COSTES REALES, cronometrados el 17/08/2026 sobre un fichero de 17,6 GB:
  // audio 2 s · subtítulos 46 s · imagen 199 s. El texto anterior decía «unos
  // 30 s en total en 4K» cuando el comentario de este mismo bloque ya recogía
  // 873,9 s medidos: prometía diez veces menos de lo que costaba.
  // Y el caso que más despistaba era el de NINGUNA casilla: si el audio no
  // engancha, el reintento automático se pone a medir por su cuenta y el
  // usuario veía un contador subiendo sin ninguna explicación.
  const conPaq    = !!(document.getElementById("rmx-paq-check")||{}).checked;
  // LABIOS: no mide esta pista contra la referencia, mide el FICHERO BASE contra
  // su propia imagen. Va aparte de las otras tres en el texto porque contesta a
  // otra pregunta (ver el bloque de resultado, más abajo).
  const conVoz    = !!(document.getElementById("rmx-voz-check")||{}).checked;
  const extras = [conPaq?"PAQUETES":null, conSubs?"SUBTÍTULOS":null,
                  conImagen?"IMAGEN":null, conVoz?"LABIOS":null].filter(Boolean);
  // LO QUE ENCARECE LA IMAGEN (15/09/2026). Los 199 s son 4 puntos con ventana
  // de búsqueda ±30 s en ficheros que duran lo mismo. Si duran distinto,
  // measure() ensancha la ventana (dif×1,2+30, tope 300 s) y cada punto
  // decodifica hasta 3,2× más vídeo; y si los desfases discrepan entre sí
  // (montajes distintos, que es lo que suele haber detrás de duraciones
  // distintas) se remide con 16 puntos, ×5. Influencer (2022): 223 s de
  // diferencia → 20 puntos de 776 s → ~9 min, no 199 s. Se avisa ANTES.
  const difDur = Math.abs((base.duration||0)-(src.duration||0));
  const search = difDur > 30 ? Math.min(300, difDur*1.2+30) : 30;
  const factorVentana = (180 + 2*search) / 240;   // (base 90 + origen 90+2·search) / (90+150)
  const pinta = () => {
    const s = Math.round((Date.now()-t0)/1000);
    const reloj = s<60 ? `${s} s` : `${Math.floor(s/60)} min ${String(s%60).padStart(2,"0")} s`;
    let txt = `Midiendo contra ${contraTxt}`;
    if (extras.length) {
      txt += ` — AUDIO + ${extras.join(" + ")} · ${reloj} transcurridos.`;
      if (conSubs)   txt += ` Los subtítulos solo demultiplexan (~46 s en un fichero de 17,6 GB).`;
      if (conImagen) {
        txt += ` La pasada por imagen decodifica vídeo y es la cara: ~199 s en ese mismo fichero con 4 puntos y ventana ±30 s.`;
        if (difDur > 30) {
          txt += ` AQUÍ los ficheros duran ${Math.round(difDur)} s distinto: la ventana sube a ±${Math.round(search)} s`
               + ` (×${factorVentana.toFixed(1)} por punto) y, si los desfases no cuadran entre sí, se remide con 16 puntos (×5):`
               + ` cuenta con ${Math.round(199*factorVentana/60)}-${Math.round(199*factorVentana*5/60)} min para un fichero así.`;
        }
      }
      if (conVoz)    txt += ` La de labios decodifica el audio entero del fichero base: 76 s medidos en un 4K de 2 h 12.`;
    } else {
      txt += `... ${reloj}`;
    }
    p.rec = {level:"warn", text: txt};
    rmxRender();
  };
  pinta();
  // Contador vivo: sin esto no hay forma de distinguir «trabajando» de «colgado».
  const tic = setInterval(pinta, 1000);
  try{
    const r=await fetch("/api/remux/measure",{method:"POST",
      headers:{"Content-Type":"application/json"},
      body:JSON.stringify({base:{path:base.path,index:ref.index},
                           src:{path:src.path,index:medida.index,objects:!!p.objects},
                           for_subtitle:esSub,
                           video:!!(document.getElementById("rmx-video-check")||{}).checked,
                           subs:!!(document.getElementById("rmx-subs-check")||{}).checked,
                           paquetes:!!(document.getElementById("rmx-paq-check")||{}).checked,
                           voz:conVoz})});
    const d=await r.json();
    // Parar el contador AQUI, en cuanto hay respuesta: a partir de este punto se
    // escribe el resultado en p.rec y no queremos que el tic lo pise.
    clearInterval(tic);
    if(!d.ok){ p.rec={level:"danger",text:d.error||"no se pudo medir"}; rmxRender(); return; }
    p.rec=d.recommend;
    // FACTOR DE ESTIRAMIENTO (deriva). Se guarda en la pista para aplicarlo en el
    // mux con --sync offset,factor. recommend() lo devuelve tanto en subtitulos
    // (accion sync, sin perdida) como en audio (accion resample). Se guarda en las
    // dos, pero el MUX solo lo aplica a SUBTITULOS: en audio la deriva se arregla
    // resampleando, no estirando timestamps. Aqui solo se conserva el numero.
    p.stretch = (d.recommend && d.recommend.stretch && Math.abs(d.recommend.stretch-1) > 1e-6)
                ? d.recommend.stretch : undefined;
    // Segunda opinion por imagen, solo si se pidio. Se anyade al texto de la
    // recomendacion en vez de sustituirlo: el numero bueno para un desfase fijo
    // sigue siendo el del AUDIO (0,5 ms de resolucion frente a 83 ms del video).
    if(d.video){
      if(!d.video.ok){
        p.rec={...p.rec,text:p.rec.text+`  ·  imagen: no se pudo medir (${d.video.error||"?"})`};
      }else{
        const va=d.video_agree;
        p.rec={...p.rec,
          level:(va===false && p.rec.level==="ok")?"warn":p.rec.level,
          text:p.rec.text+`  ·  IMAGEN: ${d.video.beta_ms>=0?"+":""}${d.video.beta_ms} ms`
             +` (alpha=${(d.video.alpha||1).toFixed(6)}, deriva ${d.video.drift_ms>=0?"+":""}${d.video.drift_ms} ms)`
             +(va===false?`  ATENCION: no coincide con el audio (${d.video_delta_ms} ms de diferencia); revisa antes de fiarte de ninguna de las dos.`
                         :`  Coincide con el audio.`)};
      }
    }
    // LABIOS (02/09/2026). Segunda opinión de OTRA CLASE: no dice si esta pista
    // casa con la referencia -para eso está todo lo de arriba- sino si el
    // FICHERO BASE casa con su propia imagen. Es el único aviso posible cuando
    // un release trae TODOS los audios corridos: entre ellos cuadran, así que la
    // medida fina sale +7 ms y parece que no hay nada que arreglar mientras los
    // labios van descuadrados medio segundo.
    // NO toca p.sync_ms a propósito: este número lleva ±250 ms de incertidumbre
    // (los tiempos de un subtítulo son de autor, no medidos) y no puede pisar una
    // medida de audio que da el milisegundo. Se dice, y decide el usuario.
    if(d.voz){
      const v=d.voz;
      if(!v.ok){
        p.rec={...p.rec,text:p.rec.text+`  ·  labios: no se pudo comprobar (${v.error||"?"})`};
      }else if(v.sospecha){
        p.rec={...p.rec,
          level:p.rec.level==="ok"?"warn":p.rec.level,
          text:p.rec.text+`  ·  ⚠ LABIOS: el fichero base trae el audio ${Math.abs(v.desfase_ms)} ms `
             +`${v.desfase_ms>0?"TARDE":"ADELANTADO"} respecto a su PROPIA imagen (la voz entra `
             +`${v.voz_ms>=0?"+":""}${v.voz_ms} ms tras el subtítulo [${v.sub_lang}], y lo normal `
             +`es +${v.sesgo_ms}). Eso NO lo arregla el desfase de arriba: va en la línea de tiempo `
             +`del fichero, así que le pasa a TODAS las pistas por igual y habría que sumar `
             +`${v.sync_ms>=0?"+":""}${v.sync_ms} ms a cada una. Confírmalo con los labios antes de `
             +`aplicarlo: ±${v.margen_ms} ms de incertidumbre. (${v.n} de ${v.total} diálogos, `
             +`nitidez ${v.nitidez})`};
      }else{
        p.rec={...p.rec,
          text:p.rec.text+`  ·  labios: el fichero base va a la par de su propia imagen `
             +`(${v.desfase_ms>=0?"+":""}${v.desfase_ms} ms, dentro del ±${v.margen_ms} ms que `
             +`resuelve el método; ${v.n} de ${v.total} diálogos [${v.sub_lang}])`};
      }
    }
    if(d.recommend.sync_ms!==undefined && d.recommend.action!=="copy")
      p.sync_ms=d.recommend.sync_ms;
    p.measured=true;   // medida DIRECTA de esta pista: manda sobre cualquier estimacion

    // PROPAGACION al resto de pistas del MISMO fichero, pero como ESTIMACION, no
    // como certeza. Antes se copiaba el valor a TODAS y se decia "comparten
    // reloj", pero eso es falso a nivel de fotograma: una pista puede traer su
    // propio retardo de contenedor. Caso real (Bitelchús 2024): la pista inglesa
    // del fuente tenia delay=43 ms de fabrica, asi que medida daba +624 y la
    // española +667 -1 fotograma de diferencia, REAL-. Copiar una sobre la otra
    // desincronizaba justo ese fotograma.
    // Reglas nuevas:
    //   - NUNCA se pisa una pista con medida propia (measured=true).
    //   - Un subtitulo hereda del audio de SU MISMO IDIOMA, porque su tiempo sigue
    //     al dialogo de ese idioma. Si los dos audios difieren (caso real: eng con
    //     desfase fijo y spa con deriva), el sub eng NO debe llevar lo del spa.
    //     Antes se copiaba el ultimo audio medido a TODOS los subs sin mirar el
    //     idioma. Un sub sin audio de su idioma se estima del medido, avisando.
    //   - Un audio sin medir recibe la estimacion, pero se marca como tal y se
    //     invita a medirlo: puede diferir si lleva retardo propio.
    const delFich = Object.values(rmxPick).filter(x=>x.fi===fi);
    const mismoFichAudios = delFich.filter(x=>x.type==="audio");
    const heredan=[], estimados=[], pendientes=[];
    const signo = v => `${v>=0?"+":""}${v} ms`;

    // PASO 1 - AUDIOS sin medir: NO se les copia NINGUN numero (18/08/2026).
    // Antes recibian el del audio medido como "estimacion", y aunque el texto lo
    // decia, en la tabla se veia un numero igual que el medido y parecia una
    // medida. Se quita por dos motivos:
    //   1. Puede ser FALSO a nivel de fotograma: cada pista puede traer su propio
    //      retardo de contenedor. Caso real (Bitelchus 2024): eng +624 ms y spa
    //      +667 ms, un fotograma de diferencia REAL.
    //   2. El motivo que lo justificaba ha desaparecido. La estimacion existia
    //      porque medir costaba minutos; desde el 18/08/2026 una medida de audio
    //      son ~4 s, asi que medir cada pista es mas barato que arriesgarse.
    // Se marcan como PENDIENTES, sin numero, para que se vea que faltan.
    if(p.type==="audio"){
      mismoFichAudios.forEach(a=>{
        if(a===p || a.measured || a.sync_ms!==undefined) return;
        a.rec={level:"warn",text:`Sin medir. Pulsa MEDIR en esta pista (cuesta unos segundos): `
              +`no se le copia el valor de «${p.title||p.lang}» porque cada audio puede traer `
              +`su propio retardo de contenedor y diferir en algún fotograma.`};
        pendientes.push(`audio [${a.lang}]`);
      });
    }

    // PASO 2 - SUBTITULOS sin medir: siguen al audio de SU MISMO IDIOMA, porque
    // su tiempo sigue al dialogo de ese idioma y no tienen onda propia con la que
    // medirse. Desde el 18/08/2026 solo heredan si ese audio esta MEDIDO; si no,
    // se quedan pendientes y se dice cual hay que medir. Antes heredaban tambien
    // de un audio meramente estimado, o sea que arrastraban un numero que nadie
    // habia medido. Unica excepcion: un subtitulo cuyo idioma no tiene audio en el
    // fichero se estima del audio medido, avisando, porque no hay nada mejor.
    delFich.forEach(q=>{
      if(q===p || q.type!=="subtitle" || q.measured) return;
      const suAudio = mismoFichAudios.find(a=>a.lang===q.lang);
      if(suAudio && suAudio.measured){
        q.sync_ms=suAudio.sync_ms; q.stretch=suAudio.stretch;
        const der = suAudio.stretch ? ` + estiramiento (deriva) x${suAudio.stretch.toFixed(6)}` : ``;
        q.rec={level:"ok",text:`Heredado del audio [${suAudio.lang}] del mismo fichero: `
              +`${signo(q.sync_ms)}${der} (un subtítulo no tiene onda propia; sigue al `
              +`diálogo de su idioma).`};
        heredan.push(`sub [${q.lang}]`);
      } else if(suAudio){
        // Su audio existe pero AUN NO se ha medido: no se inventa un numero.
        q.rec={level:"warn",text:`Pendiente: mide el audio [${suAudio.lang}] de este fichero `
              +`y este subtítulo heredará su valor automáticamente.`};
        pendientes.push(`sub [${q.lang}]`);
      } else {
        const fuente = p;
        const der = fuente.stretch ? ` + estiramiento (deriva) x${fuente.stretch.toFixed(6)}` : ``;
        q.sync_ms=fuente.sync_ms; q.stretch=fuente.stretch;
        q.rec={level:"warn",text:`Estimado del audio [${p.lang}] (no hay audio en [${q.lang}] `
              +`con el que medirlo): ${signo(q.sync_ms)}${der}. Revísalo si el idioma importa.`};
        estimados.push(`sub [${q.lang}]`);
      }
    });

    const mismoIdioma = ref.lang === p.lang;
    const seTxt = (d.drift_se_ms===null||d.drift_se_ms===undefined)
                  ? `` : ` ±${d.drift_se_ms} ms`;
    p.rec.text += `  ·  medido contra «${ref.title||ref.codec}» [${ref.lang}]`+viaTxt
                + (mismoIdioma ? `` : ` ⚠ otro idioma, la medida es menos fina`)
                + `  ·  alpha=${d.alpha.toFixed(7)} · offset ${d.beta_ms>=0?"+":""}${d.beta_ms} ms · `
                + `deriva ${d.drift_ms>=0?"+":""}${d.drift_ms}${seTxt} ms · `
                + `residuo ${d.residual_ms} ms (${d.used}/${d.total} puntos)`
                + (heredan.length?`  ·  aplicado a: ${heredan.join(", ")}`:``)
                + (estimados.length?`  ·  estimado (mídelos para confirmar): ${estimados.join(", ")}`:``)
                + (pendientes.length?`  ·  SIN MEDIR (mídelos aparte): ${pendientes.join(", ")}`:``);
  }catch(e){ p.rec={level:"danger",text:"error: "+e}; }
  finally{ clearInterval(tic); }   // red de seguridad: tambien si se sale por el return de arriba
  rmxRender();
}

async function rmxLaunch(){
  const name=document.getElementById("rmx-outname").value.trim();
  if(!name){ alert("Pon un nombre de salida"); return; }
  if(!rmxVideo){ alert("Elige la pista de vídeo"); return; }
  const tracks=Object.values(rmxPick).map(p=>({
    path:rmxData[p.fi].path, index:p.index, type:p.type,
    lang:p.lang, title:p.title, default:p.def, forced:p.forced,
    sync_ms:p.sync_ms||0, stretch:p.stretch||1, convert:p.convert, bitrate:p.bitrate,
    // objects decide si la conversión va por la ruta Atmos (-IsAtmos, conserva
    // objetos) o por la normal. Sin esto el backend pasaba -IsAtmos SIEMPRE.
    objects:!!p.objects,
    to_srt:!!p.to_srt, ocr:!!p.ocr}));
  if(!tracks.length && !confirm("No has marcado ninguna pista de audio ni subtítulos. ¿Seguir?")) return;
  const nOcr=tracks.filter(t=>t.to_srt&&t.ocr).length;
  if(nOcr && !confirm(nOcr+" subtítulo(s) van por OCR: cuenta con varios minutos por pista.\n¿Seguir?")) return;
  const r=await fetch("/api/remux/add",{method:"POST",
    headers:{"Content-Type":"application/json"},
    body:JSON.stringify({output:name,
      video:{path:rmxData[rmxVideo.fi].path,index:rmxVideo.index},
      encode_after:rmxEncodeAfter,
      tracks})});
  const d=await r.json();
  if(d.error){ alert(d.error); return; }
  document.getElementById("rmx-outname").value="";
  if(rmxEncodeAfter) alert("Encolado. Al terminar el remux, la salida pasará sola al pipeline de vídeo (pestaña Encoder).");
  rmxPoll();
}

async function rmxPoll(){
  try{
    const r=await fetch("/api/remux/status");
    const d=await r.json();
    const host=document.getElementById("rmx-jobs");
    // Indicador de la pestana, igual que las demas: se enciende cuando ESTE
    // pipeline tiene un trabajo en curso. OJO: no vale d.busy, que significa "el
    // pipeline.lock esta cogido" y tambien es true cuando quien trabaja es el
    // encoder o el audio, con el remux parado. Va ANTES del return de "sin
    // trabajos" para que tambien se APAGUE al vaciarse la lista.
    const rmxOn=(d.jobs||[]).some(j=>j.status==="running");
    const dotRmx=document.getElementById("dot-remux");
    if(dotRmx) dotRmx.className="tab-dot"+(rmxOn?" on":"");
    if(!d.jobs||!d.jobs.length){ host.innerHTML='<div class="browser-loading">Sin trabajos</div>'; return; }
    host.innerHTML=d.jobs.map(j=>{
      const col={done:"green",warn:"amber",error:"red",running:"cyan",waiting:"amber",
                 queued:"dim",cancelled:"dim"}[j.status]||"dim";
      // Barra solo mientras trabaja. pct null = fase sin % fiable (verificando):
      // barra indeterminada (a rayas animadas) para que no parezca colgado.
      let bar="";
      if(j.status==="running" && j.phase){
        const known = (typeof j.pct==="number");
        const w = known ? Math.max(2,Math.min(100,j.pct)) : 100;
        bar=`<div style="margin-top:6px">
          <div style="display:flex;justify-content:space-between;font-size:11px;color:var(--dim);margin-bottom:3px">
            <span>${esc(j.phase)}</span><span>${known?j.pct+" %":"…"}</span></div>
          <div style="height:6px;border-radius:4px;background:rgba(255,255,255,.08);overflow:hidden">
            <div class="${known?"":"rmx-indet"}" style="height:100%;width:${w}%;border-radius:4px;
                 background:var(--cyan);transition:width .4s"></div></div></div>`;
      }
      return `<div class="stream-row" style="padding:9px 11px;margin-bottom:6px">
        <div style="display:flex;gap:10px;align-items:center">
          <span style="color:var(--${col});font-weight:600;min-width:80px">${esc(j.status)}</span>
          <span style="flex:1">${esc(j.name)}</span>
          ${["queued","waiting","running"].includes(j.status)
            ? `<button class="item-cancel" onclick="fetch('/api/remux/cancel/${j.id}',{method:'POST'})">✕</button>`:``}
        </div>
        <div style="color:var(--dim);font-size:12px;margin-top:3px">${esc(j.last_log||"")}</div>
        ${bar}
      </div>`;
    }).join("");
  // Un fallo aqui NO debe romper el sondeo -se reintenta en 2 s-, pero
  // tampoco puede ser invisible: sin esta linea, un endpoint roto deja la
  // pestana con datos viejos y no hay absolutamente nada que mirar.
  }catch(e){ console.warn('[remux] fallo al pintar:', e); }
}
// Sondeo consciente de la pestaña, como sync/audio/subs. Antes iba a 3 s FIJOS
// estuvieras donde estuvieras, y no es gratis: /api/remux/status comprueba si el
// pipeline.lock lo tiene un proceso vivo, o sea justo mientras la máquina está
// encodeando. Cada 3 s, todo el día, para pintar una lista que casi nunca se
// mira. En la pestaña Remux sigue a 3 s; fuera, cada 15.
let _rmxTick=0;
// ── SANEAR ───────────────────────────────────────────────────────────────────
// El boton es DIRECTO: no obliga a analizar antes. Analizar esta ahi para
// mirarlo cuando quieras, no como peaje.
function sanPinta(d, corriendo){
  const host=document.getElementById("san-out");
  if(!d && !corriendo){ host.innerHTML=""; return; }
  let h="";
  if(corriendo){
    h+=`<div class="bar" style="margin-bottom:10px"><div class="bar-fill" style="width:${d&&d.pct?d.pct:0}%"></div></div>`;
    h+=`<div style="color:var(--cyan);font-size:13px">Saneando&hellip; ${esc((d&&d.stage)||"")}</div>`;
  }
  const r = d && d.res ? d.res : (d && d.acciones ? d : null);
  if(r){
    if(r.acciones && r.acciones.length){
      h+=`<div style="font-size:13px;margin-top:8px"><b>Qu&eacute; hace:</b><ul style="margin:6px 0 0 18px;padding:0">`+
         r.acciones.map(a=>`<li>${esc(a)}</li>`).join("")+`</ul></div>`;
    }
    if(r.avisos && r.avisos.length){
      h+=`<div style="font-size:13px;margin-top:8px;color:var(--amber)"><b>Avisos:</b><ul style="margin:6px 0 0 18px;padding:0">`+
         r.avisos.map(a=>`<li>${esc(a)}</li>`).join("")+`</ul></div>`;
    }
    if(!corriendo && r.motivo){
      const col = r.ok ? "var(--green)" : "var(--red)";
      h+=`<div style="margin-top:10px;color:${col};font-size:13px"><b>${esc(r.motivo)}</b></div>`;
    }
  }
  host.innerHTML=h;
}
async function sanAnalizar(){
  const path=(document.getElementById("san-file-input").value||"").trim();
  if(!path){ alert("Pon la ruta del fichero"); return; }
  const b=document.getElementById("san-ana-btn");
  b.disabled=true; b.textContent="Analizando...";
  try{
    const r=await fetch("/api/sanear/analizar",{method:"POST",headers:{"Content-Type":"application/json"},
                                               body:JSON.stringify({path})});
    sanPinta(await r.json(), false);
  }catch(e){ document.getElementById("san-out").innerHTML=`<div style="color:var(--red)">Error: ${esc(""+e)}</div>`; }
  finally{ b.disabled=false; b.innerHTML="&#10227; Analizar"; }
}
async function sanRun(){
  const path=(document.getElementById("san-file-input").value||"").trim();
  if(!path){ alert("Pon la ruta del fichero"); return; }
  const b=document.getElementById("san-run-btn");
  b.disabled=true;
  try{
    const r=await fetch("/api/sanear/run",{method:"POST",headers:{"Content-Type":"application/json"},
                                           body:JSON.stringify({path})});
    const d=await r.json();
    if(!d.ok){ alert(d.motivo||"no se pudo lanzar"); b.disabled=false; return; }
    sanPoll();
  }catch(e){ alert("Error: "+e); b.disabled=false; }
}
let _sanCorria=false;
async function sanPoll(){
  try{
    const d=await (await fetch("/api/sanear/status")).json();
    sanPinta(d, d.corriendo);
    document.getElementById("san-run-btn").disabled = !!d.corriendo;
    _sanCorria = d.corriendo;
  // Igual que arriba: se traga el fallo para no romper el sondeo, pero deja
  // rastro en la consola en vez de callar del todo.
  }catch(e){ console.warn('[sanear] sondeo fallido:', e); }
}
setInterval(()=>{ if(currentTab==="remux"||_sanCorria) sanPoll(); },2000);

setInterval(()=>{ _rmxTick++; if(currentTab==="remux"||_rmxTick%5===0) rmxPoll(); },3000);
rmxRenderSlots();
rmxPoll();

