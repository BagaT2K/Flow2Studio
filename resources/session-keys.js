'use strict';
class FlowSessionHistory {
 constructor(){this.frames=[];this.cursor=0;}
 push(frame){this.frames.splice(this.cursor);this.frames.push(JSON.parse(JSON.stringify(frame)));this.cursor=this.frames.length;}
 get undo(){return this.cursor?this.frames[this.cursor-1]:null;}
 get redo(){return this.cursor<this.frames.length?this.frames[this.cursor]:null;}
 moved(back){this.cursor+=back?-1:1;}
 clear(){this.frames=[];this.cursor=0;}
}
window.FlowSessionHistory=FlowSessionHistory;
