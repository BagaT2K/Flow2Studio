const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require(process.env.FLOW2_JSDOM||'jsdom');
const root=path.resolve(__dirname,'../resources'),delay=ms=>new Promise(r=>setTimeout(r,ms));
async function testModel(model){
 const rows=model===68?5:6,cols=model===100?18:15,positions=rows*cols,macroBytes=({68:3156,84:2976,100:2760})[model];
 const dom=new JSDOM(fs.readFileSync(path.join(root,'index.html'),'utf8'),{runScripts:'outside-only',url:'file://'+path.join(root,'index.html')});const w=dom.window,$=id=>w.document.getElementById(id);w.setInterval=()=>0;w.confirm=()=>true;
 let device={id:1,key:'fixture-'+model,name:'Flow2@Lofree',model:String(model),connection:'USB',vid:0x388d,pid:[68,84,100].indexOf(model)+1,version:20,usbLocation:999,vendor:true},layers,macros=new Uint8Array(macroBytes),messages=[],pending=null,sequence=0,firmwareWrites=0,inFlight=0;
 const profile={base14:true,model:String(model),firmwareVersion:'0.9',rf:true,bluetooth:true,timeout:60,indicatorBrightness:191,touchWake:true,syncBreathing:true,syncBrightness:true,mainBrightness:75,keepAwakeSupported:true,advancedSupported:true,usbBatteryRefreshSupported:true,animationsSupported:true,zoneAnimationsSupported:true,fillAnimationSupported:true,independentSyncBrightnessSupported:true,independentIndicatorSupported:true,animationSpeed:1,animationMode:0,bootEntryPreserved:true};
 w.webkit={messageHandlers:{flow:{postMessage(m){messages.push(m);inFlight++;setTimeout(()=>{let result,error;switch(m.action){
 case 'preferences':result={theme:'dark',batteryStyle:'keyboard',autoCharge:true,keycaps:{}};break;
 case 'scan':result={devices:[device]};break;case 'select':result=device;break;case 'status':result={valid:true,percent:73,power:true};break;
 case 'cachedState':result={caps:null,jobs:[]};break;
 case 'preparationStatus':result={available:true,wired:true,canPrepare:true,canRestore:true,canRestoreFactory:true,recovery:false,base14Target:true,model:String(model)};break;
 case 'capabilities':result={protocol:12,layers:6,macros:16,macroBytes,rows,cols,positions,brightness:75,effect:0,profileSupported:true,profile};break;
 case 'initializeLayers':result={initialized:true,changedLayers:[]};break;
 case 'readLayer':result={layer:m.args.layer,keys:[...layers[m.args.layer]]};break;
 case 'setKey':{const {layer,row,col,code}=m.args;assert(row<rows&&col<cols);const before=[...layers[layer]];layers[layer][row*cols+col]=code;result={layer,keys:[...layers[layer]],before};break;}
 case 'setLayer':assert.equal(m.args.keys.length,positions);result={layer:m.args.layer,keys:[...m.args.keys],before:[...layers[m.args.layer]]};layers[m.args.layer]=[...m.args.keys];break;
 case 'readMacros':result={data:Buffer.from(macros).toString('base64'),count:16,size:macroBytes};break;
 case 'saveMacros':macros=Uint8Array.from(Buffer.from(m.args.data,'base64'));assert.equal(macros.length,macroBytes);assert.equal(macros[macroBytes-1],0);result={data:Buffer.from(macros).toString('base64'),count:16,size:macroBytes};break;
 case 'prepareKeyboard':if(!m.args.confirmationToken){pending='token-'+model+'-'+(++sequence);result={confirmation:{token:pending,title:'Обновить Flow 2 '+model+'?',warning:'На свой страх и риск. Откат не гарантирован при потере питания.',details:'Studio 0.9 · база Lofree 0.14',confirmLabel:'Обновить прошивку'}};}else if(m.args.confirmationToken===pending){pending=null;firmwareWrites++;device={...device,id:device.id+1};result={verified:true,location:999};}else error='Подтверждение устарело';break;
 case 'cancelFirmwareConfirmation':pending=null;result={cancelled:true};break;
 default:error='Unexpected action '+m.action;
 }w.flowReceive({id:m.id,result,error});inFlight--;},1);}}}};
 for(const name of ['layout68.js','layouts.js','factory-layers.js','factory-models.js','session-keys.js','macro-recorder.js'])w.eval(fs.readFileSync(path.join(root,name),'utf8'));
 layers=w.flowFactoryModels[String(model)].map(a=>[...a]);
 w.eval(fs.readFileSync(path.join(root,'app.js'),'utf8')+'\nwindow.portTest={selectDevice,readLayer,chooseKey,prepareKeyboard,rpc,modelShape,setTab(tab){state.tab=tab;renderPage();drawKeyboard();},getState(){return state;}};');
 async function settle(){for(let n=0;n<300;n++){await delay(5);if(!inFlight){await delay(15);if(!inFlight)return;}}throw Error('RPC did not settle');}
 await settle();await w.portTest.selectDevice(device);await settle();assert.equal(w.portTest.modelShape().positions,positions);
 w.portTest.setTab('keys');$('layer').value='5';await w.portTest.readLayer();await settle();const key=(model===68?w.flowLayout68:w.flowLayouts[String(model)]).at(-1);w.portTest.chooseKey(key);$('keyCode').value='4';$('applyKey').click();await settle();assert.equal(layers[5][key.row*cols+key.col],4);assert(messages.some(m=>m.action==='setKey'&&m.args.row===key.row&&m.args.col===key.col));
 w.portTest.setTab('fn');$('fnLayer').value='1';await w.portTest.readLayer();await settle();$('fnTemplate').value='fkeys';$('applyFnTemplate').click();await settle();const fnWrite=messages.filter(m=>m.action==='setLayer').at(-1);assert.equal(fnWrite.args.keys.length,positions);assert.equal(fnWrite.args.keys[1],58);
 w.portTest.setTab('macros');$('readMacros').click();await settle();$('macroText').value='text abc';$('saveMacro').click();await settle();assert(messages.some(m=>m.action==='saveMacros'));assert.equal(macros.length,macroBytes);
 const scans=messages.filter(m=>m.action==='scan').length;const cancel=w.portTest.prepareKeyboard(false);await delay(30);assert(!$('firmwareDialog').hidden);assert($('firmwareDialogConfirm').disabled);assert.equal(w.document.activeElement,$('firmwareDialogCancel'));assert.equal(firmwareWrites,0);const cancelledToken=pending;$('firmwareDialog').dispatchEvent(new w.KeyboardEvent('keydown',{key:'Escape',bubbles:true}));await cancel;assert.equal(firmwareWrites,0);assert.equal(pending,null);assert.equal(messages.filter(m=>m.action==='scan').length,scans);assert($('firmwareDialog').hidden);await assert.rejects(w.portTest.rpc('prepareKeyboard',{confirmationToken:cancelledToken}));
 const install=w.portTest.prepareKeyboard(false);await delay(30);assert(!$('firmwareDialog').hidden);$('firmwareRiskAccepted').checked=true;$('firmwareRiskAccepted').dispatchEvent(new w.Event('change',{bubbles:true}));assert(!$('firmwareDialogConfirm').disabled);$('firmwareDialogConfirm').click();await install;await settle();assert.equal(firmwareWrites,1);assert($('firmwareDialog').hidden);assert.equal(w.portTest.getState().setup.phase,'ready');
 dom.window.close();return {model,status:'passed',positions,macroBytes,tests:['last physical key and layer use model stride','Fn template has correct complete layer size','macro save respects model memory and guard','Studio consent dialog defaults to cancel and needs explicit checkbox','Escape invalidates token without DFU or rescan','single-use confirmation commits once and reconnects'],hardware_tested:false};
}
(async()=>{const results=[];for(const model of [68,84,100])results.push(await testModel(model));console.log(JSON.stringify(results,null,2));})().catch(e=>{console.error(e.stack);process.exitCode=1;});
