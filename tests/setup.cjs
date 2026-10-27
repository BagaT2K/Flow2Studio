const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require(process.env.FLOW2_JSDOM||'jsdom');const root=path.resolve(__dirname,'../resources');
const dom=new JSDOM(fs.readFileSync(path.join(root,'index.html'),'utf8'),{runScripts:'outside-only',url:'file://'+path.join(root,'index.html')});
const w=dom.window,$=id=>w.document.getElementById(id);w.setInterval=()=>0;w.confirm=()=>true;
let oemRollbackAvailable=false;let firmwareOverride=null,extensionCurrent=true,usbCurrent=true,capabilityFailure=false,cachedCaps=null;
let inFlight=0,mode='ok',supported=false,hasBackup=false,devices=[],messages=[];
const usb=id=>({id,key:'usb-'+id,name:'Flow2@Lofree',model:'68',connection:'USB',usbLocation:123,vid:0x388d,pid:1,version:9,vendor:true});
const boot=()=>({id:'dfu-123',key:'dfu-123',name:'Flow 2 · восстановление',model:'',connection:'USB',bootloader:true,location:123,vendor:false});
w.webkit={messageHandlers:{flow:{postMessage(message){messages.push(message);inFlight++;setTimeout(()=>{let result,error=null;const device=devices.find(d=>d.id===message.device);
 switch(message.action){
 case 'preferences':result={theme:'dark',batteryStyle:'both',autoCharge:true,keycaps:{}};break;
 case 'scan':result={devices};break;
 case 'select':result=device;break;
 case 'initializeLayers':result={initialized:true,changedLayers:[]};break;
 case 'cachedState':result={caps:cachedCaps,jobs:[]};break;

 case 'status':result={valid:true,percent:45};break;
 case 'readLayer':result={layer:message.args.layer,keys:Array(75).fill(4)};break;
 case 'capabilities':if(capabilityFailure){error='No extension reply';break;}result={protocol:12,layers:6,macros:16,macroBytes:3156,brightness:75,effect:0,profileSupported:supported,profile:{base14:extensionCurrent&&usbCurrent,rf:true,bluetooth:true,indicatorBrightness:191,timeout:60,touchWake:true,syncBreathing:true,mainBrightness:75,keepAwakeSupported:true,firmwareVersion:firmwareOverride|| (extensionCurrent?(usbCurrent?"0.9":"3.8"):"3.7"),advancedSupported:extensionCurrent,usbBatteryRefreshSupported:extensionCurrent&&usbCurrent,animationsSupported:extensionCurrent&&usbCurrent,zoneAnimationsSupported:extensionCurrent&&usbCurrent,fillAnimationSupported:extensionCurrent&&usbCurrent,independentSyncBrightnessSupported:extensionCurrent&&usbCurrent,independentIndicatorSupported:extensionCurrent&&usbCurrent,animationSpeed:1,animationMode:0,bootEntryPreserved:extensionCurrent&&usbCurrent,zoneTestSupported:extensionCurrent&&usbCurrent,zoneDiagnosticsSupported:extensionCurrent&&usbCurrent,zoneChargingSupported:extensionCurrent&&usbCurrent,editingSleepSupported:true,fullLightSleepSupported:true,rfLightGateSupported:true,packedStateSupported:true,quietReleaseSupported:extensionCurrent}};break;
 case 'preparationStatus':result={canInstallOEM14:device.version===9&&!device.bootloader&&device.connection==='USB',canRollbackOEM14:oemRollbackAvailable&&device.connection==='USB',oem14Installed:device.version===20,available:true,wired:device.connection==='USB'&&!device.bootloader,recovery:!!device.bootloader,canPrepare:device.connection==='USB',canRestore:device.connection==='USB',canRestoreFactory:device.connection==='USB',message:device.connection==='USB'?'Можно подготовить клавиатуру':'Подключите USB'};break;
 case 'openFirmwareBackups':result={opened:true};break;
 case 'prepareKeyboard':
  if(mode==='cancel'){result={cancelled:true};break;}
  w.flowReceive({id:0,result:{preparation:{phase:'reading',done:1,total:2}}});
  if(mode==='fail'){devices=[boot()];error='Связь прервалась. Доступно восстановление по USB.';break;}
  if(mode==='unsupported'){error='Эта версия прошивки пока не поддерживается';break;}
  devices=[usb(112)];supported=mode!=='no-profile';hasBackup=true;result={verified:true,resetAcknowledged:true,location:123};break;
 case 'profile':supported=false;error='Расширение Studio не подтверждено. Настройки не записаны.';break;
 case 'installOEM14':if(mode==='oem-cancel'){result={cancelled:true};break;}oemRollbackAvailable=true;devices=[{...usb(114),version:20}];supported=false;result={verified:true,restored:true,location:123};break;
 case 'rollbackOEM14':devices=[usb(115)];supported=true;result={verified:true,restored:true,location:123};break;
 case 'restoreBackup':if(mode==='backup-cancel'){result={cancelled:true};break;}
 case 'restoreFirmware':devices=[usb(113)];supported=false;result={verified:true,restored:true,location:123};break;
 default:error='Unknown '+message.action;
 }
 w.flowReceive({id:message.id,result,error});inFlight--;
 },1);}}}};
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));async function settle(){await delay(80);for(let i=0;i<500&&(inFlight||!$('preparationProgress').hidden);i++)await delay(10);assert.equal(inFlight,0);await delay(40);}
async function select(d){devices=[d];$('scan').click();await settle();w.document.querySelector('.device').click();await settle();}
(async()=>{
 w.eval(fs.readFileSync(path.join(root,'layout68.js'),'utf8'));w.eval(fs.readFileSync(path.join(root,'layouts.js'),'utf8'));for(const script of ['factory-layers.js','session-keys.js','macro-recorder.js','app.js'])w.eval(fs.readFileSync(path.join(root,script),'utf8'));await settle();
 assert($('preparationCard').hidden);await select({...usb(110),connection:'2.4 ГГц'});assert($('prepareKeyboard').disabled);assert($('preparationDescription').textContent.includes('USB'));
 await select(usb(111));assert(!$('prepareKeyboard').disabled);assert($('brightness').disabled);assert($('touchWake').disabled);assert($('resetAll').disabled);assert($('firmwareConfirmation').textContent.includes('заблокированы'));mode='cancel';$('prepareKeyboard').click();await settle();assert(!$('prepareKeyboard').disabled);assert.equal($('beginConfiguration'),null);assert.equal(messages.filter(m=>m.action==='restoreFirmware').length,0);
 mode='ok';$('prepareKeyboard').click();await settle();assert.equal($('preparationTitle').textContent,'Клавиатура готова к работе');assert.equal($('beginConfiguration'),null);assert($('preparationBody').hidden);assert.equal($('togglePreparation').getAttribute('aria-expanded'),'false');assert($('preparationDescription').textContent.includes('оставить кабель подключённым'));assert(!$('brightness').disabled);assert($('preparationSteps').hidden);
 $('togglePreparation').click();assert(!$('preparationBody').hidden);$('togglePreparation').click();assert($('preparationBody').hidden);w.document.querySelector('[data-tab="lighting"]').click();
 $('touchWake').checked=false;$('touchWake').dispatchEvent(new w.Event('change'));await settle();assert($('brightness').disabled);assert($('touchWake').disabled);assert($('firmwareConfirmation').textContent.includes('заблокированы'));
 supported=false;await select(usb(111));mode='unsupported';$('prepareKeyboard').click();await settle();assert($('preparationTitle').textContent.includes('остановлена'));assert($('preparationDescription').textContent.includes('не поддерживается'));assert.equal($('beginConfiguration'),null);
 mode='no-profile';$('prepareKeyboard').click();await settle();assert.equal($('beginConfiguration'),null);assert($('preparationDescription').textContent.includes('не подтвердила'));
 supported=false;await select(usb(111));mode='fail';$('prepareKeyboard').click();await settle();assert($('preparationDescription').textContent.includes('Связь прервалась'));assert(w.document.querySelector('.keyboard-stage').hidden);assert($('tabs').hidden);assert(!$('restoreFirmware').disabled);
 const progress=$('preparationMeter').style.width;w.flowReceive({id:0,result:{preparation:{phase:'busy',done:0,total:1}}});assert.equal($('preparationMeter').style.width,progress);
 $('restoreFirmware').click();await settle();assert.equal($('preparationTitle').textContent,'Оригинальная прошивка восстановлена');assert($('brightness').disabled);assert($('touchWake').disabled);assert(!$('prepareKeyboard').disabled);assert.equal($('beginConfiguration'),null);
 mode='backup-cancel';const scansBeforeCancel=messages.filter(m=>m.action==='scan').length;$('restoreBackup').click();await settle();assert($('preparationProgress').hidden);assert(!$('restoreBackup').disabled);assert.equal(messages.filter(m=>m.action==='scan').length,scansBeforeCancel);mode='ok';
 $('restoreBackup').click();await settle();assert.equal($('preparationTitle').textContent,'Прежняя прошивка восстановлена');assert(messages.some(m=>m.action==='restoreBackup'));
 $('firmwareBackups').click();await settle();assert(messages.some(m=>m.action==='openFirmwareBackups'));
 supported=true;hasBackup=true;extensionCurrent=false;await select(usb(111));assert.equal($('prepareKeyboard').hidden,false);assert.equal($('prepareKeyboard').textContent,'Обновить расширение');assert.equal($('prepareKeyboard').disabled,false);assert(!$('preparationBody').hidden);
 // Current firmware starts collapsed on each selection; manual expansion works.
 extensionCurrent=true;usbCurrent=false;await select(usb(111));assert($('preparationDescription').textContent.includes('0.9'));assert(!$('preparationBody').hidden);assert.equal($('prepareKeyboard').textContent,'Обновить расширение');usbCurrent=true;await select(usb(111));assert.equal($('zoneTest'),null);assert($('preparationBody').hidden);$('togglePreparation').click();assert(!$('preparationBody').hidden);await select(usb(111));assert($('preparationBody').hidden);
 // A stale pre-flash cache must never re-enable controls or hide Prepare after
 // a factory restore when the fresh extension query fails.
 cachedCaps={profileSupported:true,protocol:12,layers:6,profile:{advancedSupported:true,usbBatteryRefreshSupported:true,animationsSupported:true,zoneAnimationsSupported:true,fillAnimationSupported:true,independentSyncBrightnessSupported:true,independentIndicatorSupported:true,animationSpeed:1,animationMode:0,bootEntryPreserved:true,zoneTestSupported:true,zoneDiagnosticsSupported:true,zoneChargingSupported:true,firmwareVersion:'3.18'}};capabilityFailure=true;
 $('restoreFirmware').click();await settle();assert.equal($('preparationTitle').textContent,'Оригинальная прошивка восстановлена');assert(!$('prepareKeyboard').hidden);assert(!$('prepareKeyboard').disabled);assert.equal($('prepareKeyboard').textContent,'Подготовить клавиатуру');assert($('brightness').disabled);assert(!$('preparationBody').hidden);
 capabilityFailure=false;cachedCaps=null;
 supported=true;firmwareOverride='3.9';await select(usb(111));const attempted=messages.filter(m=>['prepareKeyboard','restoreFirmware'].includes(m.action)).length;$('prepareKeyboard').click();await settle();assert.equal(messages.filter(m=>['prepareKeyboard','restoreFirmware'].includes(m.action)).length,attempted);assert($('error').textContent.includes('левый Shift'));$('restoreFirmware').click();await settle();assert.equal(messages.filter(m=>['prepareKeyboard','restoreFirmware'].includes(m.action)).length,attempted);
 firmwareOverride=null;supported=false;hasBackup=false;await select(boot());assert(!$('restoreFirmware').disabled);assert(!$('restoreBackup').disabled);$('restoreFirmware').click();await settle();assert.equal($('preparationTitle').textContent,'Оригинальная прошивка восстановлена');assert(messages.some(m=>m.action==='restoreFirmware'&&String(m.device).startsWith('dfu-')));

 // OEM14 uses a separate action; survives a failed extension query and keeps manual backup restore.
 supported=true;await select(usb(111));assert(!$('installOEM14').hidden);assert.equal($('rollbackOEM14'),null);
 mode='oem-cancel';let scanCount=messages.filter(m=>m.action==='scan').length;$('installOEM14').click();await settle();assert.equal(messages.filter(m=>m.action==='scan').length,scanCount);assert(!$('installOEM14').disabled);
 mode='ok';capabilityFailure=true;$('installOEM14').click();await settle();assert.equal($('preparationTitle').textContent,'Заводская Lofree 0.14 установлена');assert($('firmwareConfirmation').textContent.includes('Lofree 0.14'));assert($('installOEM14').hidden);assert.equal($('rollbackOEM14'),null);assert(!$('restoreBackup').disabled);assert($('brightness').disabled);assert(messages.some(m=>m.action==='installOEM14'));
 console.log(JSON.stringify({status:'passed',hardware_tested:false,tests:['Disconnected setup hidden; wireless asks for USB','User cancellation leaves setup available','Verified hotplug and profile reply required before ready screen','Ready collapses automatically; no begin button; manual disclosure works','Unsupported version stops without success','Flash verification alone cannot claim ready without profile reply','Interrupted setup selects bootloader and hides ordinary controls','Factory restore bypasses stale capabilities, rereads availability and exposes Prepare without manual refresh','Busy quit event preserves progress; backups open through native action','OEM14 cancellation, native action, release20 reconnect with failed capability query, disabled Studio controls and manual backup restore availability']},null,2));dom.window.close();
})().catch(e=>{console.error(e.stack);dom.window.close();process.exitCode=1;});
