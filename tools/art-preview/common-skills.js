import {position,cell,tile,sprite,pixel,line,ring,disc,spark,burst,label,mix,clamp} from './draw.js';

const cyan='#83dce2', copper='#d98d68', pink='#e88a9c', stone='#cbd0cf';
const dirs=[[1,0],[1,-1],[0,-1],[-1,0],[-1,1],[0,1]];
const progress=t=>clamp((t-.55)/1.65);
const at=(q=0,r=0)=>position(q,r);
function ground(c,q,r,cancer=false) {const p=at(q,r);tile(c,p.x,p.y,cancer);return p;}
function fade(c,a,draw) {c.save();c.globalAlpha=clamp(a);draw();c.restore();}
function path(c,a,b,p,color,v=0) {
  for(let i=0;i<7+v*3;i++) {
    const f=clamp(p-i*.035),x=mix(a.x,b.x,f),y=mix(a.y,b.y,f);
    pixel(c,x,y+Math.sin(i+v)*2,color,i===0?2:1);
  }
}
function moving(c,v,t,cancer) {
  const p=progress(t),a=ground(c,-1,0,cancer),b=ground(c,0,0,cancer);
  path(c,a,b,p,cancer?copper:cyan,v);
  cell(c,cancer?'melanoma':'immune',-1+p,0);
  if(p===1)ring(c,b.x,b.y,12+v*2,cancer?copper:cyan,.4);
}
function attack(c,v,t) {
  ground(c,-1,0);ground(c,0,0,true);
  const p=progress(t),approach=p<.45?p/.45:1-clamp((p-.45)/.22);
  const b=cell(c,'melanoma',0,0);cell(c,'immune',-1+approach*.75,0);
  if(p>.35&&p<.8) {
    const f=clamp((p-.35)/.45);
    line(c,b.x-18,b.y-8,b.x-12,b.y+8,'#899797',2);path(c,b,at(-1,0),f,'#8ea5ac');
    if(p<.55)burst(c,b.x-14,b.y,f,cyan,10,17);
  }
}
function convert(c,v,t,cancer) {
  const p=progress(t),a=ground(c,0,0,!cancer),color=cancer?pink:cyan;
  fade(c,p,()=>tile(c,a.x,a.y,cancer));
  if(p>0&&p<1) {
    if(v===0)ring(c,a.x,a.y,2+p*17,color,.5);
    if(v===1)for(let i=0;i<8;i++)line(c,a.x-14+i*4,a.y+9-p*18,a.x-14+i*4,a.y+12-p*18,color);
    if(v===2)burst(c,a.x,a.y,p,color,15,17,!cancer);
  }
  cell(c,cancer?'melanoma':'immune',0,0);
  if(!cancer&&p>.65)spark(c,a.x+18,a.y-25,cyan,3);
}
function card(c,x,y,color,v) {
  c.fillStyle='#182b2c';c.fillRect(Math.round(x-7),Math.round(y-11),14,22);
  line(c,x-7,y-11,x+7,y-11,color);line(c,x+7,y-11,x+7,y+11,color);
  line(c,x+7,y+11,x-7,y+11,color);line(c,x-7,y+11,x-7,y-11,color);
  if(v===1)spark(c,x,y,color,4);
  else if(v===2)for(let i=-5;i<=5;i+=2)line(c,x+i,y-6,x+i,y+6,color);
  else for(let i=-6;i<=6;i+=3)line(c,x-3,y+i,x+3,y+i,color);
}
function draw(c,v,t,cancer) {
  const a=cell(c,cancer?'melanoma':'immune',0,0),p=progress(t),color=cancer?copper:cyan;
  if(p<.6)for(let i=0;i<7;i++){const y=a.y-15-i*3;pixel(c,a.x+Math.sin(i+t*4)*4,y,color);}
  if(p>.15)fade(c,clamp(p*4),()=>card(c,a.x+mix(0,25,p),a.y-15-p*19,color,v));
}
function differentiate(c,v,t) {
  const types=['bcell','tcell','macrophage','dendritic'],words=['B 细胞','T 细胞','巨噬细胞','树突细胞'];
  types.forEach((name,i)=>{
    const q=i*2-3,p=progress(t),a=ground(c,q,0);
    fade(c,1-p,()=>cell(c,'immune',q,0));fade(c,p,()=>cell(c,name,q,0));
    if(p>0&&p<1) {
      if(v===0)ring(c,a.x,a.y-5,18*(1-p)+4,cyan);
      if(v===1)line(c,a.x-13,a.y-19+p*27,a.x+13,a.y-19+p*27,cyan);
      if(v===2)burst(c,a.x,a.y-5,p,cyan,9,20,true);
    }
    label(c,words[i],a.x,a.y+30);
  });
  label(c,'四种独立分化结果示例',at().x,at(0,-3).y);
}
function respire(c,v,t,cancer) {
  const color=cancer?copper:cyan,p=progress(t),center=at();
  for(const [q,r] of dirs)ground(c,q,r,cancer);
  const actors=cancer?[[-1,0],[1,0]]:[[0,0]];
  if(cancer)for(const [q,r] of dirs)path(c,at(q,r),center,clamp(p*2),color,v);
  actors.forEach(([q,r])=>{
    const a=cell(c,cancer?'melanoma':'immune',q,r);
    if(p>0&&p<1)for(let i=0;i<7+v*2;i++) {
      const f=(p+i/9)%1,x=a.x+Math.cos(i*2.4)*(1-f)*22,y=a.y+(1-f)*18;
      pixel(c,x,y,color,1+i%2);
    }
    if(p>.6)pixel(c,a.x+14,a.y-12,color,2);
  });
}
function stonePatch(c,a,p,v) {
  for(let y=-9;y<=8;y+=3)for(let x=-13;x<=13;x+=3) {
    if(Math.abs(x)+Math.abs(y)*.6>17||((x*7+y*13+101)%23+23)%23>p*24)continue;
    pixel(c,a.x+x,a.y+y,['#899291',stone,'#e1e4e2'][(x+y+60)%3],3);
  }
  if(v===1)ring(c,a.x,a.y,15,stone,.5);
}
function revive(c,v,t,cancer) {
  const a=ground(c,0,0,cancer),p=progress(t),color=cancer?copper:cyan;
  if(cancer)stonePatch(c,a,1-p,v);
  if(p>0&&p<1) {
    if(v===0)burst(c,a.x,a.y-5,p,color,14,25,true);
    if(v===1)for(let i=0;i<8;i++)line(c,a.x-12+i*3,a.y+7,a.x-12+i*3,a.y+7-p*30,color);
    if(v===2)ring(c,a.x,a.y-4,25*(1-p)+5,color,.7);
  }
  fade(c,p,()=>cell(c,cancer?'melanoma':'immune',0,0));
}
function memory(c,v,t) {
  const a=cell(c,'immune',0,0),p=progress(t),dest={x:a.x,y:a.y-38};
  path(c,{x:a.x+18,y:a.y},dest,p,cyan,v);
  for(let i=0;i<4;i++)pixel(c,dest.x-10+i*6,dest.y,i<Math.floor(p*4)?cyan:'#39585a',3);
  if(p>.8)ring(c,dest.x,dest.y+1,16,cyan,.5);
}
function mutate(c,v,t) {
  const a=cell(c,'melanoma',0,0),p=progress(t);
  if(p<.7)for(let i=0;i<9;i++) {
    const y=a.y-23+i*3,x=Math.sin(i+t*5)*7;
    pixel(c,a.x+x,y,copper);pixel(c,a.x-x,y,pink);
  }
  if(p>.55) {
    if(v>0)for(let i=0;i<v;i++) {
      const x=a.x-20-i*8;
      fade(c,1-clamp((p-.55)*2),()=>pixel(c,x,a.y-26,pink,2));
    }
    if(v===2)path(c,a,{x:a.x+28,y:a.y+12},clamp((p-.55)*2),copper,0);
  }
}
function spread(c,v,t,inward) {
  const p=progress(t),center=ground(c,0,0,!inward);
  for(const [q,r] of dirs)ground(c,q,r,inward);
  const targets=inward?[[0,0]]:[dirs[0],dirs[2],dirs[4]];
  for(const [q,r] of targets) {
    const dest=at(q,r);fade(c,p,()=>tile(c,dest.x,dest.y,true));
    const sources=inward?dirs.map(([sq,sr])=>at(sq,sr)):[center];
    if(p>0&&p<1)for(const source of sources) {
      path(c,source,dest,p,pink,v);
      if(v===1)line(c,mix(source.x,dest.x,p),mix(source.y,dest.y,p),dest.x,dest.y,'#924559');
      if(v===2)disc(c,mix(source.x,dest.x,p),mix(source.y,dest.y,p),3,pink,.55);
    }
  }
}
function solidify(c,v,t) {
  const a=ground(c,0,0,true),p=progress(t);stonePatch(c,a,p,v);
  if(v===2&&p>0&&p<1)for(let i=0;i<5;i++)spark(c,a.x-10+i*5,a.y+4-p*12,stone,2);
  cell(c,'melanoma',0,0);
}
function pressure(c,v,t) {
  dirs.forEach(([q,r])=>ground(c,q,r,true));ground(c,0,0);
  const a=cell(c,'immune',0,0),p=progress(t);
  if(p>0&&p<1)dirs.forEach(([q,r],i)=>{
    const b=at(q,r),f=p*.65;
    path(c,b,{x:a.x+(b.x-a.x)*.4,y:a.y+(b.y-a.y)*.4},p,pink,v);
    if(v===1)line(c,mix(b.x,a.x,f)-2,mix(b.y,a.y,f),mix(b.x,a.x,f)+2,mix(b.y,a.y,f),pink,2);
    if(v===2&&i%2===0)ring(c,a.x,a.y,25-p*12,'#bb6579',.7,i,i+.5);
  });
  if(p>.55&&p<1)path(c,a,{x:a.x+20,y:a.y+25},clamp((p-.55)*3),cyan,0);
}
function vessel(c,v,t) {
  const p=progress(t),a=at(-2,0),b=at(2,0),color=v===1?copper:cyan;
  sprite(c,'vessel',a.x,a.y+4);sprite(c,'vessel',b.x,b.y+4);
  fade(c,1-clamp(p*3),()=>cell(c,v===1?'melanoma':'immune',-2,0));
  fade(c,clamp((p-.65)*3),()=>cell(c,v===1?'melanoma':'immune',2,0));
  if(p>0&&p<1) {
    burst(c,a.x,a.y-5,clamp(p*2),color,12,17);
    burst(c,b.x,b.y-5,clamp((p-.5)*2),color,12,17,true);
    if(v===2)for(let i=0;i<5;i++)pixel(c,mix(a.x,b.x,p)-i*4,a.y-22-Math.sin(p*Math.PI)*8,color);
  }
}
export const commonEffects={
  immune_move:(c,v,t)=>moving(c,v,t,false),immune_attack:attack,
  immune_purify:(c,v,t)=>convert(c,v,t,false),immune_draw:(c,v,t)=>draw(c,v,t,false),
  immune_differentiate:differentiate,immune_respire:(c,v,t)=>respire(c,v,t,false),
  immune_revive:(c,v,t)=>revive(c,v,t,false),immune_memory:memory,
  cancer_move:(c,v,t)=>moving(c,v,t,true),cancer_colonize:(c,v,t)=>convert(c,v,t,true),
  cancer_draw:(c,v,t)=>draw(c,v,t,true),cancer_mutate:mutate,
  cancer_respire:(c,v,t)=>respire(c,v,t,true),cancer_revive:(c,v,t)=>revive(c,v,t,true),
  cancer_proliferate:(c,v,t)=>spread(c,v,t,false),cancer_erosion:(c,v,t)=>spread(c,v,t,true),
  cancer_solidify:solidify,cancer_pressure:pressure,shared_vessel:vessel,
};

