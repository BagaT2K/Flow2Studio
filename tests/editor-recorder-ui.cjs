const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');const {JSDOM}=require(process.env.FLOW2_JSDOM||'jsdom');const root=path.resolve(__dirname,'../resources');
const dom=new JSDOM(fs.readFileSync(path.join(root,'index.html'),'utf8'),{runScripts:'outside-only',url:'file://'+path.join(root,'index.html')});const w=dom.window,$=id=>w.document.getElementById(id);w.setInterval=()=>0;w.confirm=()=>true;
let connected=true,layers=[],macroBytes=new Uint8Array(3156),messages=[],pending=0,source='native',bulkFailure=false;
const device={id:1,key:'one',model:'68',connection:'USB',vendor:true,pid:1};const profile={rf:true,bluetooth:true,indicatorBrightness:191,timeout:60,touchWake:true,syncBreathing:true,firmwareVersion:'3.11',quietReleaseSupported:true,advancedSupported:true,usbBatteryRefreshSupported:true,animationsSupported:true,animationMode:0,bootEntryPreserved:true,syncBrightness:false,lowBatteryThreshold:0};
w.webkit={messageHandlers:{flow:{postMessage(m){pending++;messages.push(JSON.parse(JSON.stringify(m)));setTimeout(()=>{let result,error=null;switch(m.action){
case'preferences':result={theme:'dark',batteryStyle:'keyboardPercent',autoCharge:true,keycaps:{}};break;
case'scan':result={devices:connected?[device]:[]};break;case'select':result=device;break;case'cachedState':result={caps:null,jobs:[]};break;
case'preparationStatus':result={available:true,canPrepare:true,canRestore:true};break;case'status':result={valid:true,percent:81,power:true};break;
case'capabilities':result={protocol:12,layers:6,macros:16,macroBytes:3156,brightness:75,effect:0,profileSupported:true,profile};break;
case'initializeLayers':layers=w.flowFactoryLayers.map(row=>Array.from(row));for(const layer of [4,5])layers[layer]=layers[0].map((v,i)=>layers[layer][i]>255?layers[layer][i]:v);result={initialized:true,layers,changedLayers:[4,5]};break;
case'readLayer':result={layer:m.args.layer,keys:[...layers[m.args.layer]]};break;
case'setKey':{const before=[...layers[m.args.layer]];const i=m.args.row*15+m.args.col;layers[m.args.layer][i]=m.args.code;result={layer:m.args.layer,keys:[...layers[m.args.layer]],before};break;}
case'setLayer':{if(bulkFailure){error='Слой изменился с момента чтения';break;}const before=[...layers[m.args.layer]];assert.equal(JSON.stringify(before),JSON.stringify(m.args.expected));layers[m.args.layer]=[...m.args.keys];result={layer:m.args.layer,keys:[...m.args.keys],before};break;}
case'resetLayer':{const before=[...layers[m.args.layer]];layers[m.args.layer]=Array.from(w.flowFactoryLayers[m.args.layer]);result={layer:m.args.layer,keys:[...layers[m.args.layer]],before};break;}
case'resetKeys':case'resetAll':layers=w.flowFactoryLayers.map(row=>Array.from(row));result={reset:true};break;
case'readMacros':result={data:Buffer.from(macroBytes).toString('base64')};break;
case'saveMacros':assert.equal(m.args.expected,Buffer.from(macroBytes).toString('base64'));macroBytes=new Uint8Array(Buffer.from(m.args.data,'base64'));result={data:m.args.data};break;
case'startMacroRecording':result={recording:true,source};break;case'stopMacroRecording':result={recording:false};break;
default:error='Unexpected '+m.action;
}w.flowReceive({id:m.id,result,error});pending--;},2);}}}};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));async function settle(){await sleep(70);while(pending)await sleep(10);await sleep(10);}
function clickKey(index=0){w.document.querySelector('.selectable[data-index="'+index+'"]').dispatchEvent(new w.MouseEvent('click',{bubbles:true}));}
(async()=>{
for(const file of ['layout68.js','layouts.js','factory-layers.js','session-keys.js','macro-recorder.js','app.js'])w.eval(fs.readFileSync(path.join(root,file),'utf8'));await settle();w.document.querySelector('.device').click();await settle();
assert(!messages.some(m=>m.action==='prepareKeyboard'));assert.equal($('chargingIcon').hasAttribute('hidden'),false);assert.notEqual(w.getComputedStyle($('chargingIcon')).display,'none');assert.equal($('chargingBolt').hasAttribute('hidden'),false);assert.equal($('batteryValue').textContent,'81%');
w.flowReceive({id:0,result:{battery:{valid:false,percent:255,power:true,batteryReason:'usb-extension-update'}}});assert.equal($('batteryValue').textContent,'—');assert($('batteryNote').textContent.includes('обновите расширение'));assert(!$('chargingIcon').hasAttribute('hidden'));
w.flowReceive({id:0,result:{battery:{valid:true,percent:0,power:true}}});assert.equal($('batteryValue').textContent,'0%');
w.flowReceive({id:0,result:{battery:{valid:true,percent:81,power:false}}});assert.equal($('chargingIcon').hasAttribute('hidden'),true);assert.equal($('chargingIcon').querySelector('rect'),null);
assert.deepEqual(Array.from(w.document.querySelectorAll('[data-tab]'),n=>n.dataset.tab),['overview','lighting','keys','fn','macros']);
w.document.querySelector('[data-tab="keys"]').click();await settle();assert.deepEqual(Array.from($('layer').options,o=>o.value),['0','2','4','5']);assert.equal($('undoKey').disabled,true);
clickKey();$('keyCode').value='5';$('applyKey').click();await settle();clickKey(1);$('keyCode').value='6';$('applyKey').click();await settle();assert.equal(layers[0][0],5);assert.equal(layers[0][1],6);assert.equal($('showKeyHistory'),null);assert(!$('keyEditor').hidden);assert($('undoKey').querySelector('svg'));
$('undoKey').click();await settle();assert.equal(layers[0][1],30);$('undoKey').click();await settle();assert.equal(layers[0][0],41);assert($('undoKey').disabled);assert(!$('redoKey').disabled);$('redoKey').click();await settle();assert.equal(layers[0][0],5);
assert.equal($('keyHistoryList'),null);
// Reset affects one layer and can itself be undone.
const others=JSON.stringify(layers.slice(1));$('resetLayer').click();await settle();assert.equal(layers[0][0],41);assert.equal(JSON.stringify(layers.slice(1)),others);$('undoKey').click();await settle();assert.equal(layers[0][0],5);
// Fn templates use the actual Fn bank; ordinary layers remain untouched.
w.document.querySelector('[data-tab="fn"]').click();await settle();assert.equal($('keyEditor').parentElement.id,'fnAssignmentHost');assert.equal($('fnLayer').value,'1');assert.equal(w.document.querySelector('.selectable[data-index="21"] text').textContent,'');assert($('undoKey').disabled);
const baseBefore=[...layers[0]];$('fnTemplate').value='fkeys';$('applyFnTemplate').click();await settle();for(let col=1;col<=12;col++)assert.equal(layers[1][col],57+col);assert.deepEqual(layers[0],baseBefore);
const count=messages.filter(m=>m.action==='setLayer').length;bulkFailure=true;$('undoKey').click();await settle();assert.equal(messages.filter(m=>m.action==='setLayer').length,count+1);assert(!$('undoKey').disabled);assert(!$('error').hidden);bulkFailure=false;$('undoKey').click();await settle();assert.deepEqual(layers[1],Array.from(w.flowFactoryLayers[1]));
// Recording supports native packets and does not write until Save.
w.document.querySelector('[data-tab="macros"]').click();await settle();assert(!$('recordMacro').disabled);const writes=messages.filter(m=>m.action==='saveMacros').length;$('recordMacro').click();await settle();assert(!$('stopMacro').hidden);assert($('saveMacro').disabled);
for(const event of [{code:224,down:true,milliseconds:1000},{code:6,down:true,milliseconds:1120},{code:6,down:false,milliseconds:1200},{code:224,down:false,milliseconds:1230}])w.flowReceive({id:0,result:{macroKey:event}});
assert.equal(messages.filter(m=>m.action==='saveMacros').length,writes);$('stopMacro').click();await settle();assert.equal($('macroText').value,'down LCTRL\nwait 120\ndown C\nwait 80\nup C\nwait 30\nup LCTRL');assert.equal($('macroTimeline').querySelectorAll('input').length,3);assert(!$('saveMacro').disabled);
const delay=$('macroTimeline').querySelector('input');delay.value='250';delay.dispatchEvent(new w.Event('change'));assert($('macroText').value.includes('wait 250'));
$('saveMacro').click();await settle();assert.equal(messages.filter(m=>m.action==='saveMacros').length,writes+1);assert.equal(macroBytes[0],1);assert.equal(macroBytes[1],2);assert.equal(macroBytes[2],224);assert(Buffer.from(macroBytes).includes(Buffer.from('250|')));
// Cancel restores the draft. Blur balances held keys and stops native capture.
const original=$('macroText').value;$('recordMacro').click();await settle();w.flowReceive({id:0,result:{macroKey:{code:4,down:true,milliseconds:10}}});$('cancelMacro').click();await settle();assert.equal($('macroText').value,original);
$('recordMacro').click();await settle();w.flowReceive({id:0,result:{macroKey:{code:227,down:true,milliseconds:10}}});w.flowReceive({id:0,result:{macroStopped:{message:'lost focus'}}});await settle();assert($('macroText').value.startsWith('down LGUI\n'));assert($('macroText').value.endsWith('up LGUI'));assert(!$('macroMemory').textContent.includes('соответствующего'));assert($('stopMacro').hidden);
// Portable browser path uses physical event codes and suppresses ordinary shortcuts.
source='web';$('recordDelays').checked=false;$('recordMacro').click();await settle();for(const [type,code] of [['keydown','ControlLeft'],['keydown','KeyC'],['keyup','KeyC'],['keyup','ControlLeft']]){const e=new w.KeyboardEvent(type,{code,bubbles:true,cancelable:true});w.document.dispatchEvent(e);assert(e.defaultPrevented);}$('stopMacro').click();await settle();assert.equal($('macroText').value,'down LCTRL\ndown C\nup C\nup LCTRL');
w.document.querySelector('[data-tab="fn"]').click();await settle();$('resetKeys').click();await settle();assert.equal(messages.filter(m=>m.action==='readLayer').at(-1).args.layer,1);const resetBase=[...layers[0]];$('fnTemplate').value='fkeys';$('applyFnTemplate').click();await settle();assert.equal(messages.filter(m=>m.action==='setLayer').at(-1).args.layer,1);assert.deepEqual(layers[0],resetBase);
w.document.querySelector('[data-tab="macros"]').click();await settle();$('recordMacro').click();await settle();connected=false;$('scan').click();await settle();assert($('stopMacro').hidden);assert($('devicePage').hidden);assert(messages.some(m=>m.action==='stopMacroRecording'));
console.log(JSON.stringify({status:'passed',native_macos_tested:false,tests:['Large outline bolt visible only on external power; no battery pictogram','Four ordinary layers and separate two Fn banks; transparent Fn keys have empty labels','Repeated undo/redo, single-layer reset and undo; conflicts retain cursor; no session list','Fn F1–F12 template targets actual Fn layer and leaves base intact','Native macro events create balanced timed draft; no write until Save','Editable delays, byte encoding, cancel, focus-loss release and browser physical-key recording']},null,2));dom.window.close();
})().catch(e=>{console.error(e.stack);dom.window.close();process.exitCode=1;});
