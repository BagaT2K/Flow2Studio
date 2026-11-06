'use strict';
/* One catalog; only the normal key path accepts OEM service keycodes. */
window.flowActions=(()=>{
 const t=s=>window.flowI18n?.translate(s)||s;
 const main=[['Volume',[[1,'Volume up',0xa9],[2,'Volume down',0xaa],[3,'Toggle Mute',0xa8]]],['Media',[[4,'Play/pause',0xae],[5,'Next track',0xab],[6,'Previous track',0xac]]],['Display',[[9,'Screen +',0xbd],[10,'Screen −',0xbe]]]];
 const fn=[[0x7804,'Light +'],[0x7803,'Light −'],[0x7e0e,'Effect +'],[0x7e12,'Effect −'],[0x7e11,'Touch panel'],[0x7e0b,'Window overview'],[0x7e0c,'Lock']];
 const usages=[...Array.from({length:112},(_,i)=>i+4),224,225,226,227,228,229,230,231];
 function keys(){return usages.map(k=>[k,label(k)]);}
 function macros(count=16,touch=false){return Array.from({length:Math.min(16,count)},(_,i)=>[touch?320+i:0x7700+i,t('Macro %u').replace('%u',i+1)]);}
 const profileNames=['1-Zone Profile','2-Zone Profile','3-Zone Profile','Next Touch Bar Profile'];
 function profileName(code){return profileNames[code-0x7e30];}
 function groups(context,count=16,layers=6,profiles=false){
  const profileGroup=['Touch Bar Profiles',profiles?profileNames.map((name,i)=>[(context==='touch'?336:0x7e30)+i,name]):[]];
  const keyGroup=['Keys',keys().map(([k,s])=>[context==='touch'?k+64:k,s])];
  const media=main.map(([s,items])=>[s,items.map(([id,name,code])=>[context==='touch'?id:code,name])]);
  if(context==='touch')return [...media,['Scrolling',[[7,'Scrolling']]],profileGroup,keyGroup,['Macros',macros(count,true)]];
  const fnGroup=['Fn functions',[...fn,...Array.from({length:layers},(_,i)=>[0x5220+i,t('Hold %@').replace('%@',t(layerName(i)))])]];
  return context==='fn'?[fnGroup,...media,profileGroup,keyGroup,['Macros',macros(count)]]:[keyGroup,...media,fnGroup,profileGroup,['Macros',macros(count)]];
 }
 function fill(select,groups,leading=[]){
  select.replaceChildren();const option=([value,text])=>{const el=document.createElement('option');el.value=value;el.textContent=t(text);return el;};
  leading.forEach(item=>select.append(option(item)));
  groups.forEach(([title,items])=>{if(!items.length)return;const group=document.createElement('optgroup');group.label=t(title);items.forEach(item=>group.append(option(item)));select.append(group);});
 }
 return {groups,fill,main,profileName};
})();
