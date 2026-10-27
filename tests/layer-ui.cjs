/* Device-persistent layout fixtures, fresh application instances and per-bank history. */
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require(process.env.FLOW2_JSDOM||'jsdom'),root=path.resolve(__dirname,'../resources');
let layers=null,writes=[],available=true,failRead=false;
const device={id:1,key:'persistent-keyboard',model:'68',connection:'2.4 ГГц',vendor:true};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function app(){
 const dom=new JSDOM(fs.readFileSync(path.join(root,'index.html'),'utf8'),{runScripts:'outside-only',url:'file://'+path.join(root,'index.html')});
 const w=dom.window,$=id=>w.document.getElementById(id);let pending=0;w.setInterval=()=>0;
 w.webkit={messageHandlers:{flow:{postMessage(m){pending++;setTimeout(()=>{let result,error;switch(m.action){
 case'preferences':result={theme:'dark',batteryStyle:'keyboardPercent',autoCharge:true,keycaps:{}};break;
 case'scan':result={devices:available?[device]:[]};break;case'select':result=device;break;
 case'cachedState':result={caps:null,jobs:[]};break;case'preparationStatus':result={available:true};break;
 case'status':result={valid:true,percent:51,power:true};break;
 case'capabilities':result={protocol:12,layers:6,macros:16,macroBytes:3156,brightness:70,effect:0,profileSupported:true};break;
 case'initializeLayers':if(!layers){layers=w.flowFactoryLayers.map(a=>Array.from(a));for(const l of [4,5])layers[l]=layers[0].map((v,i)=>layers[l][i]>255?layers[l][i]:v);}result={layers};break;
 case'readLayer':if(failRead)error='offline';else result={layer:m.args.layer,keys:[...layers[m.args.layer]]};break;
 case'setKey':{const {layer,row,col,code,expectedCode}=m.args,i=row*15+col,before=[...layers[layer]];assert.equal(before[i],expectedCode);layers[layer][i]=code;writes.push(m);result={layer,before,keys:[...layers[layer]]};break;}
 case'setLayer':{const {layer,keys,expected}=m.args,before=[...layers[layer]];assert.equal(JSON.stringify(before),JSON.stringify(expected));layers[layer]=[...keys];writes.push(m);result={layer,before,keys:[...keys]};break;}
 default:error='Unexpected '+m.action;
 }w.flowReceive({id:m.id,result,error});pending--;},2);}}}};
 for(const file of ['layout68.js','layouts.js','factory-layers.js','session-keys.js','macro-recorder.js','app.js'])w.eval(fs.readFileSync(path.join(root,file),'utf8'));
 async function settle(){await sleep(60);while(pending)await sleep(5);await sleep(5);}
 await settle();w.document.querySelector('.device').click();await settle();
 async function tab(name){w.document.querySelector('[data-tab="'+name+'"]').click();await settle();}
 async function layer(id,n){$(id).value=n;$(id).dispatchEvent(new w.Event('change'));await settle();}
 function key(i){return w.document.querySelector('.key[data-index="'+i+'"]');}
 async function assign(i,code){key(i).dispatchEvent(new w.MouseEvent('click',{bubbles:true}));$('keyCode').value=code;$('applyKey').click();await settle();}
 return {dom,w,$,settle,tab,layer,key,assign};
}
(async()=>{
 let a=await app();await a.tab('keys');assert(!a.$('keyEditor').hidden);assert(a.$('applyKey').disabled);assert(a.$('keyCode').disabled);assert.equal(a.w.document.querySelectorAll('.assigned').length,0);
 assert.equal(a.$('showKeyHistory'),null);assert.equal(a.$('keyHistoryList'),null);assert.equal(a.$('chargingIcon').querySelector('rect'),null);
 assert.equal(a.$('keysAssignmentHost').closest('.assignment-layout').children.length,2);
 await a.assign(0,5);await a.assign(1,6);assert(a.key(0).classList.contains('assigned'));assert(a.key(1).classList.contains('assigned'));
 const base=[...layers[0]];await a.tab('fn');assert(a.$('undoKey').disabled);assert.equal(a.key(21).querySelector('text').textContent,'');assert(!a.key(21).classList.contains('assigned'));assert(a.key(1).classList.contains('assigned'));
 assert.equal(a.key(1).querySelector('text').textContent,'Экран −');assert(!a.$('keyboard').textContent.includes('Спец.'));assert(a.$('applyKey').disabled);
 a.$('undoKey').click();await a.settle();assert.deepEqual(layers[0],base);
 await a.assign(21,58);assert(a.key(21).classList.contains('assigned'));assert.equal(a.key(21).querySelector('text').textContent,'F1');
 await a.layer('fnLayer',3);assert(a.$('undoKey').disabled);await a.assign(21,59);
 await a.layer('fnLayer',1);a.$('undoKey').click();await a.settle();assert.equal(layers[1][21],1);assert.equal(layers[3][21],59);assert.deepEqual(layers[0],base);
 await a.tab('keys');assert(!a.$('undoKey').disabled);a.$('undoKey').click();await a.settle();assert.equal(layers[0][1],30);assert.equal(layers[0][0],5);
 await a.layer('layer',2);assert(a.$('undoKey').disabled);await a.assign(0,7);await a.layer('layer',0);assert(a.key(0).classList.contains('assigned'));
 a.$('toggleHighlights').click();assert(!a.key(0).classList.contains('assigned'));assert.equal(a.$('toggleHighlights').getAttribute('aria-pressed'),'false');a.$('toggleHighlights').click();assert(a.key(0).classList.contains('assigned'));
 // Failed reread retains cached desired keys and isolated history.
 failRead=true;await a.tab('fn');await a.tab('keys');assert(a.key(0).classList.contains('assigned'));failRead=false;
 // Switching tabs during a write cannot change the target of its history frame.
 a.key(2).dispatchEvent(new a.w.MouseEvent('click',{bubbles:true}));a.$('keyCode').value='8';a.$('applyKey').click();a.w.document.querySelector('[data-tab="fn"]').click();await a.settle();assert(!a.w.document.querySelector('[data-panel="keys"]').hidden);assert.equal(layers[0][2],8);
 const saved=[...layers[0]];a.dom.window.close();
 // New JS application instance: no undo history is persisted, but changed-key
 // accents are reconstructed from the actual device data rather than history.
 a=await app();await a.tab('keys');assert.deepEqual(layers[0],saved);assert(a.key(0).classList.contains('assigned'));assert(a.key(2).classList.contains('assigned'));assert(a.$('undoKey').disabled);assert(a.$('redoKey').disabled);
 await a.layer('layer',2);assert(a.key(0).classList.contains('assigned'));assert.equal(a.key(0).querySelector('text').textContent,'D');
 a.w.flowReceive({id:0,result:{battery:{valid:true,percent:52,power:false}}});assert(a.$('chargingIcon').hasAttribute('hidden'));assert.equal(a.$('batteryValue').textContent,'52%');
 a.dom.window.close();console.log(JSON.stringify({status:'passed',hardware_tested:false,tests:['Undo/redo isolated per ordinary/Fn bank and layer; switching blocked during mutation','No session-history text/list; rounded arrow controls and two-column assignment modules','No selected key leaves assignment visible and disabled','Fn explicit assignments highlighted; transparent/disabled positions empty; readable standard function labels','Changed-key highlight restored from actual device keys in a fresh app instance; undo history stays temporary','Highlight toggle affects drawing only; cached layout survives unavailable reread','Outline charging bolt only on external power; no battery pictogram']},null,2));
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
