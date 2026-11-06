'use strict';
/* Experimental Flow2 touch editor; firmware owns gesture recognition. */
(()=>{
 const profile=document.querySelector('.keyboard-stage');
 const zoneCount=document.querySelector('#touchPanel .touch-count');
 zoneCount.classList.add('touch-zone-count');zoneCount.hidden=true;
 const activeProfile=document.createElement('span');
 activeProfile.className='touch-active-profile';
 activeProfile.hidden=true;
 activeProfile.setAttribute('role','status');
 profile.querySelector('.stage-actions').append(activeProfile,zoneCount);
 $('touchPanel').querySelector(':scope > .touch-heading').remove();
 const ui={device:null,config:null,mode:0,zone:0,meta:null,busy:false,revision:0,supported:false};
 const profileFirmware=()=>state.caps?.profile?.firmwareVersion==='0.10';
 const actions=[[0,'Unassigned'],...window.flowActions.groups('touch',16,6,true).flatMap(g=>g[1])];
 const presets=[['none','Unassigned',[0,0,0]],['volume','Volume',[1,0,2]],['scroll','Scrolling',[7,0,7]],['screen','Screen brightness',[9,0,10]],['play','Play/pause',[0,4,0]],['mute','Toggle Mute',[0,3,0]],['next','Next track',[0,5,0]],['previous','Previous track',[0,6,0]],...actions.filter(a=>a[0]>=64).map(([id,title])=>['action-'+id,title,[0,id,0]])];
 const contour='<path d="M40 80Q53 82 69 81H931Q947 82 960 80V170Q948 172 933 171H67Q52 172 40 170Z"/><path d="M49 171V177H951V171M58 177V180H70V177M930 177V180H942V177"/><path d="M86 80L98 45Q100 41 106 41L204 43Q210 43 211 48L219 80M226 80L239 45Q241 41 247 41L344 43Q350 43 351 48L360 80M367 80L379 45Q381 41 387 41L485 43Q491 43 492 48L500 80M506 80L519 45Q521 41 527 41L624 43Q630 43 631 48L640 80M646 80L659 45Q661 41 667 41L765 43Q771 43 772 48L780 80M787 80L799 45Q801 41 807 41L904 43Q910 43 911 48L920 80"/><rect x="807" y="115" width="74" height="29" rx="14"/><rect x="811" y="119" width="66" height="21" rx="10"/><rect x="820" y="127" width="48" height="5" rx="2.5"/><path d="M95 178V184Q109 191 125 184V178M778 178L770 192Q768 197 775 197H824L829 192H919V178M829 192V179"/>';
 const tr=s=>window.flowI18n?.translate(s)||s;
 const boundaries=count=>count===3?[25,75]:count===2?[50,75]:[33,67];
 const defaults=(count=1)=>({count,b1:boundaries(count)[0],b2:boundaries(count)[1],actions:[[1,0,2,1,0,2,1,0,2],[9,0,10,9,0,10,9,0,10]]});
 const valid=v=>v&&[1,2,3].includes(v.count)&&Number.isInteger(v.b1)&&Number.isInteger(v.b2)&&v.b1>=15&&v.b1<=85&&v.b2>=30&&v.b2<=85&&(v.count!==3||v.b2>=v.b1+15)&&Array.isArray(v.actions)&&v.actions.length===2&&v.actions.every(a=>Array.isArray(a)&&a.length===9&&a.every(id=>actions.some(x=>x[0]===id)));
 const storageKey=()=>`flow.touch.profiles.v1.${state.selected.model}.${state.selected.serial||'default'}`;
 function storedProfiles(){try{return JSON.parse(localStorage.getItem(storageKey()))||{};}catch{return {};}}
 function remember(){
  const profiles=storedProfiles();
  profiles[ui.config.count]={config:ui.config,meta:ui.meta,mode:ui.mode};
  try{localStorage.setItem(storageKey(),JSON.stringify(profiles));}catch{}
 }
 function useConfig(config,stored){
  ui.config=structuredClone(config);ui.zone=Math.min(ui.zone,config.count-1);
  ui.mode=stored?.mode===1?1:0;
  readMeta(stored?.meta);
 }
 function status(text,phase='saved'){$('touchStatus').textContent=tr(text);$('touchStatus').parentElement.dataset.phase=phase;}
 function active(){return !!state.selected&&state.selected.id===ui.device&&state.tab==='touch';}
 function current(){return ui.meta[ui.mode][ui.zone];}
 function mappings(){return ui.config.actions[ui.mode].slice(ui.zone*3,ui.zone*3+3);}
 function readMeta(stored){
  ui.meta=[[],[]];
  for(let m=0;m<2;m++)for(let z=0;z<3;z++){
   const mapping=ui.config.actions[m].slice(z*3,z*3+3),preset=presets.find(p=>p[2].every((id,i)=>id===mapping[i]));
   const old=stored?.[m]?.[z];
   ui.meta[m][z]=old&&typeof old.advanced==='boolean'&&presets.some(p=>p[0]===old.preset)&&Array.isArray(old.custom)&&old.custom.length===3&&old.custom.every(id=>actions.some(x=>x[0]===id))?old:{advanced:!preset,preset:preset?.[0]||'none',custom:mapping};
   if(!ui.meta[m][z].advanced&&presets.find(p=>p[0]===ui.meta[m][z].preset)[2].some((id,i)=>id!==mapping[i]))ui.meta[m][z]={advanced:!preset,preset:preset?.[0]||'none',custom:mapping};
  }
 }
 function bounds(){
  const {count,b1,b2}=ui.config;
  return count===1?[0,100]:count===2?[0,b1,100]:[0,b1,b2,100];
 }
 let test=null,windowVisible=true,position=0,hideMarker;
 const liveSupported=()=>ui.supported&&profileFirmware();
 const visible=()=>windowVisible&&active()&&!document.hidden&&!state.settings&&!state.about;
 const editable=()=>ui.supported&&!ui.busy&&!state.busy&&!test;
 function showDetection(){
  const marker=$('keyboard').querySelector('.touch-contact');
  if(!marker)return;
  marker.hidden=!position;
  if(position)marker.style.left=(100-(position-1)*100/49)+'%';
 }
 function clearMarker(){clearTimeout(hideMarker);position=0;showDetection();}
 function testStatus(text=''){
  const label=$('touchLiveStatus');label.textContent=tr(text);label.hidden=!text;
 }
 function finishTest(session){
  if(test!==session)return;
  clearTimeout(session.timer);
  test=null;clearMarker();testStatus();render();
 }
 async function stopTest(session=test){
  if(!session||test!==session)return;
  if(session.phase==='starting'){session.cancel=true;return;}
  if(session.phase==='stopping')return;
  if(state.selected?.id!==session.device){finishTest(session);return;}
  session.phase='stopping';clearMarker();clearTimeout(session.timer);render();
  try{
   await rpc('touchLive',{enabled:false});
   finishTest(session);
  }catch{
   if(test!==session)return;
   // The device drops the test at 60 seconds even when Stop cannot reach it.
   session.phase='retry';
   testStatus('The keyboard did not confirm. The test will end automatically.');
   render();
   session.timer=setTimeout(()=>finishTest(session),Math.max(0,session.safeUntil-Date.now()));
  }
 }
 async function startTest(){
  if(!editable()||!liveSupported()||!visible())return;
  const session={device:ui.device,phase:'starting'};
  test=session;testStatus();render();
  try{
   await rpc('touchLive',{enabled:true});
   if(test!==session)return;
   session.phase='running';
   session.safeUntil=Date.now()+61000;
   if(session.cancel||!visible()){void stopTest(session);return;}
   session.timer=setTimeout(()=>void stopTest(session),50000);
   render();
  }catch{
   if(test!==session)return;
   finishTest(session);
   testStatus('Touch position unavailable.');
  }
 }
 function stopWhenHidden(){
  if(!test)return;
  if(state.selected?.id!==test.device){finishTest(test);return;}
  if(!visible()&&test.phase!=='retry')void stopTest();
 }
 $('touchTestStart').onclick=()=>void startTest();
 $('touchTestStop').onclick=()=>void stopTest();

 function draw(){
  if(state.tab!=='touch'||!state.selected)return;
  $('toggleHighlights').hidden=true;$('stageModel').textContent='FLOW 2 / '+state.selected.model;
  $('keyboard').innerHTML=`<div class="touch-picture"><svg viewBox="0 0 1000 244" role="img" aria-label="Lofree Flow 2, touch panel side">${contour}<g class="touch-fn-marker" ${ui.mode===1?'':'hidden'}><rect x="95" y="101" width="65" height="49" rx="7"/><text x="127.5" y="133" text-anchor="middle" stroke="none" fill="currentColor" font-size="23" font-family="-apple-system,sans-serif">Fn</text></g></svg><div class="touch-strip"><div class="touch-zones"><span class="touch-contact" aria-hidden="true" hidden></span></div><div class="touch-boundaries"></div></div></div>`;
  const zones=$('keyboard').querySelector('.touch-zones'),handles=$('keyboard').querySelector('.touch-boundaries');
  const b=bounds();
  for(let z=0;z<ui.config.count;z++){
   const button=document.createElement('button');button.type='button';button.className='touch-zone';button.style.left=(100-b[z+1])+'%';button.style.width=(b[z+1]-b[z])+'%';button.textContent=String(z+1);button.setAttribute('aria-label',tr('Zone')+' '+(z+1));button.setAttribute('aria-pressed',String(z===ui.zone));button.disabled=!editable();
   button.onclick=()=>{if(!editable())return;ui.zone=z;render();draw();};zones.append(button);
  }
  for(let i=1;i<ui.config.count;i++){
   const line=document.createElement('span');line.className='touch-divider';line.style.left=(100-b[i])+'%';zones.append(line);
   const input=document.createElement('input');input.type='range';input.min=i===1?15:ui.config.b1+15;input.max=i===1?(ui.config.count===3?ui.config.b2-15:85):85;input.value=b[i];input.step=1;input.className='touch-boundary';
   // Each handle owns its real min/max domain. Its track is positioned so the
   // thumb remains aligned with the boundary throughout its domain.
   const min=Number(input.min),max=Number(input.max);input.style.left=`calc(${100-max}% - 7px)`;input.style.width=`calc(${max-min}% + 14px)`;
   input.setAttribute('aria-label',tr('Zone boundary')+' '+i);input.disabled=!editable();
   input.oninput=()=>{if(!editable())return;ui.config[i===1?'b1':'b2']=Number(input.value);line.style.left=(100-Number(input.value))+'%';const all=zones.querySelectorAll('.touch-zone'),bb=bounds();all.forEach((e,z)=>{e.style.left=(100-bb[z+1])+'%';e.style.width=(bb[z+1]-bb[z])+'%';});render();};input.onchange=()=>void apply();handles.append(input);
  }
  if(ui.config.count>1){
   const reset=document.createElement('button');
   reset.type='button';reset.className='quiet icon-button touch-reset-zones';
   reset.title=tr('Reset zone boundaries');reset.setAttribute('aria-label',reset.title);
   reset.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 11a8 8 0 1 1 2 6m-2-6V5m0 6h6"/></svg>';
   reset.disabled=!editable();
   reset.onclick=()=>{if(!editable())return;[ui.config.b1,ui.config.b2]=boundaries(ui.config.count);draw();void apply();};
   $('keyboard').querySelector('.touch-picture').append(reset);
  }
  showDetection();
 }
 function render(){
  if(!ui.config||!ui.meta)return;
  const z=current(),p=presets.find(p=>p[0]===z.preset),b=bounds();
  $('touchZoneTitle').textContent=tr('Zone')+' '+(ui.zone+1);$('touchZoneRange').textContent=b[ui.zone]+'–'+b[ui.zone+1]+'%';
  $('touchSimple').value=z.preset;$('touchAdvanced').checked=z.advanced;
  $('touchSimplePane').hidden=z.advanced;$('touchAdvancedPane').hidden=!z.advanced;
  $('touchAutoHint').textContent=p[2][0]||p[2][2]?tr('Swipe up / down'):p[2][1]?tr('Tap'):tr('Unassigned');
  ['Up','Tap','Down'].forEach((name,i)=>{$('touch'+name).value=mappings()[i];});
  activeProfile.hidden=state.tab!=='touch'||!ui.supported||!profileFirmware();
  activeProfile.textContent=tr('Active profile: %u').replace('%u',ui.config.count);
  document.querySelectorAll('[data-touch-count]').forEach(e=>e.setAttribute('aria-pressed',String(Number(e.dataset.touchCount)===ui.config.count)));
  document.querySelectorAll('[data-touch-mode]').forEach(e=>e.setAttribute('aria-pressed',String(Number(e.dataset.touchMode)===ui.mode)));
  $('touchRetry').textContent=tr('Check connection');
  const enabled=editable();
  $('touchPanel').querySelector('.touch-config').toggleAttribute('data-testing',!!test);
  $('touchPanel').querySelectorAll('select,input,[data-touch-mode]').forEach(e=>e.disabled=!enabled);
  profile.querySelectorAll('[data-touch-count],.touch-zone,.touch-boundary,.touch-reset-zones').forEach(e=>e.disabled=!enabled);
  $('touchTestStart').hidden=!!test;
  $('touchTestStart').disabled=!enabled||!liveSupported();
  $('touchTestStop').hidden=!test;
  $('touchTestStop').disabled=test?.phase==='starting'||test?.phase==='stopping';
  $('touchRetry').disabled=ui.busy||state.busy||!!test;
  window.syncSelects?.();
 }
 let confirmed=null;
 async function load(){
  if(!state.selected||state.tab!=='touch'||ui.busy||test)return;
  const device=state.selected.id;
  if(ui.device!==device){ui.zone=0;$('touchLiveStatus').hidden=true;clearMarker();}
  ui.device=device;ui.supported=false;
  const cached=state.caps?.touch;
  useConfig(valid(cached)?cached:defaults(),storedProfiles()[cached?.count]);
  ui.revision++;ui.busy=true;fillOptions();draw();status('Reading settings…','applying');
  try{
   let value=await rpc('readTouch');
   if(device!==state.selected?.id)return;
   if(!valid(value))throw Error('Invalid Touch Bar configuration.');
   const local=storedProfiles();
   if(profileFirmware()&&Number.isInteger(value.savedProfiles)){
    for(const count of [1,2,3]){
     const config=local[count]?.config;
     if((value.savedProfiles&(1<<(count-1)))||!valid(config)||config.count!==count)continue;
     const saved=await rpc('importTouchProfile',config);
     if(device!==state.selected?.id)return;
     if(count===value.count&&valid(saved))value=saved;
    }
   }
   useConfig(value,local[value.count]);ui.supported=true;confirmed=structuredClone(value);
   if(state.caps)state.caps.touch=structuredClone(value);
   remember();status('Settings loaded.');
  }catch(e){
   if(device===state.selected?.id){
    ui.supported=valid(cached);confirmed=ui.supported?structuredClone(cached):null;
    status(ui.supported?'Last retrieved settings.':e.message,ui.supported?'waiting':'error');
   }
  }finally{
   ui.busy=false;
   if(device===state.selected?.id){render();draw();}
   else if(state.tab==='touch')void load();
  }
 }
 async function apply(){
  if(!editable())return;
  const device=ui.device,desired=structuredClone(ui.config);
  ui.revision++;ui.busy=true;render();status('Applying…','applying');
  try{
   const value=await rpc('setTouch',profileFirmware()?{...desired,keepActive:true}:desired);
   if(device!==state.selected?.id)return;
   if(!valid(value))throw Error('Invalid Touch Bar configuration.');
   ui.config=value;confirmed=structuredClone(value);remember();
   if(state.caps)state.caps.touch=structuredClone(value);
   status(value.queued?'Saved in Studio · will apply when the keyboard responds.':'Applied and verified.',value.queued?'waiting':'saved');
  }catch(e){
   if(device===state.selected?.id){
    if(confirmed)useConfig(confirmed,storedProfiles()[confirmed.count]);
    status(e.message,'error');
   }
  }finally{
   ui.busy=false;
   if(device===state.selected?.id){render();draw();}
   else if(state.tab==='touch')void load();
  }
 }
 function fillOptions(){
  const catalog=window.flowActions.groups('touch',16,6,profileFirmware());
  const presetGroups=[['Volume',presets.filter(p=>['volume','mute'].includes(p[0]))],['Media',presets.filter(p=>['play','next','previous'].includes(p[0]))],['Display',presets.filter(p=>p[0]==='screen')],['Scrolling',presets.filter(p=>p[0]==='scroll')],...catalog.filter(g=>['Touch Bar Profiles','Keys','Macros'].includes(g[0])).map(([label,items])=>[label,items.map(([id,title])=>['action-'+id,title])])];
  window.flowActions.fill($('touchSimple'),presetGroups,[['none','Unassigned']]);
  for(const id of ['touchUp','touchTap','touchDown'])window.flowActions.fill($(id),catalog.filter(g=>id!=='touchTap'||g[0]!=='Scrolling'),[[0,'Unassigned']]);
  render();
 }
 fillOptions();
 window.addEventListener('flow-language',fillOptions);
 document.querySelectorAll('[data-touch-count]').forEach(e=>e.onclick=async()=>{
  if(!editable())return;
  const count=Number(e.dataset.touchCount);
  if(count===ui.config.count&&!profileFirmware())return;
  const saved=storedProfiles()[count];
  if(profileFirmware()){
   const device=ui.device;ui.revision++;ui.busy=true;render();status('Applying…','applying');
   try{
    const value=await rpc('selectTouchProfile',{count});
    if(device!==state.selected?.id)return;
    if(!valid(value)||value.count!==count)throw Error('Invalid Touch Bar configuration.');
    useConfig(value,saved);confirmed=structuredClone(value);remember();
    if(state.caps)state.caps.touch=structuredClone(value);
    status('Applied and verified.');
   }catch(e){if(device===state.selected?.id)status(e.message,'error');}
   finally{ui.busy=false;if(device===state.selected?.id){render();draw();}else if(state.tab==='touch')void load();}
   return;
  }
  useConfig(valid(saved?.config)&&saved.config.count===count?saved.config:defaults(count),saved);
  render();draw();void apply();
 });
 document.querySelectorAll('[data-touch-mode]').forEach(e=>e.onclick=()=>{
  if(!editable())return;
  ui.mode=Number(e.dataset.touchMode);remember();render();draw();
 });
 $('touchSimple').onchange=()=>{if(!editable())return;const z=current();z.preset=$('touchSimple').value;const p=presets.find(p=>p[0]===z.preset);ui.config.actions[ui.mode].splice(ui.zone*3,3,...p[2]);render();void apply();};
 $('touchAdvanced').onchange=()=>{if(!editable())return;const z=current();z.advanced=$('touchAdvanced').checked;if(z.advanced){if(!z.savedCustom)z.custom=mappings();ui.config.actions[ui.mode].splice(ui.zone*3,3,...z.custom);}else{z.custom=mappings();z.savedCustom=true;ui.config.actions[ui.mode].splice(ui.zone*3,3,...presets.find(p=>p[0]===z.preset)[2]);}render();void apply();};
 ['Up','Tap','Down'].forEach((name,i)=>{$('touch'+name).onchange=()=>{if(!editable())return;const z=current();ui.config.actions[ui.mode][ui.zone*3+i]=Number($('touch'+name).value);z.custom=mappings();z.savedCustom=true;void apply();};});
 $('touchRetry').onclick=()=>void load();
 document.addEventListener('visibilitychange',stopWhenHidden);
 window.addEventListener('pagehide',()=>{if(test)void stopTest();});
 document.addEventListener('keydown',event=>{
  if(event.key==='Escape'&&test&&visible()&&!event.defaultPrevented){event.preventDefault();void stopTest();}
 });
 const oldDraw=drawKeyboard;drawKeyboard=function(){
  zoneCount.hidden=state.tab!=='touch';if(zoneCount.hidden)activeProfile.hidden=true;profile.classList.toggle('touch-stage',state.tab==='touch');
  if(state.tab==='touch'&&state.selected){if(!ui.config)useConfig(defaults());draw();}else oldDraw();
 };
 const oldSetTab=setTab;setTab=function(tab){oldSetTab(tab);stopWhenHidden();if(tab==='touch')void load();};
 const oldRender=renderPage;renderPage=function(){
  oldRender();
  stopWhenHidden();
  if(state.tab==='touch'&&state.selected){
   if(ui.device!==state.selected.id&&!ui.busy)void load();
   else{render();draw();}
  }
 };
 const oldReceive=window.flowReceive;window.flowReceive=function(message){
  const result=message.result;
  if(typeof result?.touchLiveWindow==='boolean'){
   windowVisible=result.touchLiveWindow;
   stopWhenHidden();
   return;
  }
  if(result?.touchLivePoint){
   if(test?.phase==='running'&&result.device===test.device&&visible()){
    position=result.touchLivePoint;showDetection();
    clearTimeout(hideMarker);hideMarker=setTimeout(clearMarker,180);
   }
   return;
  }
  oldReceive(message);
  const event=result?.deferredApplied;
  if(event?.action==='setTouch'&&event.device===state.selected?.id&&valid(event.value)){
   if(event.args?.keepActive&&ui.config?.count!==event.value.count){
    if(!event.superseded){const profiles=storedProfiles();profiles[event.value.count]={...profiles[event.value.count],config:event.value};try{localStorage.setItem(storageKey(),JSON.stringify(profiles));}catch{}}
    return;
   }
   if(event.superseded)return;
   if(state.caps)state.caps.touch=structuredClone(event.value);
   if(!ui.busy&&ui.device===event.device){
    ui.revision++;useConfig(event.value,storedProfiles()[event.value.count]);confirmed=structuredClone(event.value);remember();
    status('Pending settings applied and verified.');if(active()){render();draw();}
   }
  }
 };
 let syncing=false,nextSync=0;
 async function syncProfile(){
  if(syncing||Date.now()<nextSync||!visible()||!editable()||!profileFirmware())return;
  const device=ui.device,revision=ui.revision,known=ui.config.count;
  syncing=true;
  try{
   const value=await rpc('syncTouchProfile',{known});
   if(device!==ui.device||revision!==ui.revision||!visible()||!editable()||!valid(value)||value.count===known)return;
   useConfig(value,storedProfiles()[value.count]);confirmed=structuredClone(value);remember();
   if(state.caps)state.caps.touch=structuredClone(value);
   status('Settings loaded.');render();draw();
  }catch{nextSync=Date.now()+8000;}
  finally{syncing=false;}
 }
 setInterval(()=>void syncProfile(),1500);
 window.flowTouchTest={ui,valid,presets,actions,load};
})();
