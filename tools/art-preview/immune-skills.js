import {clamp,mix,pixel,line,ring,disc,label,cell,position,tile,spark,burst} from './draw.js';
import {headMarker} from './revised-effects.js';

const toxinArea=[[0,0],[1,0],[0,1],[-1,1],[-1,0],[0,-1],[1,-1]];
const colors={ice:'#b7ecff',violet:'#b88aff',fire:'#ff7647',coral:'#ffb5a2',cyan:'#57dedc',mark:'#f28cd6'};
function yGlyph(c,x,y,s,color=colors.ice) {
  line(c,x,y+s,x,y,color,2);line(c,x,y,x-s,y-s,color,2);line(c,x,y,x+s,y-s,color,2);
}
function hex(c,p,color,r=16) {
  const points=[[0,-8],[r,-4],[r,4],[0,8],[-r,4],[-r,-4]];
  points.forEach(([x,y],i)=>{const next=points[(i+1)%6];line(c,p.x+x,p.y+y,p.x+next[0],p.y+next[1],color);});
}
function mark(c,p,v,t) {
  const y=p.y-23;
  if(v===0){line(c,p.x-5,y,p.x,y+5,colors.mark,2);line(c,p.x,y+5,p.x+5,y,colors.mark,2);}
  else if(v===1){ring(c,p.x,y,5,colors.mark);pixel(c,p.x-1,y-1,'#ffe8fa',3);}
  else {line(c,p.x,y-5,p.x+5,y,colors.mark);line(c,p.x+5,y,p.x,y+5,colors.mark);line(c,p.x,y+5,p.x-5,y,colors.mark);line(c,p.x-5,y,p.x,y-5,colors.mark);}
  if(t<2.6)spark(c,p.x+9,y-3,colors.mark,1);
}
function antibody(c,v,t) {
  const origin=cell(c,'bcell',-2,0),targets=[[2,-1],[1,1]];
  const shots=v===1?3:1,flightTime=v===2?.62:.8,impactAt=.65+flightTime;
  for(const [i,[q,r]] of targets.entries()) {
    const p=position(q,r);tile(c,p.x,p.y,true);
    const age=t-impactAt,recoil=age>=0&&age<.3?Math.round(Math.sin(age*42)*(v===2?4:2)):0;
    c.save();c.translate(recoil,0);
    const target=cell(c,i?'signet':'melanoma',q,r);
    c.restore();
    for(let j=0;j<shots;j++) {
      const launch=.65+j*.16,f=clamp((t-launch)/flightTime),hitAge=t-launch-flightTime;
      if(t>=launch&&f<1) {
        const x=mix(origin.x,target.x,f),y=mix(origin.y,target.y,f);
        for(let k=1;k<5;k++){const tail=clamp(f-k*.026);pixel(c,mix(origin.x,target.x,tail),mix(origin.y,target.y,tail),'#5688a5',2);}
        yGlyph(c,x,y,v===2?5:3);
      }
      if(hitAge>=0&&hitAge<.52) {
        const hit=clamp(hitAge/.52);
        burst(c,target.x,target.y,hit,colors.ice,v===1?13:24,v===2?34:25);
        if(hitAge<.12)disc(c,target.x,target.y,v===2?9:6,'#edfaff',.8);
        if(v!==1)ring(c,target.x,target.y,4+hit*(v===2?26:19),'#ccefff',.85);
        if(v===2)for(let k=0;k<6;k++)line(c,target.x+8+hit*18,target.y-10+k*4,target.x+14+hit*24,target.y-10+k*4,'#90d5f4');
      }
    }
  }
  label(c,'Y 形抗体直射 · 命中震动与碎粒',160,35,colors.ice);
}
function toxin(c,v,t) {
  // Terrain is painted before particles, so later tiles cannot erase a flight trail.
  for(const [i,[q,r]] of toxinArea.entries()) {
    const p=position(q,r),delay=v===2?i*.075:0,hit=t>1.3+delay;
    tile(c,p.x,p.y,!hit);
    if(hit)for(let j=0;j<4;j++)line(c,p.x-9+j*6,p.y+2,p.x-7+j*6,p.y-1,'#564451');
  }
  for(const [i,[q,r]] of toxinArea.entries()) {
    const p=position(q,r),delay=v===2?i*.075:0;
    if(i===1||i===4)cell(c,i===4?'signet':'melanoma',q,r);
    for(let shot=0;shot<(v===1?3:1);shot++) {
      const start=.65+delay+shot*.15,f=clamp((t-start)/.65);
      if(t>=start&&f<1)for(let j=0;j<(v===0?4:6);j++) {
        const along=clamp(f-j*.026),spread=(j%3-1)*(v===1?2:3);
        pixel(c,mix(160,p.x,along)+spread,mix(98,p.y,along)-(j%2)*3,colors.violet,2);
      }
      const age=t-start-.65;
      if(age>=0&&age<.35)burst(c,p.x,p.y,age/.35,'#cab0ec',v===1?6:10,10);
    }
  }
  cell(c,'tcell',0,0);
  label(c,'1 环共七格（含脚下）· 新生健康组织保留坏死纹',160,35,colors.violet);
}
function lyse(c,v,t) {
  const p=position(1,0),f=clamp((t-.65)/1.5);tile(c,p.x,p.y,t<2.1);
  if(t<2.1) {
    for(let j=0;j<4;j++)line(c,p.x-11+j*6,p.y-7,p.x-15+j*6,p.y+5,'#d0b394',2);
    if(t>.65)for(let j=0;j<(v===1?5:3);j++) {
      const a=j*2.4+v*.5;
      line(c,p.x,p.y,p.x+Math.cos(a)*15*f,p.y+Math.sin(a)*9*f,colors.fire,2);
    }
    if(v===2&&t>.65){line(c,p.x-17*f,p.y-8,p.x+17*f,p.y+8,'#ffd29e',2);line(c,p.x-17*f,p.y+8,p.x+17*f,p.y-8,colors.fire);}
  } else burst(c,p.x,p.y,clamp((t-2.1)/.7),colors.fire,15,24);
  cell(c,'tcell',0,0);if(t>2.8)hex(c,p,'#a6c8ab');
  label(c,'裂开相邻一格固化癌组织 → 净化',160,35,colors.fire);
}
function phago(c,v,t) {
  const p=position(0,0),attack=v===1;
  tile(c,p.x,p.y,!attack&&t<1.25);
  if(attack){const target=cell(c,'melanoma',1,0);if(t>1&&t<1.7)burst(c,target.x,target.y,clamp((t-1)/.7),colors.coral,9,16);}
  const origin=cell(c,'macrophage',0,0);
  if(t>.65&&t<2.6)for(let j=0;j<(v===2?18:10);j++) {
    const f=clamp((t-.65-j*.025)/1.35),a=j*2.399;
    const x=origin.x+Math.cos(a)*(1-f)*30,y=origin.y+Math.sin(a)*(1-f)*17;
    if(v===2)spark(c,x,y,colors.coral,1);else pixel(c,x,y,colors.coral,2);
  }
  if(t>1.7){spark(c,origin.x,origin.y-23,colors.coral,4);label(c,attack?'恢复实际损失的 1/2（向上取整）':'+0.3 能量',160,151,colors.coral);}
  label(c,attack?'攻击造成能量损失后的被动恢复':'每次净化触发被动恢复',160,35,colors.coral);
}
function chemo(c,v,t) {
  cell(c,'dendritic',-2,1);const p=position(1,-1),f=clamp((t-.65)/.7);
  tile(c,p.x,p.y,false);
  if(t>.65){
    for(let i=0;i<3;i++) {
      const r=6+((t*13+i*12)%36);ring(c,p.x,p.y,r,colors.cyan,.48);
    }
    if(v===0){line(c,p.x,p.y,p.x,p.y-25*f,colors.cyan,2);spark(c,p.x,p.y-25*f,'#d9fff3',4);}
    if(v===1)for(let i=0;i<6;i++){const a=i*Math.PI/3;line(c,p.x+Math.cos(a)*4,p.y+Math.sin(a)*2,p.x+Math.cos(a)*14*f,p.y+Math.sin(a)*7*f,colors.cyan,2);}
    if(v===2){hex(c,p,colors.cyan,12);for(let i=0;i<5;i++)pixel(c,p.x+(i%2?4:-4),p.y-((t*14+i*5)%28),colors.cyan,2);}
  }
  label(c,'远处建立单一趋化源 · 持续 2 回合',160,35,colors.cyan);
}
function autoMark(c,v,t) {
  const origin=cell(c,'dendritic',-1,0),targets=[cell(c,'melanoma',1,0),cell(c,'signet',0,1)];
  if(t>.65&&t<1.5)ring(c,origin.x,origin.y,clamp((t-.65)/.85)*72,colors.mark,.55);
  if(t>1.3)targets.forEach(p=>mark(c,p,v,t));
  label(c,'相邻 2 格内自动标记 · 不造成伤害',160,35,colors.mark);
}
function adhesion(c,v,t) {
  cell(c,'dendritic',-2,1);const source=cell(c,'melanoma',0,0),near=cell(c,'signet',2,0),far=cell(c,'melanoma',3,-1);
  headMarker(c,source,v,t);
  if(t>.65&&t<2.1) {
    const f=clamp((t-.65)/1.2),x=mix(source.x,near.x,f),y=mix(source.y-29,near.y-29,f);
    const ink=['#ff609c','#c39bff','#79e8ff'][v];
    for(let j=0;j<4;j++)pixel(c,x-j*3,y+(j%2),ink,j?1:2);
  }
  if(t>1.9)headMarker(c,near,v,t-1.9);
  label(c,'E 阶段 · 标记传给两格内癌细胞',160,30,colors.mark);
  label(c,'新标记本阶段不继续连锁',far.x-5,far.y+38,'#aeb6b3');
}
function duties(c,v,t) {
  const origin=cell(c,'dendritic',-1,0),target=cell(c,'melanoma',1,0),x=(origin.x+target.x)/2;
  if(t>.65) {
    if(v===0){line(c,x,origin.y-10,x,origin.y+8,'#c6bd99',2);line(c,x-4,origin.y-10,x+4,origin.y-10,'#c6bd99');}
    if(v===1){hex(c,position(0,0),'#9bb9ad');line(c,x-4,origin.y-3,x+4,origin.y+5,'#c6bd99',2);}
    if(v===2){line(c,origin.x+14,origin.y,x-3,origin.y,'#9bb9ad');line(c,x-3,origin.y-4,x-3,origin.y+4,'#c6bd99',2);}
  }
  label(c,'各司其职 · 无法迁移进入癌细胞占据格',160,35,'#c6cfb9');
  label(c,'支援定位 / 行动约束提示',160,153,'#9bb9ad');
}
export const immuneEffects={immune_antibody:antibody,immune_toxin:toxin,immune_lyse:lyse,immune_phago:phago,immune_chemo:chemo,immune_mark:autoMark,immune_adhesion:adhesion,immune_duties:duties};
