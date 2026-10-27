'use strict';
const $=id=>document.getElementById(id);
const keySessions=new Map();
const profileStatusIds=['touchWakeStatus','indicatorStatus'];
let settingsStatusRevision=0;
function settingsStatus(ids,text,phase='saved',revision=null,action=null){
 for(const id of ids){const node=$(id);if(revision!==null&&node.dataset.revision!==String(revision))continue;if(action&&node.dataset.action!==action)continue;node.textContent=text;node.parentElement.dataset.phase=phase;}
}
function beginSettingsStatus(ids,action){const revision=++settingsStatusRevision;for(const id of ids){$(id).dataset.revision=String(revision);$(id).dataset.action=action;}settingsStatus(ids,'Применяем…','applying',revision);return revision;}
function profileResultStatus(value,persist=true){return value.queued?'Сохранено в Studio · применим после ответа клавиатуры.':persist?'Применено, проверено и сохранено.':'Применено к клавиатуре…';}
function profileStatusModules(args,base=state.caps?.profile||{}){
 if(Array.isArray(args.statusModules))return [...new Set(args.statusModules.filter(id=>profileStatusIds.includes(id)))];
 return profileStatusIds.filter(id=>(id==='touchWakeStatus'?['touchWake']:['rf','bluetooth','syncBreathing','indicatorBrightness']).some(field=>args[field]!==undefined&&args[field]!==base[field]));
}
function deferredSettingsStatus(event){
 const a=event.args||event.value||{},aliases={rf:'indicatorRF',bluetooth:'indicatorBT'};
 const ids=event.action==='profile'?(Array.isArray(a.statusModules)?profileStatusModules(a):[...profileWrites.statusScopes.keys()]):event.action==='advanced'?['indicatorStatus']:[];
 for(const id of ids){
  const fields=event.action==='advanced'?['syncBrightness','lowBatteryThreshold']:id==='touchWakeStatus'?['touchWake']:['rf','bluetooth','syncBreathing','indicatorBrightness'];
  if(fields.some(field=>{const node=$(aliases[field]||field),desired=node.type==='checkbox'?node.checked:Number(node.value);return a[field]!==undefined&&a[field]!==desired;}))continue;
  settingsStatus([id],'Ожидавшие настройки применены и проверены.','saved',null,event.action);
  if(event.action==='profile')profileWrites.statusScopes.delete(id);
 }
}

const state={session:null,devices:[],selected:null,caps:null,baseKeys:null,keys:null,key:null,layer:0,tab:'overview',undo:null,prefs:{theme:'dark',batteryStyle:'keyboardPercent',autoCharge:true,keycaps:{}},cachedCapabilities:false,queuedTimeout:null,pending:new Map(),sequence:0,busy:false,settings:false,about:false,macros:null,macroSlot:0,setup:{phase:"idle",info:null,message:"",step:null}};
function rpc(action,args={}){return new Promise((resolve,reject)=>{const id=++state.sequence;const timeout=setTimeout(()=>{state.pending.delete(id);reject(new Error('Операция не завершилась. Обновите устройство.'));},['prepareKeyboard','restoreFirmware','restoreBackup','installOEM14','rollbackOEM14'].includes(action)?600000:180000);state.pending.set(id,{resolve,reject,timeout,device:state.selected?.id});if(window.webkit?.messageHandlers?.flow)window.webkit.messageHandlers.flow.postMessage({id,action,args,device:state.selected?.id});else{clearTimeout(timeout);state.pending.delete(id);reject(new Error('Откройте интерфейс через приложение Flow 2 Studio.'));}});}
window.flowReceive=message=>{if(message.id===0){
 if(message.result?.macroKey){captureMacroKey(message.result.macroKey);return;}
 if(message.result?.macroStopped){if(macroRecording.active)void stopMacroRecording(false,false,message.result.macroStopped.message);return;}

 if(message.result?.connectionsChanged){if(!state.busy)void scan();return;}
 if(message.result?.deferred){renderDeferred(message.result.deferred);return;}
 if(message.result?.deferredError){if(message.result.deferredError.device===state.selected?.id){const event=message.result.deferredError,ids=event.action==='profile'?(Array.isArray(event.args?.statusModules)?profileStatusModules(event.args):[...profileWrites.statusScopes.keys()]):event.action==='advanced'?['indicatorStatus']:[];for(const id of ids)if($(id).parentElement.dataset.phase==='waiting')settingsStatus([id],'Применение приостановлено. '+event.message,'error');error(message.result.deferredError.message);$('deferredText').textContent='Автоматическое применение приостановлено: '+message.result.deferredError.message;}return;}
 if(message.result?.deferredApplied){const event=message.result.deferredApplied;if(event.device!==state.selected?.id)return;state.cachedCapabilities=false;renderPreparation();if(state.caps){if(['profile','advanced'].includes(event.action)){Object.assign(state.caps.profile,event.value);if(event.action==='profile'&&state.queuedTimeout===event.value.timeout)state.queuedTimeout=null;timeoutPreview();}if(event.action==='lighting')Object.assign(state.caps,event.value);if(['setKey','setLayer'].includes(event.action)&&!event.superseded)acceptLayer(event.value.layer,event.value.keys);}deferredSettingsStatus(event);if(!event.superseded){if(event.action==='lighting')$('lightingStatus').textContent='Ожидавшие настройки применены и проверены.';error('');}drawKeyboard();return;}
if(message.result?.editing)return;if(message.result?.preparation){preparationProgress(message.result.preparation);return;}if(message.result?.battery)renderBattery(message.result.battery);else{renderBattery(null);if(message.error)error(message.error);}return;}const pending=state.pending.get(message.id);if(!pending)return;clearTimeout(pending.timeout);state.pending.delete(message.id);if(message.error&&pending.device===state.selected?.id&&/Расширение Studio не подтверждено|Эта команда не поддерживается прошивкой/.test(message.error)){state.caps=null;state.setup.phase='idle';updateEnabled();drawKeyboard();}message.error?pending.reject(new Error(message.error)):pending.resolve(message.result);};
function escapeHTML(text){return String(text).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
function toast(message){$('toast').textContent=message;$('toast').hidden=false;clearTimeout(toast.timer);toast.timer=setTimeout(()=>$('toast').hidden=true,3500);}
function error(message){$('error').textContent=message||'';$('error').hidden=!message;}
async function guarded(operation){if(state.busy)return;state.busy=true;updateEnabled();drawKeyboard();error('');try{await operation();}catch(e){error(e.message);}finally{state.busy=false;updateEnabled();drawKeyboard();}}
function updateEnabled(){for(const option of $('effect').options)if(Number(option.value)>1)option.disabled=Number(option.value)===6?!state.caps?.profile?.fillAnimationSupported:!state.caps?.profile?.zoneAnimationsSupported;$('waveSpeedRow').hidden=Number($('effect').value)<2;$('waveSpeed').disabled=state.busy||!state.caps?.profile?.zoneAnimationsSupported;document.querySelectorAll('[data-tab]').forEach(b=>b.disabled=state.busy);$('appSettings').disabled=state.setup.phase==='working';$('scan').disabled=state.setup.phase==='working';$('rescan').disabled=state.setup.phase==='working';const enabled=!!state.selected&&!!state.caps?.profileSupported&&!state.busy;for(const id of ['brightness','effect','layer','readLayer','resetKeys','resetAll','readMacros'])$(id).disabled=!enabled;for(const id of ['indicatorRF','indicatorBT','indicatorBrightness','idleTimeout','customTimeout','touchWake','syncBreathing','applyTimeout'])$(id).disabled=!enabled||!state.caps?.profileSupported;for(const id of ['macroSlot','macroText','saveMacro','clearMacro'])$(id).disabled=!enabled||!state.macros;for(const id of ['syncBrightness','lowBatteryThreshold'])$(id).disabled=!enabled||!state.caps?.profile?.advancedSupported;$('indicatorBrightness').disabled=!enabled||$('syncBrightness').checked;$('wakeKeyboard').disabled=!state.selected||state.busy;$('applyKey').disabled=!enabled||!state.key||!state.keys;$('keyCode').disabled=!enabled||!state.key;$('undoKey').disabled=!enabled||!currentHistory()?.undo;$('redoKey').disabled=!enabled||!currentHistory()?.redo;for(const id of ['resetLayer','readFn','resetFn','applyFnTemplate','fnLayer','fnTemplate'])$(id).disabled=!enabled;updateHistory();updateRecorderControls();syncSelects();renderPreparation();}
function renderPreferences(){if(window.flowI18n&&Object.prototype.hasOwnProperty.call(window.flowI18n.languages,state.prefs.language))window.flowI18n.setLanguage(state.prefs.language);document.body.dataset.theme=state.prefs.theme;document.documentElement.dataset.theme=state.prefs.theme;document.querySelectorAll('[data-menu-image]').forEach(img=>{const src=state.prefs.menuPreviews?.[img.dataset.menuImage];if(src?.startsWith('data:image/png;base64,')){img.src=src;img.hidden=false;img.nextElementSibling.hidden=true;}});$('themeSelect').value=state.prefs.theme;const menuStyle=state.prefs.batteryStyle==='logo'?'logo':'keyboardPercent';document.querySelectorAll('[data-menu-style]').forEach(b=>b.classList.toggle('active',b.dataset.menuStyle===menuStyle));$('autoCharge').checked=state.prefs.autoCharge;$('editingConnection').checked=state.prefs.editingConnection!==false;$('theme').textContent=state.prefs.theme==='dark'?'☾':'☀';const caps=state.prefs.keycaps?.[state.selected?.key]||'white';document.querySelectorAll('[data-caps]').forEach(b=>b.classList.toggle('active',b.dataset.caps===caps));drawKeyboard();syncSelects();}
async function savePreferences(update){try{state.prefs=await rpc('savePreferences',update);renderPreferences();}catch(e){toast(e.message);}}
function deviceDrawing(device){
 const keys=device.model==='68'?window.flowLayout68:window.flowLayouts?.[device.model];
 if(!keys?.length)return '<svg viewBox="0 0 180 58" role="img" aria-label="Клавиатура"><rect x="1" y="1" width="178" height="56" rx="5" fill="none" stroke="currentColor"/></svg>';
 const pad=15,gutter=50,cols=Math.max(...keys.map(k=>k.x+k.w)),rows=Math.max(...keys.map(k=>k.y+(k.h||1))),w=cols*40+pad*2+gutter,h=rows*40-4+pad*2;
 return `<svg viewBox="0 0 ${w} ${h}" role="img" aria-label="Lofree Flow 2 ${escapeHTML(device.model)}" data-model="${escapeHTML(device.model)}"><rect x="1" y="1" width="${w-2}" height="${h-2}" rx="9" fill="none" stroke="currentColor" stroke-width="3"/>${keys.map(k=>`<rect class="device-key" x="${pad+k.x*40}" y="${pad+k.y*40}" width="${k.w*40-4}" height="${(k.h||1)*40-4}" rx="5" fill="none" stroke="currentColor" stroke-width="2.4"/>`).join('')}<rect x="${w-46.584}" y="${pad+2.4}" width="29.808" height="2.2" rx="1.1" fill="currentColor"/></svg>`;
}
function renderDevices(){const root=$('devices');root.replaceChildren();if(!state.devices.length){const note=document.createElement('p');note.textContent='Пока ничего не подключено';note.className='micro';root.append(note);}state.devices.forEach(device=>{const b=document.createElement('button');b.className='device'+(state.selected?.id===device.id?' active':'');b.innerHTML=`<span class="device-drawing">${deviceDrawing(device)}</span><strong>${device.bootloader?'Восстановление USB':'Flow 2'+(device.model?' / '+escapeHTML(device.model):'')}</strong><small>● ${escapeHTML(device.connection)}${device.vendor?'':' · просмотр'}</small>`;b.addEventListener('click',()=>selectDevice(device));root.append(b);});}
async function scan(){try{const result=await rpc('scan');state.devices=result.devices;if(state.selected&&!state.devices.some(d=>d.id===state.selected.id)){macroRecording.token++;if(macroRecording.active)void stopMacroRecording(true,false,'Запись остановлена: устройство отключено.');cancelLighting();cancelProfile();state.selected=null;state.caps=null;state.baseKeys=null;state.keys=null;state.key=null;renderPage();}renderDevices();}catch(e){}}
function renderPage(){const selected=!!state.selected;$('empty').hidden=selected||state.settings||state.about;$('devicePage').hidden=!selected||state.settings||state.about;$('settingsPage').hidden=!state.settings;$('aboutPage').hidden=!state.about;$('appSettings').setAttribute('aria-pressed',String(state.settings));$('about').setAttribute('aria-pressed',String(state.about));if(!selected){updateEnabled();return;}const d=state.selected;const recovery=!!d.bootloader;document.querySelector('.keyboard-stage').hidden=recovery;$('tabs').hidden=recovery;document.querySelector('.battery-panel').hidden=recovery;document.querySelector('.reset-card').hidden=recovery;document.querySelectorAll('[data-panel]').forEach(p=>p.hidden=recovery||p.dataset.panel!==state.tab);$('keyHistoryBar').hidden=recovery||!['keys','fn'].includes(state.tab);$('deviceTitle').textContent=d.bootloader?'Восстановление USB':'Flow 2'+(d.model?' / '+d.model:'');$('deviceMeta').innerHTML=`<span class="badge">● ${escapeHTML(d.connection)}</span><span>${d.model?escapeHTML(d.model)+' клавиш':'Модель не определена'}</span><span>LOFREE</span>`;$('stageModel').textContent='FLOW 2 / '+(d.model||'—')+(d.model==='68'?(state.baseKeys?' · СЛОЙ 1':' · ЗАВОДСКАЯ СХЕМА'):' · СХЕМА');$('connectionDetails').innerHTML=[['Подключение',d.connection],['Модель',d.model?'Flow 2 '+d.model:'Не определена'],['Управление',state.caps?.profileSupported?(state.cachedCapabilities?'Последние настройки · ожидаем связь':'Доступно')+(d.connection==='Bluetooth'?' · Bluetooth':''):!d.vendor?'Просмотр · нет канала настроек':'Ожидаем проверку'],['Протокол',state.caps?'VIA '+state.caps.protocol:'—']].map(([a,b])=>`<div><dt>${escapeHTML(a)}</dt><dd>${escapeHTML(b)}</dd></div>`).join('');renderPreferences();updateEnabled();}
async function selectDevice(device,{allowCached=true}={}){if(state.busy)return;if(macroRecording.active)await stopMacroRecording();cancelLighting();cancelProfile();state.setup={phase:'idle',info:null,message:'',step:null};state.macros=null;state.macroSlot=0;$('macroSlot').value=0;$('macroText').value='';state.selected=device;const sessionKey=device.key||String(device.id);if(!keySessions.has(sessionKey))keySessions.set(sessionKey,{histories:new Map(),layers:new Map()});state.session=keySessions.get(sessionKey);state.undo=null;state.caps=null;state.baseKeys=null;state.keys=null;state.key=null;state.layer=0;state.settings=false;state.about=false;state.cachedCapabilities=false;state.queuedTimeout=null;$('deferredNotice').hidden=true;for(const id of profileStatusIds){$(id).dataset.revision=String(++settingsStatusRevision);$(id).dataset.action='profile';}settingsStatus(profileStatusIds,'Читаем текущие настройки…','reading');error('');renderDevices();renderPage();renderBattery(null);$('lightingStatus').textContent=device.connection==='Bluetooth'?'Читаем заряд и проверяем канал настроек Bluetooth…':'Читаем текущую яркость и эффект…';$('keyStatus').textContent='Выберите слой и прочитайте его.';await guarded(async()=>{await rpc('select');let cached=null;try{cached=await rpc('cachedState');}catch{}await loadPreparation();if(device.bootloader){renderPage();return;}try{const battery=await rpc('status');renderBattery(battery);}catch(e){renderBattery(null);$('batteryNote').textContent=e.message;}if(!device.vendor){settingsStatus(profileStatusIds,'Канал настроек недоступен · подключите USB или 2.4 ГГц.','waiting');$('lightingStatus').textContent='Настройки этой модели по Bluetooth пока недоступны. Заряд читается отдельно; для настроек подключите USB или приёмник 2.4 ГГц.';renderPage();return;}try{state.caps=await rpc('capabilities');if(state.caps.profileSupported&&state.caps.layers===6){try{const initialized=await rpc('initializeLayers');if(initialized.layers)initialized.layers.forEach((keys,layer)=>state.session.layers.set(layer,[...keys]));}catch(e){error('Не удалось подготовить исходные слои: '+e.message);}}profileUI();$('brightness').value=state.caps.brightness;$('brightnessValue').textContent=state.caps.brightness+'%';$('effect').value=state.caps.effect;$('lightingStatus').textContent='Настройки прочитаны из клавиатуры.';$('layer').replaceChildren();for(let i=0;i<state.caps.layers;i++){const o=document.createElement('option');if(i===1||i===3)continue;o.value=i;o.textContent=layerName(i);$('layer').append(o);}try{state.baseKeys=(await rpc('readLayer',{layer:0})).keys;state.session.layers.set(0,[...state.baseKeys]);}catch(e){error('Не удалось прочитать подписи схемы: '+e.message);}syncRange();syncSelects();}catch(e){if(allowCached&&cached?.caps?.profileSupported){state.caps=cached.caps;if(!state.caps.profile?.zoneAnimationsSupported&&state.caps.effect>1)state.caps.effect=1;state.baseKeys=state.session.layers.get(0)||null;state.cachedCapabilities=true;$('layer').replaceChildren();for(let i=0;i<state.caps.layers;i++){const o=document.createElement('option');if(i===1||i===3)continue;o.value=i;o.textContent=layerName(i);$('layer').append(o);}profileUI();$('brightness').value=state.caps.brightness;$('effect').value=state.caps.effect;syncRange();$('lightingStatus').textContent='Последние прочитанные настройки. Изменения сохранятся до восстановления связи.';error('');}else{settingsStatus(profileStatusIds,'Не удалось прочитать настройки. '+e.message,'error');$('lightingStatus').textContent=e.message;error(e.message);}}try{const saved=await rpc('cachedState');restoreDesired(saved.jobs||[]);}catch{}renderPage();});if(['keys','fn'].includes(state.tab)&&state.caps)readLayer();}
function renderBattery(battery){if(battery?.pending)return;const valid=battery?.valid&&battery.percent>=0&&battery.percent<=100;$('batteryValue').textContent=valid?battery.percent+'%':'—';$('chargingIcon').toggleAttribute('hidden',!battery?.power);$('chargingIcon').setAttribute('aria-label',battery?.power?'Подключено питание':'Заряд батареи');$('batteryNote').textContent=battery?.power?(battery.full?'Питание подключено · заряд полный':valid?'Заряжается':battery.batteryReason==='usb-extension-update'?'Заряжается · обновите расширение для чтения заряда по USB':'Заряжается · ожидаем данные о проценте'):valid?(battery.source==='ble-standard'?'Получено по Bluetooth':'Последний ответ клавиатуры'):'Заряд пока недоступен';}
function renderDeferred(event){if(event.device!==state.selected?.id)return;$('deferredNotice').hidden=!event.count;$('deferredText').textContent=event.paused?'Применение приостановлено. Проверьте сообщение ниже или отмените ожидающие изменения.':`Сохранено в Studio: ${event.count}. Применим после ответа клавиатуры. При глубоком сне нажмите любую её клавишу.`;}
function restoreDesired(jobs){if(!state.caps)return;const statusModules=new Map(jobs.filter(job=>job.action==='profile').map(job=>[job,profileStatusModules(job.args)]));for(const job of jobs){const a=job.args;if(job.action==='setLayer')acceptLayer(a.layer,a.keys);if(job.action==='setKey'&&state.session?.layers.has(a.layer)){const keys=[...state.session.layers.get(a.layer)];keys[a.row*modelShape().cols+a.col]=a.code;acceptLayer(a.layer,keys);}if(job.action==='lighting'){Object.assign(state.caps,a);$('brightness').value=a.brightness;$('effect').value=a.effect;$('waveSpeed').value=String(a.waveSpeed??1);}if(['profile','advanced'].includes(job.action)){Object.assign(state.caps.profile,a);if(job.action==='profile')state.queuedTimeout=a.timeout;}}if(jobs.length){profileUI();for(const job of jobs)if(['profile','advanced'].includes(job.action)){const ids=job.action==='profile'?statusModules.get(job):['indicatorStatus'],revision=beginSettingsStatus(ids,job.action);if(job.action==='profile')for(const id of ids)profileWrites.statusScopes.set(id,revision);settingsStatus(ids,job.error?'Применение приостановлено. '+job.error:'Сохранено в Studio · применим после ответа клавиатуры.',job.error?'error':'waiting');}syncRange();renderDeferred({device:state.selected.id,count:jobs.length,paused:jobs.every(job=>job.error)});if(jobs.some(job=>job.error))error(jobs.filter(job=>job.error).map(job=>job.error).join(' · '));}}
$('clearDeferred').onclick=async()=>{cancelLighting();cancelProfile();try{await rpc('clearDeferred');state.queuedTimeout=null;const cached=await rpc('cachedState');if(cached.caps){state.caps=cached.caps;$('brightness').value=state.caps.brightness;$('effect').value=state.caps.effect;profileUI();syncRange();}toast('Ожидающие изменения отменены');}catch(e){error(e.message);}};

function modelShape(){const model=String(state.selected?.model||'68'),cols=Number(state.caps?.cols)||(model==='100'?18:15),rows=Number(state.caps?.rows)||(model==='68'?5:6);return {rows,cols,positions:rows*cols,macroBytes:Number(state.caps?.macroBytes)||({68:3156,84:2976,100:2760})[model]||3156};}
function factoryLayers(){return state.caps?.profile?.base14||state.selected?.model!=='68'?window.flowFactoryModels?.[state.selected?.model]||window.flowFactoryLayers:window.flowFactoryLayers;}
function fnPosition(base){return factoryLayers()?.[base]?.findIndex(code=>code===0x5220+(base===2?3:1))??70;}
function layout(){if(!state.selected||state.selected.bootloader)return [];return state.selected.model==='68'?window.flowLayout68:window.flowLayouts?.[state.selected.model]||[];}
function currentHistory(){
 if(!state.session||!['keys','fn'].includes(state.tab))return null;
 const key=state.tab+':'+state.layer;
 if(!state.session.histories.has(key))state.session.histories.set(key,new window.FlowSessionHistory());
 return state.session.histories.get(key);
}
let highlightChanges=true;try{highlightChanges=localStorage.getItem('flow.highlightChanges')!=='off';}catch{}
function layerDefault(layer){const factory=factoryLayers();if(!factory?.[layer])return null;if(layer<4)return factory[layer];return factory[0].map((code,i)=>factory[layer][i]>255?factory[layer][i]:code);}
function changedKey(layer,position,code){const baseline=layerDefault(layer);if(!baseline||code===undefined)return false;return code!==baseline[position]&&!(layer>=4&&code===factoryLayers()[layer][position]);}
function resetKeyEditor(){state.key=null;$('keyEditor').hidden=false;$('keyPosition').textContent='Выберите клавишу на схеме.';$('keyCode').replaceChildren(new Option('Выберите клавишу',''));$('keyCode').disabled=true;$('applyKey').disabled=true;}
function label(code){
 if(code===undefined)return '';if(code===0)return 'Отключено';if(code===1)return 'Основной слой';
 if(code>=4&&code<=29)return String.fromCharCode(65+code-4);
 if(code>=30&&code<=38)return String(code-29);if(code===39)return '0';
 if(code>=58&&code<=69)return 'F'+(code-57);if(code>=104&&code<=115)return 'F'+(code-91);
 if(code>=0x7700&&code<0x7710)return 'M'+(code-0x7700+1);if(code===0x5221)return 'Fn';if(code>=0x5220&&code<=0x523f)return 'Fn→'+(code-0x5220+1);
 if(code>=0x5200&&code<=0x521f)return code===0x5200?'Mac':code===0x5202?'Windows':'Слой '+(code-0x5200+1);
 const special={0x00be:'Экран −',0x00bd:'Экран +',0x00b4:'Поиск',0x00ac:'Пред. трек',0x00ae:'Пуск/пауза',0x00ab:'След. трек',0x00a8:'Без звука',0x00aa:'Громк. −',0x00a9:'Громк. +',0x0065:'Меню',0x7013:'NKRO',0x7785:'2.4 ГГц',0x7793:'BT 1',0x7794:'BT 2',0x7795:'BT 3',0x7803:'Свет −',0x7804:'Свет +',0x7c00:'Загрузчик',0x7c03:'Сброс',0x7e07:'Обзор окон',0x7e08:'Блокировка',0x7e0a:'Эффект +',0x7e0d:'Панель',0x7e0e:'Эффект −',0x7e10:'123 / F1'};
 if(state.caps?.profile?.base14){const v14={0x7e01:'BT 1',0x7e02:'BT 2',0x7e03:'BT 3',0x7e04:'2.4 ГГц',0x7e0b:'Обзор окон',0x7e0c:'Блокировка',0x7e0e:'Эффект +',0x7e11:'Панель',0x7e12:'Эффект −',0x7e14:'123 / F1'};if(v14[code])return v14[code];}if(special[code])return special[code];
 if(code>=0x7e00&&code<=0x7e3f)return 'Lofree '+(code-0x7e00);
 return ({40:'Enter',41:'Esc',42:'Backspace',43:'Tab',44:'Space',45:'−',46:'=',47:'[',48:']',49:'\\',50:'#',51:';',52:"'",53:'`',54:',',55:'.',56:'/',57:'Caps',70:'Print',71:'Scroll',72:'Pause',73:'Insert',74:'Home',75:'PgUp',76:'Delete',77:'End',78:'PgDn',79:'→',80:'←',81:'↓',82:'↑',83:'Num',84:'÷',85:'×',86:'−',87:'+',88:'Enter',89:'1',90:'2',91:'3',92:'4',93:'5',94:'6',95:'7',96:'8',97:'9',98:'0',99:'.',127:'Mute',128:'Vol +',129:'Vol −',224:'Ctrl',225:'Shift',226:'Opt',227:'Cmd',228:'Ctrl',229:'Shift',230:'Opt',231:'Cmd'})[code]||'0x'+code.toString(16).toUpperCase();
}
function keyDetail(code){const details={0x7e07:'Обзор окон: Ctrl + ↑ в Mac, Win + Tab в Windows; при переключении числового ряда может отправлять F3',0x7e08:'Заблокировать экран: Ctrl + Cmd + Q в Mac, Win + L в Windows',0x7e0a:'Следующий режим подсветки',0x7e0d:'Включить или выключить боковую сенсорную панель · удерживайте сочетание',0x7e0e:'Предыдущий режим подсветки',0x7e10:'Переключить верхний ряд между цифрами и F1–F12',0x7013:'Переключить NKRO: одновременная регистрация большого числа клавиш'};return (details[code]||label(code))+(code>=0x7e00&&code<=0x7e3f&&!details[code]?' · служебная функция Lofree, точное назначение ещё не подтверждено':'')+' · код 0x'+Number(code).toString(16).toUpperCase().padStart(4,'0');}
function drawKeyboard(){
 const editing=['keys','fn'].includes(state.tab);$('toggleHighlights').hidden=state.tab!=='keys';$('toggleHighlights').setAttribute('aria-pressed',String(highlightChanges));
 const keys=layout();if(!keys.length){$('keyboard').replaceChildren();return;}
 const light=state.prefs.theme==='light',cols=Math.max(...keys.map(k=>k.x+k.w)),rows=Math.max(...keys.map(k=>k.y+(k.h||1)));
 const pad=15,gutter=50,w=cols*40+pad*2+gutter,h=rows*40-4+pad*2;
 const outline=light?'#4b5e56':'#cad2d0',stroke=light?'#81928a':'#a4b0ae',text=light?'#34463d':'#ccd5d2';
 const profile=state.caps?.profile,on=!!state.caps?.profileSupported&&!!profile&&(state.selected.connection==='Bluetooth'?profile.bluetooth:state.selected.connection==='2.4 ГГц'?profile.rf:false);
 const level=on?(profile.syncBrightness?Number(state.caps.brightness)/100:profile.indicatorBrightness/255):0;
 let svg=`<svg viewBox="0 0 ${w} ${h}" role="img" aria-label="Контур Lofree Flow 2 ${escapeHTML(state.selected?.model)}, вид сверху"><rect class="case-outline" x="1" y="1" width="${w-2}" height="${h-2}" rx="9" fill="none" stroke="${outline}" stroke-width="1.65"/>`;
 keys.forEach((key,index)=>{const selected=state.key?.row===key.row&&state.key?.col===key.col;const rawCode=(['keys','fn'].includes(state.tab)?state.keys:state.baseKeys)?.[key.row*modelShape().cols+key.col];const code=rawCode===1?inheritedCode(key):rawCode??(['keys','fn'].includes(state.tab)&&!!factoryLayers()?undefined:key.defaultCode);const empty=editing&&(rawCode===0||(state.tab==='fn'&&rawCode===1));const title=empty?'':state.selected.model!=='68'&&label(code).startsWith('Fn→')?'Fn':label(code);const marked=editing&&state.keys&&(state.tab==='fn'?rawCode>1:highlightChanges&&changedKey(state.layer,key.row*modelShape().cols+key.col,rawCode));const selectable=['keys','fn'].includes(state.tab)&&state.caps?.profileSupported&&state.keys&&!state.busy&&!!factoryLayers();const x=pad+key.x*40,y=pad+key.y*40,kw=key.w*40-4,kh=(key.h||1)*40-4;svg+=`<g class="key ${selectable?'selectable':''} ${marked?'assigned':''} ${selected?'selected':''}" data-index="${index}"><title>${escapeHTML(rawCode===undefined?'Назначение ещё не прочитано':rawCode===1?'Наследует: '+keyDetail(inheritedCode(key)):keyDetail(rawCode))}</title><rect x="${x}" y="${y}" width="${kw}" height="${kh}" rx="5" fill="none" stroke="${stroke}" stroke-width="1.1"/><text x="${x+kw/2}" y="${y+kh/2+3}" text-anchor="middle" font-size="${title.length>7?6:8}" font-family="-apple-system,sans-serif" fill="${text}">${escapeHTML(title==='Space'?'':title)}</text></g>`;});
 // Selected geometry 1: equal visible vertical borders; indicator near top of first row.
 // Fixed right inset and length preserve the same physical indicator across model widths.
 if(['keys','fn'].includes(state.tab))$('stageModel').textContent='FLOW 2 / '+state.selected.model+' · '+layerName(state.layer).toUpperCase();
 const indicatorWidth=29.808,indicatorX=w-31.68-indicatorWidth/2,indicatorY=pad+3.5-1.1;
 svg+=`<g aria-label="Индикатор"><rect class="indicator-track" x="${indicatorX}" y="${indicatorY}" width="${indicatorWidth}" height="2.2" rx="1.1" fill="${light?'#81928a':'#53665c'}"/><rect x="${indicatorX}" y="${indicatorY}" width="${indicatorWidth}" height="2.2" rx="1.1" fill="${light?'#405638':'#d6e5b1'}" opacity="${level}"/></g></svg>`;
 $('keyboard').innerHTML=svg;$('keyboard').querySelectorAll('.selectable').forEach(el=>el.addEventListener('click',()=>chooseKey(keys[Number(el.dataset.index)])));
}

function chooseKey(key){state.key=key;const code=state.keys[key.row*modelShape().cols+key.col];$('keyPosition').textContent=`${layerName(state.layer)} · позиция ${key.row+1}:${key.col+1} · ${keyDetail(code)}`;const select=$('keyCode');select.replaceChildren();const choices=new Map([[0,'Отключить'],[1,'Наследовать основную раскладку'+(code===1?' · '+label(inheritedCode(key)):'')]]);for(let i=4;i<=29;i++)choices.set(i,label(i));for(let i=30;i<=57;i++)choices.set(i,label(i));for(let i=58;i<=69;i++)choices.set(i,'F'+(i-57));for(let i=70;i<=115;i++)choices.set(i,label(i));for(const i of [79,80,81,82,224,225,226,227,228,229,230,231])choices.set(i,label(i));for(let layer=0;layer<(state.caps?.layers||6);layer++)choices.set(0x5220+layer,'Удерживать '+layerName(layer));for(let i=0;i<(state.caps?.macros||0);i++)choices.set(0x7700+i,'Макрос '+(i+1));if(!choices.has(code))choices.set(code,'Текущее: '+keyDetail(code));for(const [value,title]of choices){const option=document.createElement('option');option.value=value;option.textContent=title;select.append(option);}select.value=code;$('keyEditor').hidden=false;updateEnabled();drawKeyboard();syncSelects();}
function layerName(layer){return ({0:'Mac · основной',1:'Fn · Mac',2:'Windows · основной',3:'Fn · Windows',4:'Дополнительный 1',5:'Дополнительный 2'})[layer]||'Слой '+(layer+1);}
function inheritedCode(key){const base=state.layer===3?2:0;return state.session?.layers.get(base)?.[key.row*modelShape().cols+key.col]??factoryLayers()?.[base]?.[key.row*modelShape().cols+key.col]??key.defaultCode;}
function acceptLayer(layer,keys){if(!Array.isArray(keys)||keys.length!==modelShape().positions)return;state.session?.layers.set(layer,[...keys]);if(layer===0)state.baseKeys=[...keys];if(state.layer===layer)state.keys=[...keys];drawKeyboard();}
async function readLayer(){if(!state.caps||state.busy)return;const requested=Number($(state.tab==='fn'?'fnLayer':'layer').value);state.layer=requested;resetKeyEditor();state.keys=state.session?.layers.get(requested)||null;
 await guarded(async()=>{try{if(state.tab==='fn'){const base=requested===3?2:0;try{const parent=await rpc('readLayer',{layer:base});acceptLayer(base,parent.keys);}catch{}}const value=await rpc('readLayer',{layer:requested});if(value.layer!==requested)throw Error('Устройство вернуло другой слой');acceptLayer(requested,value.keys);$('keyStatus').textContent=layerName(requested)+' · выберите клавишу на схеме.';if(state.tab==='fn'){const base=requested===3?2:0,fnCode=state.session.layers.get(base)?.[fnPosition(base)];$('fnStatus').textContent=fnCode!==undefined&&fnCode!==(0x5220+requested)?'Fn на основном слое переназначена. Чтобы использовать этот Fn-слой, назначьте клавише «Удерживать '+layerName(requested)+'».':'Выберите клавишу на схеме для изменения Fn-сочетания.';}}catch(e){if(!state.keys)throw e;$('keyStatus').textContent='Последние прочитанные назначения · изменения сохранятся до связи.';}});drawKeyboard();}
function setTab(tab){if(state.busy)return;if(macroRecording.active&&tab!=='macros')void stopMacroRecording();state.tab=tab;if(['keys','fn'].includes(tab)){state.layer=Number($(tab==='fn'?'fnLayer':'layer').value)||0;state.keys=state.session?.layers.get(state.layer)||null;}document.querySelectorAll('[data-tab]').forEach(b=>b.classList.toggle('active',b.dataset.tab===tab));document.querySelectorAll('[data-panel]').forEach(p=>p.hidden=p.dataset.panel!==tab);$('keyHistoryBar').hidden=!['keys','fn'].includes(tab);$(tab==='fn'?'fnAssignmentHost':'keysAssignmentHost').append($('keyEditor'));resetKeyEditor();drawKeyboard();if(['keys','fn'].includes(tab)&&state.caps)void readLayer();if(tab==='macros'&&state.caps&&!state.macros)void readMacros();}
$('scan').onclick=scan;$('rescan').onclick=scan;$('theme').onclick=()=>savePreferences({theme:state.prefs.theme==='dark'?'light':'dark'});
$('appSettings').onclick=()=>{if(macroRecording.active)void stopMacroRecording();state.about=false;state.settings=true;renderPage();};$('about').onclick=()=>{if(macroRecording.active)void stopMacroRecording();state.settings=false;state.about=true;renderPage();};$('back').onclick=()=>{state.settings=false;renderPage();};
$('themeSelect').onchange=e=>savePreferences({theme:e.target.value});$('autoCharge').onchange=e=>savePreferences({autoCharge:e.target.checked});document.querySelectorAll('[data-menu-style]').forEach(b=>b.onclick=()=>savePreferences({batteryStyle:b.dataset.menuStyle}));
document.querySelectorAll('[data-caps]').forEach(b=>b.onclick=()=>savePreferences({keycaps:b.dataset.caps}));document.querySelectorAll('[data-tab]').forEach(b=>b.onclick=()=>setTab(b.dataset.tab));
const lighting={generation:0,timer:null,settle:null,queued:null,running:false,revision:0};
function syncRange(){$('brightnessValue').textContent=Number($('brightness').value)+'%';$('brightness').style.setProperty('--range-fill',Number($('brightness').value)+'%');}
function cancelLighting(){lighting.generation++;clearTimeout(lighting.timer);clearTimeout(lighting.settle);lighting.queued=null;lighting.timer=null;}
function queueLighting(persist){
 if(!state.caps||state.setup.phase==='working'||!state.selected)return;
 lighting.queued={generation:lighting.generation,device:state.selected.id,revision:lighting.revision,persist,brightness:Number($('brightness').value),effect:Number($('effect').value),waveSpeed:Number($('waveSpeed').value),effectFamily:'zones-v1'};
 void flushLighting();
}
async function flushLighting(){
 if(lighting.running||!lighting.queued)return;
 const change=lighting.queued;lighting.queued=null;lighting.running=true;
 try{
  const value=await rpc('lighting',{brightness:change.brightness,effect:change.effect,waveSpeed:change.waveSpeed,effectFamily:change.effectFamily,persist:change.persist});
  if(change.generation===lighting.generation&&state.selected?.id===change.device&&change.revision===lighting.revision){Object.assign(state.caps,value);$('lightingStatus').textContent=value.queued?'Сохранено в Studio · применим после ответа клавиатуры.':change.persist?'Применено, проверено и сохранено.':'Применено к клавиатуре…';error('');}
 }catch(e){if(change.generation===lighting.generation){cancelLighting();$('lightingStatus').textContent='Не удалось подтвердить изменение. '+e.message;error(e.message);}}
 finally{lighting.running=false;if(lighting.queued)void flushLighting();}
}
function liveLighting(immediate=false){
 syncRange();syncSelects();if(!state.caps||state.busy)return;
 lighting.revision++;$('lightingStatus').textContent='Применяем…';clearTimeout(lighting.settle);
 // Keep at most one transfer in flight; preserve only the most recent choice.
 lighting.queued=null;
 if(immediate){clearTimeout(lighting.timer);lighting.timer=null;queueLighting(false);}else if(!lighting.timer)lighting.timer=setTimeout(()=>{lighting.timer=null;queueLighting(false);},90);
 lighting.settle=setTimeout(()=>queueLighting(true),650);
}
$('brightness').oninput=()=>liveLighting();$('brightness').onchange=()=>{clearTimeout(lighting.timer);clearTimeout(lighting.settle);lighting.timer=null;queueLighting(true);};$('effect').onchange=()=>{updateEnabled();liveLighting(true);};$('waveSpeed').onchange=()=>liveLighting(true);
$('refreshBattery').onclick=()=>guarded(async()=>{try{renderBattery(await rpc('status'));}catch(e){renderBattery(null);throw e;}});$('readLayer').onclick=readLayer;$('layer').onchange=readLayer;
$('applyKey').onclick=()=>guarded(async()=>{if(!state.key||!state.keys)return;const layer=state.layer,key={...state.key},before=[...state.keys],code=Number($('keyCode').value),position=key.row*modelShape().cols+key.col;const value=await rpc('setKey',{layer,row:key.row,col:key.col,code,previous:before[position],expectedCode:before[position]});const after=value.queued?before.map((v,i)=>i===position?code:v):value.keys;acceptLayer(layer,after);if(before[position]!==code)currentHistory().push({kind:'key',layer,row:key.row,col:key.col,before:value.before||before,after:[...after],label:layerName(layer)+' · '+label(before[position])+' → '+label(code)});chooseKey(key);toast(value.queued?'Назначение сохранено в Studio · ожидаем связь':'Назначение сохранено и проверено');});
async function applyHistory(back,count=1){await guarded(async()=>{for(let i=0;i<count;i++){const history=currentHistory();const frame=back?history?.undo:history?.redo;if(frame&&frame.layer!==state.layer)throw Error('История относится к другому слою');if(!frame)break;const expected=back?frame.after:frame.before,target=back?frame.before:frame.after;let value;
 if(frame.kind==='key'){const pos=frame.row*modelShape().cols+frame.col;value=await rpc('setKey',{layer:frame.layer,row:frame.row,col:frame.col,code:target[pos],previous:expected[pos],expectedCode:expected[pos]});const current=state.session.layers.get(frame.layer)||expected;acceptLayer(frame.layer,value.queued?current.map((v,index)=>index===pos?target[pos]:v):value.keys);}
 else{value=await rpc('setLayer',{layer:frame.layer,expected,keys:target});acceptLayer(frame.layer,value.queued?target:value.keys);}
 history.moved(back);resetKeyEditor();toast(value.queued?'Изменение сохранено в Studio · ожидаем связь':back?'Изменение отменено':'Изменение повторено');}});}
function updateHistory(){const history=currentHistory();$('undoKey').title=history?.undo?'Отменить: '+history.undo.label:'Нет изменений этого слоя для отмены';$('redoKey').title=history?.redo?'Повторить: '+history.redo.label:'Нет изменений этого слоя для повтора';}
$('undoKey').onclick=()=>applyHistory(true);$('redoKey').onclick=()=>applyHistory(false);
$('toggleHighlights').onclick=()=>{highlightChanges=!highlightChanges;try{localStorage.setItem('flow.highlightChanges',highlightChanges?'on':'off');}catch{}drawKeyboard();};
async function resetCurrentLayer(){await guarded(async()=>{const layer=state.layer,before=state.keys&&[...state.keys];const value=await rpc('resetLayer',{layer});if(value.cancelled)return;acceptLayer(layer,value.keys);currentHistory().push({kind:'layer',layer,before:value.before||before,after:value.keys,label:'Заводские назначения · '+layerName(layer)});resetKeyEditor();toast('Выбранный слой сброшен и проверен');});}
$('resetLayer').onclick=resetCurrentLayer;$('resetFn').onclick=resetCurrentLayer;$('fnLayer').onchange=readLayer;$('readFn').onclick=readLayer;
$('applyFnTemplate').onclick=()=>guarded(async()=>{if(!state.keys||state.tab!=='fn'||![1,3].includes(state.layer))return;const layer=state.layer,before=[...state.keys],keys=[...factoryLayers()[layer]];if($('fnTemplate').value==='fkeys')for(let col=1;col<=12;col++)keys[col]=57+col;const value=await rpc('setLayer',{layer,expected:before,keys});const after=value.queued?keys:value.keys;acceptLayer(layer,after);currentHistory().push({kind:'layer',layer,before:value.before||before,after,label:'Шаблон '+(window.flowI18n?.sourceText($('fnTemplate').selectedOptions[0])??$('fnTemplate').selectedOptions[0].textContent)+' · '+layerName(layer)});toast(value.queued?'Шаблон сохранён в Studio · ожидаем связь':'Fn-шаблон применён и проверен');});
function profileUI(profile){
 const p=profile||state.caps?.profile;$('waveSpeed').value=String(state.caps?.waveSpeed??p?.animationSpeed??1);
 if(p){$('indicatorRF').checked=p.rf;$('indicatorBT').checked=p.bluetooth;$('touchWake').checked=!!p.touchWake;$('syncBreathing').checked=p.syncBreathing!==false;$('indicatorBrightness').value=p.indicatorBrightness;$('syncBrightness').checked=!!p.syncBrightness;$('lowBatteryThreshold').value=String(p.lowBatteryThreshold||0);
  $('idleTimeout').value=Array.from($('idleTimeout').options).some(o=>o.value===String(p.timeout))?String(p.timeout):'custom';$('customTimeout').value=p.timeout||60;}
 const route=state.selected?.connection;$('indicatorRFRow').hidden=route!=='2.4 ГГц';$('indicatorBTRow').hidden=route!=='Bluetooth';$('advancedNote').textContent=p?.advancedSupported?'Настройки работают в клавиатуре и при закрытом Studio.':'Для порога красного индикатора и синхронизации яркости обновите расширение по USB.';
 settingsStatus(profileStatusIds,state.cachedCapabilities?'Последние прочитанные настройки · ожидаем связь.':p?'Настройки прочитаны из клавиатуры.':'Настройки пока не прочитаны.',state.cachedCapabilities?'waiting':'saved');
 profilePreview();timeoutPreview();updateEnabled();syncSelects();
}
function profilePreview(){$('indicatorManual').classList.toggle('collapsed',$('syncBrightness').checked);$('indicatorManual').setAttribute('aria-hidden',String($('syncBrightness').checked));$('indicatorBrightness').disabled=$('syncBrightness').checked||!state.caps?.profileSupported;const custom=$('idleTimeout').value==='custom';$('customTimeoutRow').hidden=!custom;$('neverWarning').hidden=$('idleTimeout').value!=='0';$('indicatorValue').textContent=Math.round(Number($('indicatorBrightness').value)*100/255)+'%';$('indicatorBrightness').style.setProperty('--range-fill',Math.round(Number($('indicatorBrightness').value)*100/255)+'%');}
function b64bytes(value){return Uint8Array.from(atob(value),c=>c.charCodeAt(0));}
function bytes64(bytes){return btoa(Array.from(bytes,b=>String.fromCharCode(b)).join(''));}
const macroKeyNames={ENTER:40,ESC:41,BACKSPACE:42,TAB:43,SPACE:44,LEFT:80,RIGHT:79,UP:82,DOWN:81,DELETE:76,LCTRL:224,LSHIFT:225,LALT:226,LGUI:227,RCTRL:228,RSHIFT:229,RALT:230,RGUI:231};
function macroKey(name){name=name.toUpperCase();if(macroKeyNames[name])return macroKeyNames[name];if(/^[A-Z]$/.test(name))return name.charCodeAt(0)-61;if(/^[1-9]$/.test(name))return 29+Number(name);if(name==='0')return 39;if(/^F([1-9]|1[0-2])$/.test(name))return 57+Number(name.slice(1));if(/^0X[0-9A-F]{2}$/.test(name)){const v=parseInt(name,16);if(v)return v;}throw Error('Неизвестная клавиша: '+name);}
function macroName(code){for(const [name,value] of Object.entries(macroKeyNames))if(value===code)return name;return code>=4&&code<=29?String.fromCharCode(code+61):code>=30&&code<=38?String(code-29):code===39?'0':code>=58&&code<=69?'F'+(code-57):'0x'+code.toString(16).padStart(2,'0');}
function decodeMacro(bytes){
 let lines=[],text='';const flush=()=>{if(text){lines.push('text '+text);text='';}};
 for(let i=0;i<bytes.length;){const b=bytes[i++];if(b===1){flush();const cmd=bytes[i++];if(cmd>=1&&cmd<=3&&i<bytes.length)lines.push(['','tap ','down ','up '][cmd]+macroName(bytes[i++]));else if(cmd===4){let digits='';while(i<bytes.length&&bytes[i]>=48&&bytes[i]<=57)digits+=String.fromCharCode(bytes[i++]);if(!digits||bytes[i++]!==124)return 'raw '+Array.from(bytes,x=>x.toString(16).padStart(2,'0')).join(' ');lines.push('wait '+digits);}else return 'raw '+Array.from(bytes,x=>x.toString(16).padStart(2,'0')).join(' ');}else if(b>=32&&b<=126)text+=String.fromCharCode(b);else return 'raw '+Array.from(bytes,x=>x.toString(16).padStart(2,'0')).join(' ');}
 flush();return lines.join('\n');
}
function encodeMacro(source){
 const out=[],held=new Set();for(const [index,line] of source.split(/\r?\n/).entries()){
  if(!line.trim())continue;const match=/^(text|tap|down|up|wait|raw)(?: (.*))?$/.exec(line);if(!match)throw Error('Строка '+(index+1)+': неизвестное действие');
  const [,command,value='']=match;
  if(command==='text'){for(const c of value){const b=c.charCodeAt(0);if(b<32||b>126)throw Error('text поддерживает только печатные ASCII-символы');out.push(b);}}
  else if(command==='raw'){if(!/^(?:[0-9a-fA-F]{2})(?:\s+[0-9a-fA-F]{2})*$/.test(value))throw Error('raw: нужны байты hex через пробел');const raw=value.split(/\s+/).map(x=>parseInt(x,16));if(raw.includes(0))throw Error('raw не может содержать нулевой разделитель');out.push(...raw);}
  else if(command==='wait'){const v=Number(value);if(!/^\d+$/.test(value)||v<1||v>60000)throw Error('Задержка: 1–60000 мс');out.push(1,4,...Array.from(String(v),c=>c.charCodeAt(0)),124);}
  else{const code=macroKey(value.trim());if(command==='down'){if(held.has(code))throw Error('Клавиша уже удерживается: '+value);held.add(code);}if(command==='up'){if(!held.delete(code))throw Error('Нет соответствующего down: '+value);}out.push(1,{tap:1,down:2,up:3}[command],code);}
 }if(held.size)throw Error('Добавьте up для удерживаемых клавиш');return Uint8Array.from(out);
}
function parseMacroBuffer(data){const slots=[];let start=0;for(let i=0;i<data.length&&slots.length<16;i++)if(data[i]===0){slots.push(data.slice(start,i));start=i+1;}if(slots.length!==16||data.length!==modelShape().macroBytes||data[data.length-1]!==0)throw Error('Неизвестный формат памяти макросов. Запись отключена.');return {slots,tail:data.slice(start)};}
function showMacro(){if(!state.macros)return;const slot=Number($('macroSlot').value);$('macroText').value=decodeMacro(state.macros.slots[slot]);$('macroStatus').textContent='Макрос '+(slot+1)+' · '+state.macros.slots[slot].length+' байт. Изменения появятся после сохранения.';renderMacroTimeline();updateEnabled();syncSelects();}
async function readMacros(){if(state.macros&&$('macroText').value!==decodeMacro(state.macros.slots[Number($('macroSlot').value)])&&!window.confirm('Перечитать макросы и убрать несохранённые изменения?'))return;await guarded(async()=>{const value=await rpc('readMacros');const raw=b64bytes(value.data);state.macros={...parseMacroBuffer(raw),raw};showMacro();});}
async function resetKeyboard(all){cancelProfile();cancelLighting();await guarded(async()=>{const result=await rpc(all?'resetAll':'resetKeys');if(result.cancelled)return;state.keys=null;state.key=null;state.undo=null;state.session?.histories.clear();state.session?.layers.clear();state.macros=null;resetKeyEditor();state.baseKeys=(await rpc('readLayer',{layer:0})).keys;if(all){state.caps=await rpc('capabilities');$('brightness').value=state.caps.brightness;$('effect').value=state.caps.effect;syncRange();profileUI();}if(['keys','fn'].includes(state.tab)){const value=await rpc('readLayer',{layer:Number($(state.tab==='fn'?'fnLayer':'layer').value)});state.layer=value.layer;state.keys=value.keys;}$('keyStatus').textContent='Заводские назначения всех слоёв восстановлены и проверены.';$('macroText').value='';$('macroStatus').textContent=all?'Макросы очищены. Прочитайте память для редактирования.':'Макросы сохранены.';toast(all?'Настройки сброшены и проверены':'Назначения восстановлены');});}
const profileWrites={generation:0,revision:0,timer:null,settle:null,running:false,queued:null,timeoutOverride:null,statusScopes:new Map()};
function cancelProfile(){profileWrites.generation++;clearTimeout(profileWrites.timer);clearTimeout(profileWrites.settle);profileWrites.timer=null;profileWrites.queued=null;profileWrites.timeoutOverride=null;profileWrites.statusScopes.clear();}
function timeoutValue(){return $('idleTimeout').value==='custom'?Number($('customTimeout').value):Number($('idleTimeout').value);}
function timeoutPreview(){const value=timeoutValue(),saved=state.caps?.profile?.timeout;$('timeoutStatus').textContent=saved===undefined?'Время ещё не прочитано.':value===saved?(state.queuedTimeout===value?'Сохранено в Studio · ожидаем связь.':'Сохранено в клавиатуре.'):'Есть несохранённое изменение времени.';}
function liveProfile(immediate=false,statusId='indicatorStatus'){
 profilePreview();if(!state.caps?.profileSupported||state.busy)return;
 profileWrites.statusScopes.set(statusId,beginSettingsStatus([statusId],'profile'));profileWrites.revision++;profileWrites.queued=null;clearTimeout(profileWrites.settle);
 if(immediate){clearTimeout(profileWrites.timer);profileWrites.timer=null;queueProfile(true);}else if(!profileWrites.timer)profileWrites.timer=setTimeout(()=>{profileWrites.timer=null;queueProfile(false);},90);
 if(!immediate)profileWrites.settle=setTimeout(()=>queueProfile(true),650);
}
function queueProfile(persist=true){
 if(!state.caps?.profileSupported||!state.selected||state.setup.phase==='working')return;
 const timeout=profileWrites.timeoutOverride??state.caps.profile.timeout;
 const statusEntries=[...profileWrites.statusScopes.entries()];
 profileWrites.queued={statusEntries,generation:profileWrites.generation,revision:profileWrites.revision,device:state.selected.id,args:{persist,statusModules:statusEntries.map(([id])=>id),rf:$('indicatorRF').checked,bluetooth:$('indicatorBT').checked,touchWake:$('touchWake').checked,syncBreathing:$('syncBreathing').checked,indicatorBrightness:Number($('indicatorBrightness').value),timeout}};
 void flushProfile();
}
async function flushProfile(){
 if(profileWrites.running||!profileWrites.queued)return;
 const change=profileWrites.queued;profileWrites.queued=null;profileWrites.running=true;
 try{
  const value=await rpc('profile',change.args);
  if(change.generation!==profileWrites.generation||state.selected?.id!==change.device||!state.caps)return;
  state.caps.profile={...state.caps.profile,...value};if(value.queued)state.queuedTimeout=value.timeout;
  if(profileWrites.timeoutOverride===value.timeout)profileWrites.timeoutOverride=null;
  
  for(const [id,revision] of change.statusEntries){settingsStatus([id],profileResultStatus(value,change.args.persist),value.queued?'waiting':'saved',revision);if(!value.queued&&change.args.persist&&profileWrites.statusScopes.get(id)===revision)profileWrites.statusScopes.delete(id);}
  if(value.queued)$('timeoutStatus').textContent='Время сохранено в Studio · ожидаем связь.';else timeoutPreview();drawKeyboard();
 }catch(e){if(change.generation===profileWrites.generation&&change.revision===profileWrites.revision){for(const [id,revision] of change.statusEntries)settingsStatus([id],'Не удалось подтвердить изменение. '+e.message,'error',revision);cancelProfile();error(e.message);timeoutPreview();}}
 finally{profileWrites.running=false;if(profileWrites.queued)void flushProfile();}
}
for(const id of ['indicatorRF','indicatorBT','syncBreathing'])$(id).onchange=()=>liveProfile(true,'indicatorStatus');
$('touchWake').onchange=()=>liveProfile(true,'touchWakeStatus');
$('indicatorBrightness').oninput=()=>liveProfile();$('indicatorBrightness').onchange=()=>liveProfile(true,'indicatorStatus');
$('idleTimeout').onchange=()=>{profilePreview();timeoutPreview();};$('customTimeout').oninput=()=>{profilePreview();timeoutPreview();};
$('applyTimeout').onclick=()=>{const value=timeoutValue();if(!Number.isInteger(value)||value<0||value>3600||($('idleTimeout').value==='custom'&&value===0)){error('Укажите 1–3600 секунд или «Никогда».');return;}profileWrites.timeoutOverride=value;profileWrites.revision++;clearTimeout(profileWrites.timer);clearTimeout(profileWrites.settle);profileWrites.timer=null;$('timeoutStatus').textContent='Сохраняем время…';queueProfile(true);};
$('readMacros').onclick=readMacros;$('macroSlot').onchange=()=>{if(state.macros&&$('macroText').value!==decodeMacro(state.macros.slots[state.macroSlot||0])&&!window.confirm('Изменения макроса не сохранены. Перейти к другому?')){$('macroSlot').value=state.macroSlot||0;syncSelects();return;}state.macroSlot=Number($('macroSlot').value);showMacro();};
$('clearMacro').onclick=()=>{$('macroText').value='';$('macroStatus').textContent='Редактор очищен. Для удаления макроса в клавиатуре нажмите «Сохранить».';renderMacroTimeline();};
$('saveMacro').onclick=()=>guarded(async()=>{if(!state.macros)return;const replacement=encodeMacro($('macroText').value),slot=Number($('macroSlot').value);const slots=state.macros.slots.map((bytes,i)=>i===slot?replacement:bytes);let tail=Array.from(state.macros.tail);while(tail.length&&tail[tail.length-1]===0)tail.pop();const used=slots.reduce((sum,b)=>sum+b.length+1,0)+tail.length;if(used>modelShape().macroBytes-1)throw Error('Макросы не помещаются в память: '+used+' / '+(modelShape().macroBytes-1)+' байт');const next=new Uint8Array(modelShape().macroBytes);let offset=0;for(const bytes of slots){next.set(bytes,offset);offset+=bytes.length+1;}next.set(tail,offset);const value=await rpc('saveMacros',{expected:bytes64(state.macros.raw),data:bytes64(next)});const raw=b64bytes(value.data);state.macros={...parseMacroBuffer(raw),raw};showMacro();$('macroStatus').textContent=value.queued?'Макрос сохранён в Studio · применим после ответа клавиатуры.':'Сохранено и проверено. Назначьте «Макрос '+(slot+1)+'» клавише.';});
$('resetKeys').onclick=()=>resetKeyboard(false);$('resetAll').onclick=()=>resetKeyboard(true);
$('wakeKeyboard').onclick=async()=>{let online=false;await guarded(async()=>{await rpc('wake');online=true;toast('Клавиатура ответила. Настройки можно применять.');});if(online)await selectDevice(state.selected);};
for(let i=0;i<16;i++){const o=document.createElement('option');o.value=i;o.textContent='Макрос '+(i+1);$('macroSlot').append(o);}

const setupPhases={entering:'Подключаемся для подготовки…',reading:'Читаем прошивку клавиатуры', 'checking-backup':'Проверяем вторую копию', 'backup-saved':'Резервная копия сохранена',writing:'Подготавливаем клавиатуру',verifying:'Проверяем результат',rollback:'Восстанавливаем прежнюю прошивку','rollback-verifying':'Проверяем восстановление',reconnecting:'Ожидаем возвращения клавиатуры'};
function preparationProgress(step){if(step.phase==='busy'){toast('Дождитесь завершения подготовки клавиатуры');return;}state.setup.step=step;renderPreparation();}
function renderPreparation(){
 const root=$('preparationCard');root.hidden=!state.selected;if(!state.selected)return;
 const setup=state.setup,info=setup.info||{},phase=setup.phase,ready=phase==='ready',working=phase==='working';
 $('firmwareConfirmation').textContent=state.caps?.profileSupported?(state.cachedCapabilities?'Ранее подтверждена Studio '+(state.caps.profile?.firmwareVersion||'')+' · ожидаем связь':'✓ Прошивка Studio '+(state.caps.profile?.firmwareVersion||'')+' подтверждена клавиатурой'):info.oem14Installed?'Заводская Lofree 0.14 · расширения Studio отключены':'Прошивка Studio не подтверждена · настройки заблокированы';
 $('preparationTitle').textContent=ready?'Клавиатура готова к работе':phase==='restored'?(setup.restoreMode==='oem14'?'Заводская Lofree 0.14 установлена':setup.restoreMode==='factory'?'Оригинальная прошивка восстановлена':'Прежняя прошивка восстановлена'):phase==='failed'?'Подготовка остановлена':state.selected.bootloader?'Восстановление клавиатуры':state.caps?.profileSupported?'Расширенные настройки доступны':'Один раз подготовим клавиатуру.';
 $('preparationDescription').textContent=ready?'Настраивайте её по USB, Bluetooth или через приёмник 2.4 ГГц. Вы можете оставить кабель подключённым или перейти на беспроводное соединение.':phase==='restored'?(setup.restoreMode==='oem14'?'Установлена заводская Lofree 0.14. Для возврата прежней версии выберите сохранённую копию.':setup.restoreMode==='factory'?'Оригинальная прошивка возвращена и проверена. Расширенные настройки Studio отключены.':'Сохранённая прошивка возвращена и проверена. Назначения и функции зависят от этой версии прошивки.'):setup.message||(state.caps?.profileSupported?'Клавиатура уже подготовлена. Настройки доступны через текущее подключение.':info.message)||'Проверяем доступные способы подключения…';
 $('preparationSteps').hidden=ready||phase==='restored'||!!state.caps?.profileSupported;
 $('preparationProgress').hidden=!working;
 const step=setup.step||{},progress=step.total?Math.max(0,Math.min(100,Math.round(100*step.done/step.total))):0;
 $('preparationProgressLabel').textContent=setupPhases[step.phase]||'Проверяем подключение…';$('preparationMeter').style.width=progress+'%';$('preparationProgress').setAttribute('aria-valuenow',progress);
 const needsEditingUpgrade=!!state.caps?.profileSupported&&(state.caps.profile?.firmwareVersion!=='0.9'||!state.caps.profile?.advancedSupported||(state.selected.connection==='USB'&&!state.caps.profile?.usbBatteryRefreshSupported)||!state.caps.profile?.fillAnimationSupported||!state.caps.profile?.bootEntryPreserved||!state.caps.profile?.independentIndicatorSupported||!state.caps.profile?.base14);
 const expanded=working||(setup.expanded??(!state.caps?.profileSupported||needsEditingUpgrade||phase==='failed'||phase==='restored'));setDisclosure($('preparationBody'),expanded);$('togglePreparation').setAttribute('aria-expanded',String(expanded));$('togglePreparation').disabled=working;root.classList.toggle('collapsed',!expanded);
 $('prepareKeyboard').hidden=working||(!needsEditingUpgrade&&(ready||!!state.caps?.profileSupported));$('prepareKeyboard').disabled=state.busy||!info.canPrepare||!info.available;
 if(needsEditingUpgrade&&state.selected.connection==='USB'&&state.caps.profile?.advancedSupported&&!state.caps.profile?.usbBatteryRefreshSupported)$('preparationDescription').textContent='Доступно расширение 0.9: новые анимации и чтение процента заряда по USB. Обновление сохраняет настройки и резервную копию.';
 if(needsEditingUpgrade&&state.caps?.profile?.usbBatteryRefreshSupported&&!state.caps?.profile?.animationsSupported)$('preparationDescription').textContent='Доступно расширение 0.9: волны сверху вниз, снизу вверх, туда-обратно и плавный перелив. Для обновления подключите USB в проводном режиме.';
 if(needsEditingUpgrade&&state.selected.connection==='USB'&&state.caps?.profile?.bootEntryPreserved)$('preparationDescription').textContent='Доступно расширение 0.9: независимый индикатор работает и при выключенной подсветке клавиш.';
 if(state.caps?.profileSupported&&['3.9','3.10'].includes(state.caps.profile?.firmwareVersion))$('preparationDescription').textContent='Доступно исправление 0.9 для входа в загрузчик. Для уже установленного 3.9/3.10 удерживайте Fn, затем левый Shift и нажмите Esc. После появления устройства восстановления можно обновить расширение или вернуть оригинал.';
 if(needsEditingUpgrade&&!state.caps?.profile?.base14)$('preparationDescription').textContent='Переход на Studio 0.9 на официальной базе Lofree 0.14. Перед записью сохраним и проверим текущую прошивку для отката.';
 $('prepareKeyboard').textContent=needsEditingUpgrade?'Обновить расширение':state.selected.bootloader?'Продолжить подготовку':'Подготовить клавиатуру';
 $('restoreFirmware').hidden=!['68','84','100'].includes(state.selected.model)&&!info.recovery; 
 $('restoreBackup').hidden=!['68','84','100'].includes(state.selected.model)&&!info.recovery;$('restoreBackup').disabled=state.busy||!info.canRestore||!(info.wired||info.recovery);$('restoreFirmware').disabled=state.busy||!(info.canRestoreFactory??info.canRestore)||!(info.wired||info.recovery);
 $('installOEM14').hidden=!info.canInstallOEM14;$('installOEM14').disabled=state.busy;
 $('firmwareBackups').hidden=!info.canRestore&&!info.backupExists;$('firmwareBackups').disabled=state.busy;
 $('preparationCableNote').hidden=!working;
 root.classList.toggle('prepared',!!state.caps?.profileSupported&&!working&&!ready&&phase!=='failed');
}
async function loadPreparation(){
 try{state.setup.info=await rpc('preparationStatus');}catch(e){state.setup.info={available:false,message:e.message};}
 renderPreparation();
}
function confirmFirmware(info){
 return new Promise(resolve=>{
  const dialog=$('firmwareDialog'),check=$('firmwareRiskAccepted'),accept=$('firmwareDialogConfirm'),cancel=$('firmwareDialogCancel'),previous=document.activeElement;
  $('firmwareDialogTitle').textContent=info.title;$('firmwareDialogWarning').textContent=info.warning;$('firmwareDialogDetails').textContent=info.details;accept.textContent=info.confirmLabel||'Обновить прошивку';check.checked=false;accept.disabled=true;dialog.hidden=false;
  const finish=value=>{dialog.hidden=true;check.onchange=accept.onclick=cancel.onclick=null;dialog.removeEventListener('keydown',keys);previous?.focus();resolve(value);};
  const keys=e=>{if(e.key==='Escape'){e.preventDefault();finish(false);}else if(e.key==='Tab'){const nodes=[check,cancel,...(!accept.disabled?[accept]:[])],i=nodes.indexOf(document.activeElement);e.preventDefault();nodes[(i+(e.shiftKey?-1:1)+nodes.length)%nodes.length].focus();}};
  check.onchange=()=>{accept.disabled=!check.checked;};accept.onclick=()=>{if(check.checked)finish(true);};cancel.onclick=()=>finish(false);dialog.addEventListener('keydown',keys);cancel.focus();
 });
}
async function prepareKeyboard(restore=false){
 if(state.busy)return;
 if(!state.selected?.bootloader&&['3.9','3.10'].includes(state.caps?.profile?.firmwareVersion)){error('В расширении '+state.caps.profile.firmwareVersion+' нарушен программный вход в загрузчик. Удерживайте Fn, затем левый Shift, затем нажмите Esc. Выберите появившееся устройство восстановления и повторите нужную операцию.');return;}
 cancelProfile();cancelLighting();const original=state.selected,location=original?.usbLocation??original?.location;
 state.busy=true;state.setup.phase='working';state.setup.message='';state.setup.step={phase:'entering',done:0,total:1};error('');updateEnabled();drawKeyboard();renderPreparation();
 let result=null,failure=null;
 const action=restore==='oem14'?'installOEM14':restore==='oem14-rollback'?'rollbackOEM14':restore==='factory'?'restoreFirmware':restore?'restoreBackup':'prepareKeyboard';
 try{result=await rpc(action);if(result?.confirmation){const consent=result.confirmation;if(await confirmFirmware(consent))result=await rpc(action,{confirmationToken:consent.token});else{try{await rpc('cancelFirmwareConfirmation');}catch{}result={cancelled:true};}}}catch(e){failure=e;}
 if(result?.cancelled){state.setup.phase='idle';state.busy=false;updateEnabled();renderPreparation();return;}
 state.setup.step={phase:'reconnecting',done:0,total:1};renderPreparation();
 let fresh=null;
 try{
  for(let attempt=0;attempt<30;attempt++){
   const inventory=await rpc('scan');state.devices=inventory.devices;
   const expectedLocation=result?.location??location;const matches=state.devices.filter(d=>d.connection==='USB'&&(expectedLocation===undefined?(d.bootloader||d.model===original.model):String(d.usbLocation??d.location)===String(expectedLocation)));
   fresh=matches.find(d=>!d.bootloader)||matches.find(d=>d.bootloader);
   if(fresh&&(!fresh.bootloader||(failure&&attempt>=3)))break;
   await new Promise(resolve=>setTimeout(resolve,500));
  }
 }catch(e){failure=failure||e;}
 state.busy=false;state.caps=null;state.selected=null;renderDevices();renderPage();
 if(fresh){if(result?.verified){keySessions.delete(original.key||String(original.id));keySessions.delete(fresh.key||String(fresh.id));}await selectDevice(fresh,{allowCached:false});}
 if(!fresh){error(failure?.message||'Клавиатура пока не вернулась. Оставьте USB подключённым и обновите список устройств.');return;}
 if(failure){state.setup.phase='failed';state.setup.message=failure.message;error(failure.message);}
 else if(restore&&result?.verified&&!fresh.bootloader){state.setup.phase='restored';state.setup.restoreMode=restore;if(restore==='factory'||restore==='oem14'){state.caps=null;state.cachedCapabilities=false;}state.setup.message='';error('');}
 else if(result?.verified&&!fresh.bootloader&&state.caps?.profileSupported){state.setup.phase='ready';state.setup.message='';error('');}
 else{state.setup.phase='failed';state.setup.message='Образ прошивки проверен, но клавиатура ещё не подтвердила расширенные настройки. Оставьте USB подключённым и повторите проверку связи.';error(state.setup.message);}
 await loadPreparation();renderPage();renderPreparation();updateEnabled();
}
$('installOEM14').onclick=()=>prepareKeyboard('oem14');
$('prepareKeyboard').onclick=()=>prepareKeyboard(false);$('restoreFirmware').onclick=()=>prepareKeyboard('factory');$('restoreBackup').onclick=()=>prepareKeyboard('backup');
$('firmwareBackups').onclick=async()=>{try{await rpc('openFirmwareBackups');}catch(e){error(e.message);}};
$('togglePreparation').onclick=()=>{if(state.setup.phase==='working')return;state.setup.expanded=$('togglePreparation').getAttribute('aria-expanded')!=='true';renderPreparation();};

const selects=[];
function syncSelects(){for(const item of selects)item.sync();}
function enhanceSelect(select){
 const wrap=document.createElement('div');wrap.className='studio-select';select.before(wrap);wrap.append(select);select.classList.add('select-source');select.tabIndex=-1;select.setAttribute('aria-hidden','true');
 const trigger=document.createElement('button');trigger.type='button';trigger.className='select-trigger';trigger.setAttribute('aria-haspopup','listbox');trigger.setAttribute('aria-expanded','false');
 const list=document.createElement('div');list.className='select-options';list.id=select.id+'-options';list.setAttribute('role','listbox');list.hidden=true;trigger.setAttribute('aria-controls',list.id);wrap.append(trigger,list);
 let focus=0,optionSignature=null,pointerWasOpen=null;
 function close(){list.hidden=true;trigger.setAttribute('aria-expanded','false');}
 function choose(index){const option=select.options[index];if(!option||option.disabled)return;select.value=option.value;select.dispatchEvent(new Event('change',{bubbles:true}));close();trigger.focus();sync();}
 function sync(){trigger.disabled=select.disabled;trigger.textContent=select.selectedOptions[0]?.textContent||'Выберите';trigger.setAttribute('aria-label',(select.getAttribute('aria-label')||document.querySelector('label[for="'+select.id+'"]')?.textContent||({themeSelect:'Тема',batteryStyle:'Заряд в строке меню'})[select.id]||'Выбор')+': '+trigger.textContent);if(select.disabled)close();const signature=JSON.stringify(Array.from(select.options,o=>[o.value,o.textContent,o.disabled,o.selected]));if(signature===optionSignature)return;optionSignature=signature;const keepFocus=!list.hidden&&list.contains(document.activeElement);const focusedIndex=Array.from(list.children).indexOf(document.activeElement);list.replaceChildren();Array.from(select.options).forEach((option,index)=>{const b=document.createElement('button');b.type='button';b.textContent=option.textContent;b.setAttribute('role','option');b.setAttribute('aria-selected',String(option.selected));b.disabled=option.disabled;b.tabIndex=-1;b.onclick=()=>choose(index);list.append(b);});if(keepFocus)list.children[Math.max(0,focusedIndex)]?.focus();}
 function open(){document.querySelectorAll('.select-options').forEach(el=>{if(el!==list){el.hidden=true;el.previousElementSibling?.setAttribute('aria-expanded','false');}});sync();focus=Math.max(0,select.selectedIndex);list.hidden=false;trigger.setAttribute('aria-expanded','true');list.children[focus]?.focus();}
 trigger.addEventListener('mousedown',e=>{if(e.button!==0)return;pointerWasOpen=!list.hidden;e.preventDefault();});
 trigger.onclick=e=>{const wasOpen=e.detail>0?(pointerWasOpen??!list.hidden):!list.hidden;pointerWasOpen=null;if(wasOpen){close();trigger.focus();}else open();};
 wrap.addEventListener('keydown',e=>{if(e.key==='Escape'){close();trigger.focus();e.preventDefault();}else if(['ArrowDown','ArrowUp','Home','End'].includes(e.key)){e.preventDefault();if(list.hidden)open();else{focus=e.key==='Home'?0:e.key==='End'?select.options.length-1:Math.max(0,Math.min(select.options.length-1,focus+(e.key==='ArrowDown'?1:-1)));list.children[focus]?.focus();}}else if(e.key==='Tab')close();});
 document.addEventListener('click',e=>{if(!wrap.contains(e.target))close();});wrap.addEventListener('focusout',()=>setTimeout(()=>{if(!wrap.contains(document.activeElement))close();},0));
 select.addEventListener('change',sync);new MutationObserver(sync).observe(select,{attributes:true,childList:true,subtree:true});selects.push({sync});sync();
}
document.querySelectorAll('select').forEach(enhanceSelect);
$('appLanguage').closest('.studio-select').setAttribute('data-i18n-skip','');
$('appLanguage').onchange=()=>{const language=$('appLanguage').value;window.flowI18n?.setLanguage(language);void savePreferences({language});};
(async()=>{try{state.prefs=await rpc('preferences');renderPreferences();await scan();setInterval(()=>{if(!state.busy)scan();},4000);}catch(e){}updateEnabled();})();

$('editingConnection').onchange=()=>savePreferences({editingConnection:$('editingConnection').checked});

let advancedRevision=0;
async function saveAdvanced(){if(!state.caps?.profile?.advancedSupported||state.busy)return;const revision=++advancedRevision;const device=state.selected.id,statusRevision=beginSettingsStatus(['indicatorStatus'],'advanced');profilePreview();updateEnabled();const args={persist:true,syncBrightness:$('syncBrightness').checked,lowBatteryThreshold:Number($('lowBatteryThreshold').value)};try{const value=await rpc('advanced',args);if(state.selected?.id!==device||revision!==advancedRevision)return;Object.assign(state.caps.profile,value);settingsStatus(['indicatorStatus'],profileResultStatus(value),value.queued?'waiting':'saved',statusRevision);drawKeyboard();}catch(e){if(state.selected?.id===device&&revision===advancedRevision){settingsStatus(['indicatorStatus'],'Не удалось подтвердить изменение. '+e.message,'error',statusRevision);error(e.message);}}}
$('syncBrightness').onchange=saveAdvanced;$('lowBatteryThreshold').onchange=saveAdvanced;

const macroRecording={active:false,starting:false,token:0,capture:null,native:false,backup:'',lastArrival:0,timer:null,budget:0};
function macroCaptureSource(events){return events.map(e=>e.type==='wait'?'wait '+e.ms:e.type+' '+macroName(e.code)).join('\n');}
function macroTimelineRows(){return $('macroText').value.split(/\r?\n/).filter(line=>line.trim());}
function macroBudget(){if(!state.macros)return 0;const slot=Number($('macroSlot').value);let tail=[...state.macros.tail];while(tail.length&&tail[tail.length-1]===0)tail.pop();return modelShape().macroBytes-1-16-tail.length-state.macros.slots.reduce((sum,bytes,i)=>sum+(i===slot?0:bytes.length),0);}
function macroEncodedSize(events){return events.reduce((sum,e)=>sum+(e.type==='wait'?String(e.ms).length+3:3),0);}
function renderMacroTimeline(){
 const root=$('macroTimeline');root.replaceChildren();const rows=macroTimelineRows();if(!rows.length){const p=document.createElement('p');p.className='micro';p.textContent='Нажатий пока нет. Начните запись или добавьте паузу.';root.append(p);}
 rows.forEach((line,index)=>{const match=/^(wait|tap|down|up|text|raw)\s+(.*)$/.exec(line);const chip=document.createElement('div');chip.className='macro-event';const text=document.createElement('span');
  if(match?.[1]==='wait'){text.textContent='Пауза';chip.append(text);const input=document.createElement('input');input.type='number';input.min='1';input.max='60000';input.value=match[2];input.disabled=macroRecording.active;input.setAttribute('aria-label','Пауза в миллисекундах');input.onchange=()=>{const value=Number(input.value);if(!Number.isInteger(value)||value<1||value>60000){toast('Пауза: 1–60000 мс');return;}const next=macroTimelineRows();next[index]='wait '+value;$('macroText').value=next.join('\n');renderMacroTimeline();};chip.append(input);const unit=document.createElement('span');unit.textContent='мс';chip.append(unit);}
  else {let title=line;if(match&&['tap','down','up'].includes(match[1])){try{title=({tap:'Нажать',down:'↓',up:'↑'})[match[1]]+' '+label(macroKey(match[2]));}catch{}}text.textContent=title;chip.append(text);}
  if(!macroRecording.active){const remove=document.createElement('button');remove.type='button';remove.textContent='×';remove.title='Удалить действие';remove.setAttribute('aria-label','Удалить действие');remove.onclick=()=>{const next=macroTimelineRows();next.splice(index,1);$('macroText').value=next.join('\n');renderMacroTimeline();};chip.append(remove);}root.append(chip);
 });
 try{const events=macroRecording.active?macroRecording.capture?.events:null;const size=events?macroEncodedSize(events)+macroRecording.capture.held.size*3:encodeMacro($('macroText').value).length;$('macroMemory').textContent=`Этот макрос: ${size} / ${Math.max(0,macroBudget())} доступных байт`;}
 catch(e){$('macroMemory').textContent=e.message;}
}
function updateRecorderControls(){const active=macroRecording.active,ready=!!state.macros&&!!state.caps?.profileSupported&&!state.busy;
 $('recordMacro').disabled=!ready||active||macroRecording.starting;$('recordMacro').hidden=active;$('stopMacro').hidden=!active;$('cancelMacro').hidden=!active;$('recordDelays').disabled=active||!ready;
 for(const id of ['macroSlot','saveMacro','clearMacro','macroDelay','addMacroDelay'])$(id).disabled=!ready||active;
 $('readMacros').disabled=!state.caps?.profileSupported||state.busy||active;$('macroText').readOnly=active;document.querySelector('.macro-recorder').classList.toggle('is-recording',active);
}
async function startMacroRecording(){if(macroRecording.active||macroRecording.starting||!state.macros||state.busy)return;macroRecording.starting=true;const token=++macroRecording.token,device=state.selected?.id,slot=Number($('macroSlot').value);updateRecorderControls();
 macroRecording.backup=$('macroText').value;macroRecording.capture=new window.FlowMacroCapture($('recordDelays').checked);macroRecording.budget=macroBudget();macroRecording.native=false;
 try{const result=await rpc('startMacroRecording');if(!result.recording)throw Error('Запись не началась.');macroRecording.native=result.source==='native';}
 catch(e){macroRecording.starting=false;updateRecorderControls();error(e.message);return;}
 if(token!==macroRecording.token||state.tab!=='macros'||state.settings||state.about||state.selected?.id!==device||Number($('macroSlot').value)!==slot){macroRecording.starting=false;updateRecorderControls();try{await rpc('stopMacroRecording');}catch{}return;}
 macroRecording.starting=false;macroRecording.active=true;$('macroText').value='';$('recordingStatus').textContent='Идёт запись. Нажимайте клавиши и сочетания; завершите кнопкой «Остановить запись». Fn обрабатывается самой клавиатурой.';
 macroRecording.timer=setTimeout(()=>void stopMacroRecording(true,false,'Запись остановлена через 5 минут.'),300000);updateRecorderControls();renderMacroTimeline();
}
function captureMacroKey(event){if(!macroRecording.active)return;const capture=macroRecording.capture,snapshot={length:capture.events.length,held:new Set(capture.held),last:capture.last};
 if(!capture.accept(Number(event.code),!!event.down,Number(event.milliseconds)))return;
 if(macroEncodedSize(capture.events)+capture.held.size*3>macroRecording.budget){capture.events.length=snapshot.length;capture.held=snapshot.held;capture.last=snapshot.last;void stopMacroRecording(true,false,'Запись остановлена: доступная память макроса заполнена.');return;}
 macroRecording.lastArrival=performance.now();$('macroText').value=macroCaptureSource(capture.events);renderMacroTimeline();
}
async function stopMacroRecording(send=true,cancel=false,message='Запись готова. Проверьте действия и нажмите «Сохранить макрос».'){
 if(!macroRecording.active)return;macroRecording.active=false;clearTimeout(macroRecording.timer);macroRecording.timer=null;
 const capture=macroRecording.capture;let endTime;if(capture.delays&&capture.held.size&&capture.last!==null){const gap=Math.min(300000,Math.max(0,Math.round(performance.now()-macroRecording.lastArrival)));let waitBytes=0,left=gap;while(left>0){const ms=Math.min(60000,left);waitBytes+=String(ms).length+3;left-=ms;}if(macroEncodedSize(capture.events)+capture.held.size*3+waitBytes<=macroRecording.budget)endTime=capture.last+gap;}
 $('macroText').value=cancel?macroRecording.backup:macroCaptureSource(capture.finish(endTime));$('recordingStatus').textContent=cancel?'Запись отменена. Прежний черновик восстановлен.':message;
 updateRecorderControls();renderMacroTimeline();if(send)try{await rpc('stopMacroRecording');}catch(e){error(e.message);}
}
$('recordMacro').onclick=startMacroRecording;$('stopMacro').onclick=()=>stopMacroRecording();$('cancelMacro').onclick=()=>stopMacroRecording(true,true);
$('macroText').addEventListener('input',renderMacroTimeline);
$('addMacroDelay').onclick=()=>{const value=Number($('macroDelay').value);if(!Number.isInteger(value)||value<1||value>60000){toast('Пауза: 1–60000 мс');return;}$('macroText').value+=($('macroText').value?'\n':'')+'wait '+value;renderMacroTimeline();};
for(const type of ['keydown','keyup'])document.addEventListener(type,event=>{if(!macroRecording.active||macroRecording.native)return;event.preventDefault();event.stopPropagation();if(event.repeat)return;const code=window.flowWebKey(event.code);if(code)captureMacroKey({code,down:type==='keydown',milliseconds:performance.now()});},true);
window.addEventListener('blur',()=>{macroRecording.token++;if(macroRecording.active)void stopMacroRecording(true,false,'Запись остановлена: окно Studio потеряло фокус.');});

function setDisclosure(element,expanded){
 if(element.dataset.expanded===String(expanded))return;
 element.dataset.expanded=String(expanded);element.setAttribute('aria-hidden',String(!expanded));element.inert=!expanded;
 const reduce=window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
 if(!element.animate||reduce){element.hidden=!expanded;return;}
 const height=element.hidden?0:element.getBoundingClientRect().height;
 element._disclosure?.cancel();element.hidden=false;element.style.height='auto';
 const target=expanded?element.getBoundingClientRect().height:0;
 const animation=element.animate([{height:height+'px',opacity:height?1:0},{height:target+'px',opacity:expanded?1:0}],{duration:320,easing:'cubic-bezier(.22,1,.36,1)'});
 element._disclosure=animation;element.style.overflow='hidden';
 animation.onfinish=()=>{if(element._disclosure!==animation)return;element.hidden=!expanded;element.style.overflow='';element.style.height='';element._disclosure=null;};
}

// External destinations are opened by the native app, preserving the local UI.
document.querySelectorAll('[data-external]').forEach(link=>link.addEventListener('click',async event=>{event.preventDefault();try{await rpc('openExternal',{link:link.dataset.external});}catch(e){toast(e.message);}}));
