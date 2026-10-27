'use strict';
(()=>{
 const names={en:'English',zh:'简体中文',ja:'日本語',ko:'한국어',es:'Español',de:'Deutsch',ru:'Русский'},catalog=window.flowLocales||{},textRecords=new WeakMap(),attributeRecords=new WeakMap();
 let language='en',scheduled=false,refreshing=false,disposed=false,initialized=false;
 try{const saved=localStorage.getItem('flow.language');if(names[saved])language=saved;}catch{}
 const keys=Object.keys(catalog).sort((a,b)=>b.length-a.length),reverse=new Map();
 for(const key of keys)for(const value of Object.values(catalog[key]))if(!reverse.has(value))reverse.set(value,key);
 const escape=s=>s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
 const fragments=new RegExp(keys.filter(key=>key.length>1).map(escape).join('|'),'g');
 const formatToken=/%(?:0?\d+)?(?:ll|l)?[udx@]/g;
 const patterns=keys.filter(key=>/%(?:0?\d+)?(?:ll|l)?[udx@]/.test(key)).map(key=>{
  let last=0,expression='^',count=0;for(const match of key.matchAll(formatToken)){expression+=escape(key.slice(last,match.index).replace(/%%/g,'%'))+(match[0].endsWith('@')?'([\\s\\S]+?)':match[0].endsWith('x')?'([0-9a-fA-F]+)':'(-?\\d+)');last=match.index+match[0].length;count++;}expression+=escape(key.slice(last).replace(/%%/g,'%'))+'$';return {key,regex:new RegExp(expression),count};
 });
 function translate(source,depth=0){
  if(typeof source!=='string'||!source.trim())return source;
  const key=catalog[source]?source:reverse.get(source);
  if(key)return catalog[key][language]||catalog[key].en||source;
  if(depth<3)for(const pattern of patterns){const match=pattern.regex.exec(source);if(!match)continue;let index=1;return (catalog[pattern.key][language]||catalog[pattern.key].en).replace(formatToken,()=>{const value=match[index++];return /[\/\\]/.test(value)?value:translate(value,depth+1);}).replace(/%%/g,'%');}
  return source.replace(fragments,key=>catalog[key][language]||catalog[key].en||key);
 }
 function excluded(node){const element=node.nodeType===1?node:node.parentElement;return !element||!!element.closest('script,style,textarea,pre,code,#firmwareDialogDetails,[data-i18n-skip]');}
 function translateNode(node){
  if(excluded(node))return;
  const value=node.nodeValue,old=textRecords.get(node),source=old&&old.rendered===value?old.source:value,rendered=translate(source);
  textRecords.set(node,{source,rendered});if(rendered!==value)node.nodeValue=rendered;
 }
 function translateAttributes(element){
  if(excluded(element))return;
  let records=attributeRecords.get(element);if(!records){records={};attributeRecords.set(element,records);}
  for(const name of ['title','aria-label','placeholder'])if(element.hasAttribute(name)){
   const value=element.getAttribute(name),old=records[name],source=old&&old.rendered===value?old.source:value,rendered=translate(source);records[name]={source,rendered};if(rendered!==value)element.setAttribute(name,rendered);
  }
 }
 const observer=new MutationObserver(()=>{if(!scheduled&&!refreshing){scheduled=true;queueMicrotask(()=>{scheduled=false;refresh();});}});
 function observe(){observer.observe(document.body,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['title','aria-label','placeholder']});}
 function refresh(){
  if(disposed||refreshing||!document.body)return;refreshing=true;observer.disconnect();
  try{const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);while(walker.nextNode())translateNode(walker.currentNode);document.body.querySelectorAll('[title],[aria-label],[placeholder]').forEach(translateAttributes);document.documentElement.lang=language;const picker=document.getElementById('appLanguage');if(picker){picker.value=language;const label=translate('Language');if(picker.getAttribute('aria-label')!==label)picker.setAttribute('aria-label',label);}window.syncSelects?.();}finally{refreshing=false;observe();}
 }
 function setLanguage(value){if(!names[value])value='en';if(value!==language||!initialized){language=value;try{localStorage.setItem('flow.language',value);}catch{}refresh();initialized=true;}return language;}
 function dispose(){disposed=true;observer.disconnect();}
 window.addEventListener('pagehide',dispose);
 function sourceText(element){if(!element)return '';const walker=document.createTreeWalker(element,NodeFilter.SHOW_TEXT);let text='';while(walker.nextNode()){const node=walker.currentNode,record=textRecords.get(node);text+=record&&record.rendered===node.nodeValue?record.source:node.nodeValue;}return text;}
 window.flowI18n={translate,setLanguage,refresh,dispose,sourceText,get language(){return language;},languages:names};
 const originalConfirm=window.confirm.bind(window);window.confirm=message=>originalConfirm(translate(message));
 setLanguage(language);
})();
