'use strict';
// Presentation only: version checks and release links belong to the native host.
(() => {
 let preview=false;
 const banner=document.getElementById('updateBanner');
 async function check(force){
  const button=document.getElementById('checkUpdates');button.disabled=true;
  try{
   const value=await rpc('checkUpdates',{force});
   preview=!!value.preview;
   banner.hidden=!(preview||value.available);
   document.getElementById('updatePreview').hidden=!preview;
   document.getElementById('updateDetails').hidden=true;
   document.getElementById('updateVersion').textContent='Flow2Studio '+(preview?'0.9.6':value.version||'0.9.6');
  }catch{}
  finally{button.disabled=false;}
 }
 document.getElementById('checkUpdates').onclick=()=>check(true);
 document.getElementById('showUpdate').onclick=async()=>{
  if(preview){const details=document.getElementById('updateDetails');details.hidden=!details.hidden;return;}
  try{await rpc('openUpdate');}catch{}
 };
 if(window.webkit?.messageHandlers?.flow)void check(false);
})();
