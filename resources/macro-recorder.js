'use strict';
const flowWebKeys={Enter:40,Escape:41,Backspace:42,Tab:43,Space:44,Minus:45,Equal:46,BracketLeft:47,BracketRight:48,Backslash:49,Semicolon:51,Quote:52,Backquote:53,Comma:54,Period:55,Slash:56,CapsLock:57,PrintScreen:70,ScrollLock:71,Pause:72,Insert:73,Home:74,PageUp:75,Delete:76,End:77,PageDown:78,ArrowRight:79,ArrowLeft:80,ArrowDown:81,ArrowUp:82,NumLock:83,NumpadDivide:84,NumpadMultiply:85,NumpadSubtract:86,NumpadAdd:87,NumpadEnter:88,NumpadDecimal:99,IntlBackslash:100,ContextMenu:101,NumpadEqual:103,ControlLeft:224,ShiftLeft:225,AltLeft:226,MetaLeft:227,ControlRight:228,ShiftRight:229,AltRight:230,MetaRight:231};
function flowWebKey(code){if(flowWebKeys[code])return flowWebKeys[code];if(/^Key[A-Z]$/.test(code))return code.charCodeAt(3)-61;if(/^Digit[0-9]$/.test(code))return code==='Digit0'?39:29+Number(code.slice(5));if(/^Numpad[0-9]$/.test(code))return code==='Numpad0'?98:88+Number(code.slice(6));if(/^F(?:[1-9]|1[0-9]|2[0-4])$/.test(code)){const n=Number(code.slice(1));return n<=12?57+n:91+n;}return 0;}
class FlowMacroCapture {
 constructor(delays=true){this.delays=delays;this.events=[];this.held=new Set();this.last=null;}
 accept(code,down,time){if(!Number.isInteger(code)||code<1||code>255||!Number.isFinite(time))return false;if(down?this.held.has(code):!this.held.has(code))return false;
  if(this.delays&&this.last!==null){let gap=Math.min(300000,Math.max(0,Math.round(time-this.last)));while(gap>0){const ms=Math.min(60000,gap);this.events.push({type:'wait',ms});gap-=ms;}}
  this.last=time;if(down)this.held.add(code);else this.held.delete(code);this.events.push({type:down?'down':'up',code});return true;
 }
 finish(time){if(this.delays&&this.held.size&&this.last!==null&&Number.isFinite(time)){let gap=Math.min(300000,Math.max(0,Math.round(time-this.last)));while(gap>0){const ms=Math.min(60000,gap);this.events.push({type:'wait',ms});gap-=ms;}}for(const code of [...this.held].reverse())this.events.push({type:'up',code});this.held.clear();return this.events;}
}
window.FlowMacroCapture=FlowMacroCapture;window.flowWebKey=flowWebKey;
