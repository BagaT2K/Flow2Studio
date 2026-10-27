const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require(process.env.FLOW2_JSDOM||'jsdom');const root=path.resolve(__dirname,'../resources');
const device={id:1,key:'same-rf',model:'68',connection:'2.4 ГГц',vendor:true,pid:1};
const caps={protocol:12,layers:6,macros:16,macroBytes:3156,brightness:75,effect:0,profileSupported:true,profile:{rf:true,bluetooth:false,indicatorBrightness:191,timeout:60,touchWake:true,syncBreathing:true,mainBrightness:75,firmwareVersion:'3.11',quietReleaseSupported:true,advancedSupported:true,usbBatteryRefreshSupported:true,animationsSupported:true,animationMode:0,bootEntryPreserved:true,syncBrightness:false,lowBatteryThreshold:0}};
let chosenLanguage='en',offline=false,jobs=[],messages=[],requests=0,failAction=null;
const dom=new JSDOM(fs.readFileSync(path.join(root,'index.html'),'utf8'),{runScripts:'outside-only',url:'https://flow2studio.test/'});const w=dom.window,$=id=>w.document.getElementById(id);w.setInterval=()=>0;
w.webkit={messageHandlers:{flow:{postMessage(m){messages.push(m);requests++;setTimeout(()=>{let result,error=null;switch(m.action){
case'savePreferences':chosenLanguage=m.args.language||chosenLanguage;result={language:chosenLanguage,theme:'dark',batteryStyle:'keyboardPercent',autoCharge:true,keycaps:{}};break;
case'preferences':result={language:chosenLanguage,theme:'dark',batteryStyle:'keyboardPercent',autoCharge:true,keycaps:{}};break;
case'scan':result={devices:[device]};break;case'select':result=device;break;
case'initializeLayers':result={initialized:true,changedLayers:[]};break;
case'cachedState':result={caps:JSON.parse(JSON.stringify(caps)),jobs:JSON.parse(JSON.stringify(jobs))};break;
case'preparationStatus':result={available:true,canPrepare:false};break;
case'status':if(offline)error='Нет ответа';else result={valid:true,percent:81,power:true};break;
case'capabilities':if(offline)error='Клавиатура не ответила';else result=JSON.parse(JSON.stringify(caps));break;
case'readLayer':result={layer:0,keys:Array(75).fill(4)};break;
case'lighting':case'profile':case'advanced':
 if(m.action===failAction){error='Тест: ответ не подтверждён';break;}
 if(offline){jobs=jobs.filter(j=>j.action!==m.action);jobs.push({action:m.action,args:{...m.args,persist:true}});result={...m.args,queued:true};w.flowReceive({id:0,result:{deferred:{device:1,count:jobs.length}}});}
 else {result=m.action==='lighting'?m.args:{...caps.profile,...m.args};if(m.action!=='lighting')Object.assign(caps.profile,m.args);}
 break;
case'clearDeferred':jobs=[];result={cleared:true};w.flowReceive({id:0,result:{deferred:{device:1,count:0}}});break;
default:error='Unexpected '+m.action;
}w.flowReceive({id:m.id,result,error});requests--;},1);}}}};
const delay=ms=>new Promise(r=>setTimeout(r,ms));async function settle(ms=100){await delay(ms);while(requests)await delay(10);}
(async()=>{
for(const file of ['layout68.js','layouts.js','factory-layers.js','factory-models.js','session-keys.js','macro-recorder.js','locales.js','localization.js','app.js'])w.eval(fs.readFileSync(path.join(root,file),'utf8'));await settle();
assert.equal(w.flowI18n.language,'en');assert.equal(w.document.documentElement.lang,'en');assert.equal($('restoreFirmware').textContent,'Install Stock Firmware');assert.equal($('restoreBackup').textContent,'Restore from Backup');
w.document.querySelector('.device').click();await settle();
$('macroText').value='text Hello\nwait 25\ntap A';
const expected={en:'Brightness',zh:'亮度',ja:'明るさ',ko:'밝기',es:'Brillo',de:'Helligkeit',ru:'Яркость'},results=[];
for(const language of Object.keys(expected)){
 $('appLanguage').value=language;$('appLanguage').dispatchEvent(new w.Event('change',{bubbles:true}));await settle();
 assert.equal(w.flowI18n.language,language);assert.equal(w.document.documentElement.lang,language);assert.equal(w.localStorage.getItem('flow.language'),language);assert.equal(chosenLanguage,language);
 assert.equal(w.document.querySelector('label[for="brightness"]').textContent,expected[language]);
 const before=$('indicatorStatus').textContent;$('touchWake').checked=!$('touchWake').checked;$('touchWake').dispatchEvent(new w.Event('change'));await settle();assert.equal($('indicatorStatus').textContent,before);
 assert.equal($('touchWakeStatus').textContent,w.flowLocales['Применено, проверено и сохранено.'][language]);
 $('lowBatteryThreshold').value='20';$('lowBatteryThreshold').dispatchEvent(new w.Event('change'));await settle();assert.equal($('indicatorStatus').textContent,w.flowLocales['Применено, проверено и сохранено.'][language]);
 assert.equal($('lowBatteryThreshold').value,'20');assert.equal($('macroText').value,'text Hello\nwait 25\ntap A');
 const formatted=w.flowI18n.translate('Найдено устройств восстановления USB: 2. Оставьте подключённой одну клавиатуру для восстановления.');assert(formatted.includes('2'));if(language!=='ru')assert(!/[А-Яа-яЁё]/.test(formatted));
 const error=w.flowI18n.translate('Клавиатура отклонила условия команды. [LFC 12/1; код 1; Studio 0.9; яркость 100%; этап 0]');if(language!=='ru')assert(!/[А-Яа-яЁё]/.test(error));assert(error.includes('100%'));results.push({language,status:'passed'});
}
assert(messages.some(m=>m.action==='savePreferences'&&m.args.language==='de'));assert.equal(w.document.querySelectorAll('#appLanguage option').length,7);
// A freshly loaded page applies the locally saved language before native preferences return.
const restart=new JSDOM(fs.readFileSync(path.join(root,'index.html'),'utf8'),{runScripts:'outside-only',url:'https://flow2studio.test/'});restart.window.localStorage.setItem('flow.language','ja');restart.window.eval(fs.readFileSync(path.join(root,'locales.js'),'utf8'));restart.window.eval(fs.readFileSync(path.join(root,'localization.js'),'utf8'));assert.equal(restart.window.flowI18n.language,'ja');assert.equal(restart.window.document.querySelector('label[for="brightness"]').textContent,'明るさ');restart.window.flowI18n.dispose();await delay(30);restart.window.close();
console.log(JSON.stringify({status:'passed',languages:results,tests:['English default','All seven languages update labels and dynamic independent statuses','Picker persists through native preferences and local restart','Control values and macro source remain unchanged'],hardware_tested:false},null,2));w.flowI18n?.dispose();await delay(50);dom.window.close();
})().catch(async e=>{console.error(e.stack);w.flowI18n?.dispose();await delay(50);dom.window.close();process.exitCode=1;});
