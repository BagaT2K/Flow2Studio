/* Interface integration tests with an injected native bridge; no hardware. */
const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');
const {JSDOM}=require(process.env.FLOW2_JSDOM||'jsdom');
const root=path.resolve(__dirname,'../resources');
const dom=new JSDOM(fs.readFileSync(path.join(root,'index.html'),'utf8'),{runScripts:'outside-only',url:'file://'+path.join(root,'index.html')});
const w=dom.window,$=id=>w.document.getElementById(id),messages=[];
let inFlight=0;w.confirm=()=>true;
const prefs={theme:'dark',batteryStyle:'both',autoCharge:true,keycaps:{},menuPreviews:{keyboardPercent:'data:image/png;base64,AAAA',keyboardBattery:'data:image/png;base64,BBBB',logo:'data:image/png;base64,CCCC'}};
let devices=[],matrix=Array(75).fill(4),lightingFailure=false,bleFailure=false,bleCapsFailure=false;matrix[44]=79;matrix[59]=81;matrix[74]=80;matrix[70]=82;
let matrices=Array.from({length:6},(_,i)=>i===0?matrix:Array(75).fill(10+i));let macroBytes=new Uint8Array(3156);let profile={rf:true,bluetooth:true,indicatorBrightness:191,timeout:60,touchWake:true,syncBreathing:true,mainBrightness:75,keepAwakeSupported:true,firmwareVersion:"3.11",advancedSupported:true,usbBatteryRefreshSupported:true,animationsSupported:true,zoneAnimationsSupported:true,fillAnimationSupported:true,animationSpeed:1,animationMode:0,bootEntryPreserved:true,syncBrightness:false,lowBatteryThreshold:0,editingSleepSupported:true,fullLightSleepSupported:true,rfLightGateSupported:true,packedStateSupported:true,quietReleaseSupported:true};
w.setInterval=()=>0;
w.webkit={messageHandlers:{flow:{postMessage(message){inFlight++;messages.push(JSON.parse(JSON.stringify(message)));setTimeout(()=>{
 let result,error=null;
 const d=devices.find(d=>d.id===message.device);
 switch(message.action){
 case 'preferences':result=prefs;break;
 case 'savePreferences':Object.assign(prefs,message.args);if(message.args.keycaps){prefs.keycaps={...(prefs.keycaps&&typeof prefs.keycaps==='object'?prefs.keycaps:{}),[d.key]:message.args.keycaps};}result=prefs;break;
 case 'scan':result={devices};break;
 case 'select':result=d;break;
 case 'initializeLayers':result={initialized:true,layers:matrices.map(a=>[...a]),changedLayers:[]};break;
 case 'cachedState':result={caps:null,jobs:[]};break;
 case 'clearDeferred':result={cleared:true};break;
 case 'advanced':profile={...profile,...message.args};result=profile;break;
 case 'status':if(d.connection==='Bluetooth'&&bleFailure){error='Bluetooth battery unavailable';break;}result=d.connection==='Bluetooth'?{valid:true,percent:38,source:'ble-standard',updatedAt:1792764000}:{valid:true,percent:73,power:false};break;
 case 'capabilities':if(d.ble&&(bleCapsFailure||bleFailure)){error='BLE test: no nonce reply';break;}if(d.model!=='68'||!d.vendor){error='Модель пока только для просмотра';break;}result={protocol:12,layers:6,macros:16,macroBytes:3156,brightness:75,effect:0,profileSupported:true,profile};break;
 case 'lighting':if(lightingFailure){error=typeof lightingFailure==='string'?lightingFailure:'Test offline';break;}result=message.args;break;
 case 'readLayer':result={keys:[...matrices[message.args.layer]],layer:message.args.layer};break;
 case 'setLayer':matrices[message.args.layer]=[...message.args.keys];result={keys:[...message.args.keys],layer:message.args.layer};break;
 case 'resetLayer':{const before=[...matrices[message.args.layer]];matrices[message.args.layer]=Array(75).fill(4);result={keys:[...matrices[message.args.layer]],before,layer:message.args.layer};break;}
 case 'setKey':matrices[message.args.layer][message.args.row*15+message.args.col]=message.args.code;result={keys:[...matrices[message.args.layer]],layer:message.args.layer};break;
 case 'profile':profile=message.args;result=profile;break;
 case 'wake':result={online:true};break;
 case 'readMacros':result={data:Buffer.from(macroBytes).toString('base64'),count:16,size:3156};break;
 case 'saveMacros':assert.equal(message.args.expected,Buffer.from(macroBytes).toString('base64'));macroBytes=new Uint8Array(Buffer.from(message.args.data,'base64'));result={data:message.args.data,count:16,size:3156};break;
 case 'resetKeys':case 'resetAll':for(const layer of matrices)layer.fill(4);if(message.action==='resetAll')macroBytes.fill(0);result={reset:true};break;
 default:error='Unknown action';
 }w.flowReceive({id:message.id,result,error});inFlight--;
 },2);}}}};
const delay=ms=>new Promise(r=>setTimeout(r,ms));
async function wait(ms=90){await delay(ms);const deadline=Date.now()+5000;while(inFlight&&Date.now()<deadline)await delay(10);assert.equal(inFlight,0,'Native mock did not settle');await delay(0);}
(async()=>{
 w.eval(fs.readFileSync(path.join(root,'layout68.js'),'utf8'));w.eval(fs.readFileSync(path.join(root,'layouts.js'),'utf8'));for(const script of ['factory-layers.js','session-keys.js','macro-recorder.js','app.js'])w.eval(fs.readFileSync(path.join(root,script),'utf8'));await wait();
 assert.equal($('empty').hidden,false);assert.equal($('devicePage').hidden,true);assert.equal($('brightness').disabled,true);
 devices=[{id:111,key:'one',model:'68',connection:'2.4 ГГц',vendor:true,pid:1},{id:222,key:'two',model:'100',connection:'USB',vendor:true,pid:3}];
 $('scan').click();await wait();assert.equal(w.document.querySelectorAll('.device').length,2);
 w.document.querySelector('.device').click();await wait();
 assert.equal($('devicePage').hidden,false);assert.equal($('batteryValue').textContent,'73%');assert.equal(w.document.querySelector('.key[data-index="43"] text').textContent,'→');assert(!$('keyboard').textContent.includes('pgup'));assert.equal(w.document.querySelectorAll('.select-trigger').length,w.document.querySelectorAll('select').length);
 assert.equal($('brightness').disabled,false);assert.equal(w.document.querySelectorAll('.key').length,68);
 w.document.querySelector('[data-tab="lighting"]').click();$('brightness').value=2;$('effect').value='1';$('brightness').dispatchEvent(new w.Event('input'));$('effect').dispatchEvent(new w.Event('change'));await wait(850);
 const setting=messages.findLast(m=>m.action==='lighting');assert.equal(setting.device,111);assert.equal(setting.args.brightness,2);assert.equal(setting.args.effect,1);assert.equal(setting.args.persist,true);assert(messages.some(m=>m.action==='lighting'&&m.args.persist===false));
 const beforeBurst=messages.filter(m=>m.action==='lighting').length;
 for(const level of [0,1,4]){$('brightness').value=level;$('brightness').dispatchEvent(new w.Event('input'));}
 await wait(850);const burst=messages.filter(m=>m.action==='lighting').slice(beforeBurst);assert.equal(burst.length,2);assert(burst.every(m=>m.args.brightness===4));
 // Exact percent values are accepted and previewed before a drag ends.
 const fineStart=messages.filter(m=>m.action==='lighting').length;
 $('brightness').value=29;$('brightness').dispatchEvent(new w.Event('input'));await wait(125);
 assert(messages.slice().some(m=>m.action==='lighting'&&m.args.brightness===29&&!m.args.persist));
 $('brightness').value=51;$('brightness').dispatchEvent(new w.Event('input'));await wait(125);
 $('brightness').dispatchEvent(new w.Event('change'));await wait(750);
 const fine=messages.filter(m=>m.action==='lighting').slice(fineStart);assert.equal(fine.filter(m=>m.args.persist).length,1);assert.equal(fine.at(-1).args.brightness,51);assert.equal($('brightnessValue').textContent,'51%');
 lightingFailure=true;$('brightness').value=1;$('brightness').dispatchEvent(new w.Event('input'));await wait(850);assert.equal($('error').hidden,false);assert($('lightingStatus').textContent.includes('Не удалось подтвердить'));
 const afterFailure=messages.filter(m=>m.action==='lighting').length;await wait(750);assert.equal(messages.filter(m=>m.action==='lighting').length,afterFailure);lightingFailure=false;
 w.document.querySelector('[data-tab="keys"]').click();await wait();
 assert.equal($('layer').options.length,4);assert.equal(w.document.querySelectorAll('.selectable').length,68);
 w.document.querySelector('.selectable').dispatchEvent(new w.MouseEvent('click',{bubbles:true}));
 $('keyCode').value=5;$('applyKey').click();await wait();assert.equal(matrix[0],5);assert.equal($('undoKey').disabled,false);
 assert.equal(w.document.querySelectorAll('.selectable').length,68);$('undoKey').click();await wait();assert.equal(matrix[0],4);

 // Distinct per-layer fixture verifies that the selected layer, not layer zero, is written.
 $('layer').value=2;$('layer').dispatchEvent(new w.Event('change'));await wait();assert.equal(w.document.querySelector('.selectable text').textContent,'I');
 w.document.querySelector('.selectable').dispatchEvent(new w.MouseEvent('click',{bubbles:true}));
 assert([...$('keyCode').options].some(o=>o.value===String(0x5221)));assert([...$('keyCode').options].some(o=>o.value===String(0x770f)));
 $('keyCode').value=6;$('applyKey').click();await wait();assert.equal(matrices[2][0],6);assert.equal(matrices[0][0],4);
 $('layer').value=0;$('layer').dispatchEvent(new w.Event('change'));await wait();assert.equal(w.document.querySelector('.selectable text').textContent,'A');
 w.document.querySelector('[data-tab="lighting"]').click();$('touchWake').checked=false;$('indicatorRF').checked=false;$('indicatorBT').checked=true;$('indicatorBrightness').value=45;$('idleTimeout').value='0';$('idleTimeout').dispatchEvent(new w.Event('change'));assert.equal($('neverWarning').hidden,false);$('indicatorBrightness').dispatchEvent(new w.Event('input'));$('indicatorBT').dispatchEvent(new w.Event('change'));await wait(350);assert.equal(profile.timeout,60);assert.equal($('idleTimeout').value,'0');$('applyTimeout').click();await wait();assert.equal(profile.touchWake,false);assert.equal(profile.rf,false);assert.equal(profile.indicatorBrightness,45);assert.equal(profile.timeout,0);
 // Auto indicator/panel edits keep an uncommitted timer draft; slider previews are volatile.
 $('idleTimeout').value='custom';$('customTimeout').value=123;$('idleTimeout').dispatchEvent(new w.Event('change'));$('customTimeout').dispatchEvent(new w.Event('input'));
 const countBeforeDraft=messages.filter(m=>m.action==='profile').length;await wait(100);assert.equal(messages.filter(m=>m.action==='profile').length,countBeforeDraft);
 $('syncBreathing').checked=false;$('syncBreathing').dispatchEvent(new w.Event('change'));await wait();assert.equal(profile.syncBreathing,false);assert.equal(profile.timeout,0);assert.equal($('customTimeout').value,'123');assert($('timeoutStatus').textContent.includes('несохранённое'));
 const dragStart=messages.filter(m=>m.action==='profile').length;
 for(const v of [40,50,60,70]){$('indicatorBrightness').value=v;$('indicatorBrightness').dispatchEvent(new w.Event('input'));await delay(35);}
 assert(messages.filter(m=>m.action==='profile').slice(dragStart).some(m=>!m.args.persist));
 $('indicatorBrightness').dispatchEvent(new w.Event('change'));await wait(750);
 const drag=messages.filter(m=>m.action==='profile').slice(dragStart);assert.equal(drag.filter(m=>m.args.persist).length,1);assert.equal(profile.indicatorBrightness,70);assert.equal(profile.timeout,0);
 $('applyTimeout').click();await wait();assert.equal(profile.timeout,123);assert.equal(profile.persist,true);assert.equal($('timeoutStatus').textContent,'Сохранено в клавиатуре.');assert.equal($('applyProfile'),null);
 w.document.querySelector('[data-tab="macros"]').click();assert.equal($('saveMacro').disabled,true);$('readMacros').click();await wait();assert.equal($('saveMacro').disabled,false);
 $('macroText').value='text Hi\nwait 100\ndown LCTRL\ntap C\nup LCTRL';$('saveMacro').click();await wait();assert.equal(macroBytes[0],72);assert($('macroStatus').textContent.includes('Сохранено'));
 const saved=Buffer.from(macroBytes);$('macroSlot').value=1;$('macroSlot').dispatchEvent(new w.Event('change'));$('macroText').value='text Two';$('saveMacro').click();await wait();assert.equal(macroBytes[0],72);assert.notDeepEqual(Buffer.from(macroBytes),saved);
 const beforeInvalid=messages.filter(m=>m.action==='saveMacros').length;$('macroText').value='down LCTRL';$('saveMacro').click();await wait();assert.equal(messages.filter(m=>m.action==='saveMacros').length,beforeInvalid);assert($('error').textContent.includes('up'));
 $('resetKeys').click();await wait();assert.equal(matrices[2][0],4);assert.equal(macroBytes[0],72);
 $('resetAll').click();await wait();assert(macroBytes.every(b=>b===0));$('wakeKeyboard').click();await wait();assert(messages.some(m=>m.action==='wake'));
 $('appSettings').click();$('themeSelect').value='light';$('themeSelect').dispatchEvent(new w.Event('change'));await wait();
 assert.equal(w.document.body.dataset.theme,'light');assert.equal(w.document.documentElement.dataset.theme,'light');assert.equal($('batteryStyle'),null);assert.equal(w.document.querySelectorAll('[data-menu-style]').length,2);assert.equal(w.document.querySelector('[data-menu-style="keyboardBattery"]'),null);assert.equal($('autoCharge').getAttribute('role'),'switch');const trigger=$('themeSelect').parentElement.querySelector('.select-trigger');trigger.click();assert.equal(trigger.getAttribute('aria-expanded'),'true');trigger.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Escape',bubbles:true}));assert.equal(trigger.getAttribute('aria-expanded'),'false');
 w.document.querySelector('[data-menu-style="logo"]').click();await wait();assert.equal(prefs.batteryStyle,'logo');for(const img of w.document.querySelectorAll('[data-menu-image]')){assert.equal(img.src,prefs.menuPreviews[img.dataset.menuImage]);assert.equal(img.hidden,false);assert.equal(img.nextElementSibling.hidden,true);}assert.equal($('keepAwake'),null);$('back').click();w.document.querySelector('[data-caps="black"]').click();await wait();assert.equal(w.document.querySelector('[data-caps="black"]').classList.contains('active'),true);
 w.document.querySelectorAll('.device')[1].click();await wait();assert.equal($('brightness').disabled,true);assert.equal($('applyKey').disabled,true);
 devices.push({id:'bt-example',key:'bt-example',name:'Flow 2 68',model:'68',connection:'Bluetooth',vendor:false});$('scan').click();await wait();w.document.querySelectorAll('.device')[2].click();await wait();assert.equal($('brightness').disabled,true);assert.equal($('error').hidden,true);assert($('lightingStatus').textContent.includes('Настройки этой модели'));assert.equal($('batteryValue').textContent,'38%');assert($('batteryNote').textContent.includes('Получено по Bluetooth'));
 devices.push({id:333,key:'ble-real-shape',name:'Flow2-68@Lofree',model:'68',connection:'Bluetooth',ble:true,vendor:true,pid:0,systemBattery:99});$('scan').click();await wait();bleFailure=true;w.document.querySelectorAll('.device')[3].click();await wait();assert.equal($('brightness').disabled,true);assert.equal($('batteryValue').textContent,'—');assert($('batteryNote').textContent.includes('unavailable'));
 bleFailure=false;bleCapsFailure=true;w.document.querySelectorAll('.device')[3].click();await wait();assert.equal($('brightness').disabled,true);assert.equal($('batteryValue').textContent,'38%');assert.equal($('error').hidden,false);
 bleCapsFailure=false;w.document.querySelectorAll('.device')[3].click();await wait();assert.equal($('brightness').disabled,false);assert.equal($('batteryValue').textContent,'38%');assert.equal($('statusLine'),null);
 $('brightness').value=2;$('brightness').dispatchEvent(new w.Event('input'));await wait(850);assert(messages.some(m=>m.device===333&&m.action==='lighting'&&m.args.brightness===2&&m.args.persist===true));
 assert(!messages.some(m=>m.device==='bt-example'&&['capabilities','lighting','setKey','readLayer'].includes(m.action)));

 w.flowReceive({id:0,result:{battery:{valid:true,percent:37,source:'ble-standard'}},error:null});assert.equal($('batteryValue').textContent,'37%');
 w.flowReceive({id:0,result:{battery:null},error:'No battery response while asleep'});assert.equal($('batteryValue').textContent,'—');assert.equal($('brightness').disabled,false);

 lightingFailure='Клавиатура не ответила на два запроса связи.';const offlineStart=messages.filter(m=>m.action==='lighting').length;$('brightness').value=41;$('brightness').dispatchEvent(new w.Event('change'));await wait(850);assert.equal($('brightness').disabled,false);const offlineEnd=messages.filter(m=>m.action==='lighting').length;assert(offlineEnd>offlineStart);await wait(300);assert.equal(messages.filter(m=>m.action==='lighting').length,offlineEnd);lightingFailure=false;
 w.flowReceive({id:0,result:{editing:{message:'Подсветка спит · удержание связи подтверждено'}}});assert.equal($('editingStatus'),null);assert.equal($('brightness').disabled,false);
 $('editingConnection').checked=false;$('editingConnection').dispatchEvent(new w.Event('change'));await wait();assert(messages.some(m=>m.action==='savePreferences'&&m.args.editingConnection===false));
 devices=[];$('scan').click();await wait();assert.equal($('empty').hidden,false);assert.equal($('devicePage').hidden,true);
 $('appSettings').click();assert(!$('settingsPage').hidden);assert($('empty').hidden);assert.equal(w.document.querySelector('header'),null);assert.equal($('appSettings').closest('aside'),w.document.querySelector('aside'));
 $('about').click();assert(!$('aboutPage').hidden);assert($('settingsPage').hidden);assert($('devicePage').hidden);assert.equal($('aboutTitle').textContent,'Flow2Studio');assert.equal($('aboutGithub').getAttribute('href'),'https://github.com/BagaT2K');assert.equal($('aboutKofi').getAttribute('href'),'https://ko-fi.com/bagat2k/tip');$('aboutGithub').click();$('aboutKofi').click();$('aboutQr').click();await wait();assert(messages.some(m=>m.action==='openExternal'&&m.args.link==='github'));assert.equal(messages.filter(m=>m.action==='openExternal'&&m.args.link==='kofi').length,2);
 $('appSettings').click();assert(!$('settingsPage').hidden);$('back').click();assert(!$('empty').hidden);assert($('aboutPage').hidden);
 assert.equal($('effect').querySelector('[value="6"]').textContent,'Водопад');
 $('appSettings').click();const themeTrigger=$('themeSelect').parentElement.querySelector('.select-trigger'),themeOptions=$('themeSelect-options');
 themeTrigger.click();assert(!themeOptions.hidden);const firstOption=themeOptions.firstElementChild;firstOption.focus();$('themeSelect').dispatchEvent(new w.Event('change'));await wait();assert.equal(themeOptions.firstElementChild,firstOption);assert.equal(w.document.activeElement,firstOption);
 themeTrigger.dispatchEvent(new w.MouseEvent('mousedown',{button:0,bubbles:true,cancelable:true}));themeTrigger.dispatchEvent(new w.MouseEvent('click',{detail:1,bubbles:true}));assert(themeOptions.hidden);assert.equal(themeTrigger.getAttribute('aria-expanded'),'false');
 themeTrigger.click();assert(!themeOptions.hidden);themeTrigger.click();assert(themeOptions.hidden);$('back').click();

 w.flowReceive({id:0,result:{battery:{valid:true,percent:42}}});w.flowReceive({id:0,result:{battery:{pending:true}}});assert.equal($('batteryValue').textContent,'42%');

 assert.equal(messages.some(m=>['install','dfu','firmware','raw','erase','prepareKeyboard','restoreFirmware'].includes(m.action)),false);
 // New animation choices are sent as complete lighting settings; the host
 // settles after its ordinary preview/commit rather than streaming frames.
 devices=[{id:111,key:'one',model:'68',connection:'USB',vendor:true,pid:1}];profile.animationsSupported=true;profile.zoneAnimationsSupported=true;profile.fillAnimationSupported=true;profile.usbBatteryRefreshSupported=true;
 $('scan').click();await wait();w.document.querySelector('.device').click();await wait();w.document.querySelector('[data-tab="lighting"]').click();
 assert.equal($('effect').options.length,7);
 for(const effect of [2,3,4,5,6,0,1]){$('effect').value=String(effect);$('effect').dispatchEvent(new w.Event('change'));await wait(750);assert.equal(messages.filter(m=>m.action==='lighting').at(-1).args.effect,effect);assert.equal(messages.filter(m=>m.action==='lighting').at(-1).args.persist,true);}
 for(const speed of [0,1,2,3]){$('effect').value='5';$('waveSpeed').value=String(speed);$('waveSpeed').dispatchEvent(new w.Event('change'));await wait(750);const args=messages.filter(m=>m.action==='lighting').at(-1).args;assert.equal(args.waveSpeed,speed);assert.equal(args.effectFamily,'zones-v1');}assert(![...$('effect').options].some(o=>/Пульсация|Двойная|Мягкое/.test(o.textContent)));
 const idleAnimationWrites=messages.filter(m=>m.action==='lighting').length;await wait(750);assert.equal(messages.filter(m=>m.action==='lighting').length,idleAnimationWrites);
 profile.animationsSupported=false;profile.zoneAnimationsSupported=false;profile.fillAnimationSupported=false;w.document.querySelector('.device').click();await wait();assert([...$('effect').options].filter(o=>Number(o.value)>1).every(o=>o.disabled));assert.equal($('animationNote'),null);assert.equal($('prepareKeyboard').textContent,'Обновить расширение');
 console.log(JSON.stringify({status:'passed',hardware_tested:false,tests:['Disconnected screen hides device controls','Multiple connections and explicit selection','Overview uses actual base layer, including right-side arrows','Custom dropdowns and switch','Bluetooth view-only without configuration channel','Bluetooth battery remains available when capability query fails', 'BLE controls enabled after capabilities; live lighting targets selected BLE connection', 'Battery update and failed refresh clear stale percentage','Live brightness/effect, coalescing, deferred save and transfer failure','Distinct layer buffers, selected layer assignment, base layer isolation and undo', 'MO layer and macro key assignments', 'Live indicator/panel and separate explicit timeout save; dirty draft preserved','Fine 29/51 percent brightness; throttled volatile preview and one commit on release','Continuous indicator drag previews before release; breathing sync toggle','Separate indicator modes/brightness and never warning', 'Macro text/keys/delay encoding, slot preservation, invalid held-key rejection', 'Factory keys and full settings reset with reread', 'Safe wake request','Light theme, battery mode and manual keycaps','Unverified model remains read-only','Disconnect clears controls','Native-rendered menu assets replace preview fallbacks', 'Editing connection preference and status; missing battery or temporary sleep reply preserves previously verified controls; no write retry loop', 'Regular settings never trigger firmware preparation automatically']},null,2));
 dom.window.close();
})().catch(e=>{console.error(e.stack||e);dom.window.close();process.exitCode=1;});
