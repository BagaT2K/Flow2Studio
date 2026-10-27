const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require(process.env.FLOW2_JSDOM||'jsdom'),root=path.resolve(__dirname,'../resources');
const dom=new JSDOM(fs.readFileSync(path.join(root,'index.html'),'utf8'),{runScripts:'outside-only',url:'https://flow.test'}),w=dom.window,$=id=>w.document.getElementById(id);
assert($('updateBanner').hidden,'The demo banner must not flash before the native response');
assert.equal(JSON.parse(fs.readFileSync(path.join(root,'update-config.json'),'utf8')).preview,false);
let result={configured:false,preview:false},fail=false,opened=0;
w.webkit={messageHandlers:{flow:{}}};w.rpc=async(action)=>{if(action==='openUpdate'){opened++;return {};}if(fail)throw Error('offline');return result;};
for(const file of ['locales.js','localization.js','updates.js'])w.eval(fs.readFileSync(path.join(root,file),'utf8'));
const tick=()=>new Promise(r=>setTimeout(r,30));
(async()=>{
 await tick();assert($('updateBanner').hidden);assert.equal($('updateBanner').nextElementSibling.id,'about');
 result={configured:false,preview:true};await $('checkUpdates').onclick();assert(!$('updateBanner').hidden);assert(!$('updatePreview').hidden);
 $('showUpdate').click();assert(!$('updateDetails').hidden);assert.equal(opened,0);
 for(const language of ['en','zh','ja','ko','es','de','ru']){w.flowI18n.setLanguage(language);await tick();if(language!=='ru')assert(!/[А-Яа-яЁё]/.test($('updateBanner').textContent));}
 result={configured:true,preview:false,available:false,version:'0.9.0'};await $('checkUpdates').onclick();assert($('updateBanner').hidden);
 result={configured:true,preview:false,available:true,version:'0.10.0'};await $('checkUpdates').onclick();assert(!$('updateBanner').hidden);assert($('updatePreview').hidden);assert.equal($('updateVersion').textContent,'Flow2Studio 0.10.0');
 await $('showUpdate').onclick();assert.equal(opened,1);
 fail=true;await $('checkUpdates').onclick();assert(!$('checkUpdates').disabled);assert(!$('updateBanner').hidden);
 console.log('Passed: demo hidden by default, explicit preview, no fake download, About placement, seven languages, current/new/offline responses and real release action.');
 w.flowI18n.dispose();await tick();w.close();
})().catch(e=>{console.error(e);process.exit(1);});
