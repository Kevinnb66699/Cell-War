import {clamp,mix,pixel,line,ring,disc,label,sprite,position,tile,spark,burst} from './draw.js';
import {mucus} from './textures.js';

function maw(c,x,y,r,opening,direction,v) {
  const membrane=['#c6684b','#d98658','#ba5464'][v];
  for(let dy=-r;dy<=r;dy++)for(let dx=-r;dx<=r;dx++) {
    const d=Math.hypot(dx,dy);
    if(d>r)continue;
    const a=Math.atan2(Math.sin(Math.atan2(dy,dx)-direction),Math.cos(Math.atan2(dy,dx)-direction));
    if(Math.abs(a)<opening&&d>1)continue;
    const color=d>r-2?'#ffd0ad':d>r-4?membrane:'#743a3d';
    pixel(c,x+dx,y+dy,color);
  }
  const nx=x-Math.cos(direction)*r*.35,ny=y-Math.sin(direction)*r*.35;
  disc(c,nx,ny,4,'#f49682');pixel(c,nx-1,ny-2,'#ffe1d0',2);
  for(const side of [-1,1]) {
    const a=direction+side*opening;
    line(c,x+Math.cos(a)*3,y+Math.sin(a)*3,x+Math.cos(a)*(r-1),y+Math.sin(a)*(r-1),'#ffe2d0');
    if(opening>.25)pixel(c,x+Math.cos(a)*(r-4),y+Math.sin(a)*(r-4),'#fff0e7',2);
  }
}
function powered(c,x,y,level,t,v) {
  const count=6+level*4;
  for(let i=0;i<count;i++) {
    const p=(t*.7+i/count)%1,a=i*2.4;
    const radius=15+level*2;
    const px=x+Math.cos(a)*radius,py=y+10-p*37+Math.sin(a)*5;
    pixel(c,px,py,p>.65?'#ffcfb1':'#ef7758',1+(i%4===0?1:0));
    if(v===2&&i%5===0)line(c,px,py+5,px,py,'#ff9e8c');
  }
  for(let i=0;i<level;i++)spark(c,x-8+i*8,y-25,'#ffe2c9',2);
}
export function chain(c,v,t) {
  const path=[[-2,1],[-1,1],[0,0],[1,0]];
  const progress=clamp((t-.35)/2.25)*3;
  const step=Math.min(2,Math.floor(progress)),f=progress>=3?1:progress-step;
  const source=position(...path[step]),target=position(...path[step+1]);
  const lunge=clamp((f-.16)/.43);
  const sprint=lunge*lunge*(3-2*lunge);
  const x=Math.round(mix(source.x,target.x,sprint)),y=Math.round(mix(source.y,target.y,sprint))-4;
  const bitten=f>.61;
  const level=step+(bitten?1:0);
  // Food dots stand for tissue fragments; no cancer actor is invented on an empty destination.
  path.forEach((coord,i)=>{
    const p=position(...coord);
    const cleaned=i<=step||(i===step+1&&bitten);
    tile(c,p.x,p.y,!cleaned);
    if(i>step&&!cleaned){disc(c,p.x,p.y-3,3,'#d49c77');pixel(c,p.x-1,p.y-5,'#f7d5a0',2);}
  });
  const direction=Math.atan2(target.y-source.y,target.x-source.x);
  if(lunge>0&&lunge<1) {
    for(let i=1;i<=3;i++)line(c,x-Math.cos(direction)*(i*8+8),y+i*4-7,x-Math.cos(direction)*(i*8+14),y+i*4-7,'#da795c',2);
  }
  const bite=clamp((f-.56)/.18);
  let opening=t<.35?.15:bitten?.06:.3+Math.sin(clamp(f/.58)*Math.PI)*.95;
  if(v===1&&!bitten)opening=Math.max(opening,1.1);
  const radius=13+level+(v===1?2:0);
  powered(c,x,y,level,t,v);
  disc(c,x,y+9,radius,'#1b2d21',.3);
  maw(c,x,y,radius,opening,direction,v);
  if(f>.57&&f<.94) {
    const impact=clamp((f-.57)/.37);
    burst(c,target.x,target.y-4,impact,'#edaf94',14+v*8,22+v*5);
    if(v===0){line(c,x+12,y-12,x+20,y-17,'#ffccb0',2);line(c,x+14,y+7,x+21,y+12,'#ffccb0',2);}
    if(v===1)ring(c,x,y,18+Math.floor(impact*10),'#ef9d85',.7);
    if(v===2)burst(c,x,y,bite,'#ffbec0',18,29,true);
  }
  label(c,t<.35?'强化启动':level===3?'强化 III · 持续粒子':'吞噬 '+level+' / 3',160,25,'#f7bd9c');
}
function clipWave(c,origin,radius) {
  c.beginPath();
  for(let y=-Math.floor(radius*.6);y<=Math.floor(radius*.6);y++){
    const span=Math.floor(Math.sqrt(Math.max(0,radius*radius-y*y/.36)));
    c.rect(origin.x-span,origin.y+y,span*2+1,1);
  }
  c.clip();
}
export function rupture(c,v,t) {
  const origin=position(0,0);
  if(t<.65) {
    const p=t/.65;
    sprite(c,'cells/signet',origin.x,origin.y-4,1+Math.floor(p*3)/12);
    pixel(c,origin.x-7,origin.y-11,'#d7da92',2);
    return;
  }
  const p=clamp((t-.65)/1.1);
  const radius=p*92;
  if(p<=0)return;
  c.save();
  clipWave(c,origin,radius);
  for(let r=-2;r<=2;r++)for(let q=Math.max(-2,-r-2);q<=Math.min(2,-r+2);q++) {
    const at=position(q,r);
    mucus(c,at.x,at.y,0,t);
  }
  c.restore();
  if(p<1) {
    if(v===0) {
      ring(c,origin.x,origin.y,radius,'#dbe6a0',.6);
      burst(c,origin.x,origin.y,p,'#b4c76e',20,82);
    } else if(v===1) {
      for(let i=0;i<12;i++) {
        const a=i*Math.PI/6,reach=p*82;
        const x=origin.x+Math.cos(a)*reach,y=origin.y+Math.sin(a)*reach*.6-Math.sin(p*Math.PI)*17;
        line(c,x-Math.cos(a)*11,y-Math.sin(a)*7,x,y,'#b6cd73',2);
        disc(c,x,y,3,'#e0e5a1',.7);
      }
    } else {
      for(let i=0;i<3;i++)ring(c,origin.x,origin.y,Math.max(0,radius-i*3),'#c5d283',.6);
      for(let i=0;i<14;i++) {
        const a=i*2.4,r=25+i%5*11;
        const x=origin.x+Math.cos(a)*r,y=origin.y+Math.sin(a)*r*.6-(1-p)*35;
        pixel(c,x,y,'#dce7ac',2);line(c,x,y-4,x,y,'#91ad54');
      }
    }
  }
}
