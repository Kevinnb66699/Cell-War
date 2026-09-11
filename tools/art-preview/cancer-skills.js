import {clamp,mix,pixel,line,ring,disc,label,sprite,position,tile,cell,spark,burst} from './draw.js';

const BLOOD='#dd5265', AMBER='#e5ad63', PINK='#efadc9', BONE='#e0d9c3', STEEL='#8aa9b8', FIRE='#f29550';
const stage=(t,start,length)=>clamp((t-start)/length);
function ground(c,q,r,cancer=false) {const p=position(q,r);tile(c,p.x,p.y,cancer);return p;}
function movingCell(c,name,from,to,p,lift=0) {
  const a=position(...from),b=position(...to),x=mix(a.x,b.x,p),y=mix(a.y,b.y,p);
  disc(c,x,y+3,10,'#1c2925',.3);
  sprite(c,`cells/${name}`,x,y-4-lift);
  return {x,y:y-4-lift};
}
function shards(c,x,y,p,color,count=14) {
  for(let i=0;i<count;i++) {
    const a=i*2.399,r=10+p*(12+i%4*4),xx=x+Math.cos(a)*r,yy=y+Math.sin(a)*r*.65;
    line(c,xx,yy,xx+Math.cos(a)*4,yy+Math.sin(a)*3,color);
  }
}
function plate(c,x,y,a,size,color) {
  const xx=x+Math.cos(a)*23,yy=y+Math.sin(a)*18;
  line(c,xx-Math.sin(a)*size,yy+Math.cos(a)*size,xx+Math.sin(a)*size,yy-Math.cos(a)*size,color,2);
}
function tissueRing(c,p,color,r=17) {ring(c,p.x,p.y+3,r,color,.5);}

function homing(c,v,t) {
  const from=[-2,0],to=[1,0],a=ground(c,...from),b=ground(c,...to,t>1.9);
  sprite(c,'vessel',a.x,a.y+3);
  const neighbors=[[2,0],[1,1],[0,1]];
  neighbors.forEach(([q,r],i)=>ground(c,q,r,t>2.25+i*.2));
  const p=stage(t,.8,1.1);
  if(v===0) {
    for(let k=0;k<8;k++) {
      const u=clamp(p-k*.045),x=mix(a.x,b.x,u),y=a.y-4-Math.sin(u*Math.PI)*28;
      disc(c,x,y,Math.max(1,4-k*.4),k<2?PINK:BLOOD);
    }
  } else if(v===1) {
    for(const at of [a,b]) {
      ring(c,at.x,at.y-5,15+Math.sin(t*5)*2,BLOOD,.75);
      ring(c,at.x,at.y-5,19,PINK,.75,0,t*4);
    }
    if(p>0&&p<1)for(let i=0;i<18;i++) {
      const u=(p+i/18)%1;pixel(c,mix(a.x,b.x,u),a.y-8+Math.sin(u*12+t*5)*5,BLOOD,2);
    }
  } else {
    for(let k=0;k<3;k++) {
      const y=a.y-9+k*7;line(c,a.x,y,mix(a.x,b.x,p),y,BLOOD);
      spark(c,mix(a.x,b.x,p),y,PINK,2);
    }
  }
  if(v===0)movingCell(c,'melanoma',from,to,p,Math.sin(p*Math.PI)*28);
  else cell(c,'melanoma',...(p<.5?from:to));
  if(t>1.9) {
    tissueRing(c,b,BLOOD,17+stage(t,1.9,.5)*4);
    neighbors.forEach((coord,i)=>{if(t>2.25+i*.2)tissueRing(c,position(...coord),BLOOD);});
  }
  label(c,t<1.9?'血管入口 → 空健康组织':'落点定殖 · 相邻最多三格示意',160,166,BLOOD);
}

function pseudopod(c,v,t) {
  const from=[-1,0],to=[0,0],a=ground(c,...from,true),b=ground(c,...to,t>1.7);
  [[1,0],[0,-1],[-1,1]].forEach(coord=>{const p=ground(c,...coord,true);tissueRing(c,p,AMBER,14);});
  const reach=stage(t,.3,1),move=stage(t,1.25,.65);
  if(t<2.2)for(let k=0;k<(v===0?3:v===1?5:2);k++) {
    const spread=(k-(v===0?1:v===1?2:.5))*(v===2?12:5);
    const x=mix(a.x,b.x,reach),y=b.y-5+spread;
    line(c,a.x,a.y-4,x-7,y,'#86532d',3);
    line(c,a.x,a.y-5,x,y,AMBER,v===1?2:1);
    if(v===1)disc(c,x,y,3,'#f5d7a2');
    if(v===2)line(c,x,y,x+5,y-spread*.6,'#f5d7a2',2);
  }
  movingCell(c,'melanoma',from,to,move);
  if(t>1.8)burst(c,b.x,b.y-4,stage(t,1.8,1),AMBER,12,21);
  label(c,'目标邻接三格癌性组织 · 迁移 0.5',160,166,AMBER);
}

function armor(c,v,t) {
  ground(c,0,0,true);const p=cell(c,'signet',0,0),impact=stage(t,.8,.6);
  if(t<1.4)line(c,p.x-64+impact*37,p.y,p.x-47+impact*37,p.y,'#c5c9d3',2);
  if(t<1.65) {
    if(v===0){ring(c,p.x,p.y,23,PINK,.85);ring(c,p.x,p.y,25,'#8b526d',.85);}
    if(v===1)for(let i=0;i<8;i++)disc(c,p.x+Math.cos(i*Math.PI/4)*23,p.y+Math.sin(i*Math.PI/4)*18,4,PINK);
    if(v===2)for(let i=0;i<8;i++)plate(c,p.x,p.y,i*Math.PI/4,6,PINK);
  }
  if(t>1.3&&t<2.2)shards(c,p.x-21,p.y,stage(t,1.3,.9),PINK,v===1?22:12);
  if(t>1.5)ring(c,p.x,p.y,22,'#755064',.85,.4,Math.PI*1.55);
  label(c,t<1.4?'囊甲待命':'本世界回合首次减损已消耗',160,166,PINK);
}

function ossify(c,v,t) {
  const p=ground(c,0,0,true),future=t>=2.2,build=stage(t,future?2.2:.3,future?.8:1);
  const color=future?BONE:STEEL;
  if(v===0)ring(c,p.x,p.y+2,20,color,.56,0,Math.PI*2*build);
  if(v===1)for(let i=0;i<6;i++) {
    const a=i*Math.PI/3,x=p.x+Math.cos(a)*17,y=p.y+3+Math.sin(a)*9;
    line(c,x,y,x,y-build*(future?10:4),color,2);
  }
  if(v===2)for(let i=0;i<5;i++) {
    const x=p.x-14+i*7;line(c,x,p.y+5,x+build*8,p.y-2,color);
    if(future)line(c,x,p.y-2,x+build*8,p.y+5,BONE);
  }
  if(future)for(let i=0;i<12;i++) {
    const a=i*Math.PI/6;pixel(c,p.x+Math.cos(a)*18,p.y+3+Math.sin(a)*10,BONE,2);
  }
  cell(c,'osteo',0,0);
  if(!future&&t<1.5)burst(c,p.x,p.y,1-build,STEEL,10,20,true);
  label(c,future?'两世界回合后 · E阶段固化（压缩演示）':'现在：只标记脚下癌组织',160,166,color);
}

function barrier(c,v,t) {
  const g=ground(c,0,0,true);tissueRing(c,g,BONE,20);
  const p=cell(c,'osteo',0,0),hit=stage(t,.5,1);
  if(v===0)for(let i=0;i<8;i++)plate(c,p.x,p.y,i*Math.PI/4,6,STEEL);
  if(v===1)for(let i=0;i<5;i++)line(c,p.x-24+i*3,p.y+16,p.x-24+i*3,p.y-17, i%2?STEEL:BONE,2);
  if(v===2){ring(c,p.x,p.y,25,STEEL,.82);ring(c,p.x,p.y,21,BONE,.82);}
  if(t<1.5)line(c,p.x-70+hit*43,p.y,p.x-50+hit*27,p.y,'#db7480',3);
  if(t>=1.4&&t<2.4) {
    const k=stage(t,1.4,1);shards(c,p.x-24,p.y,k,STEEL,14);
    line(c,p.x-21+k*16,p.y,p.x-17+k*14,p.y,'#e1a0a5',1);
  }
  label(c,'固化癌组织上 · 承受原能量损失的40%',160,166,STEEL);
}

function minimal(c,v,t) {
  const from=[-1,0],to=[0,0],p=stage(t,.65,1.2);
  ground(c,...from,true);ground(c,...to,t>1.85);
  const at=movingCell(c,'sclc',from,to,p);
  if(v===0)for(let i=0;i<3;i++)line(c,at.x-17-i*4,at.y-5+i*5,at.x-10-i*4,at.y-5+i*5,STEEL);
  if(v===1){ring(c,at.x,at.y,13,'#a3c9d5',.8);ring(c,at.x,at.y,17,STEEL,.8,.5,2.3);}
  if(v===2)for(let i=0;i<6;i++) {
    const a=i*Math.PI/3+t*2;pixel(c,at.x+Math.cos(a)*14,at.y+Math.sin(a)*11,'#b4d2dc',2);
  }
  label(c,'轻量胞浆 · 迁移至健康组织消耗0.7',160,166,STEEL);
}

function jump(c,v,t) {
  const from=[-3,0],to=[2,0],a=position(...from),b=position(...to),p=stage(t,.6,1.2);
  for(let q=-3;q<=2;q++) {
    const tileAt=ground(c,q,0,q===-3||(q===2&&t>=1.8));
    if(q>-3&&q<2)pixel(c,tileAt.x,tileAt.y+17,'#647378',2);
  }
  if(v===0)movingCell(c,'sclc',from,to,p,Math.sin(p*Math.PI)*42);
  if(v===1) {
    cell(c,'sclc',...(p<.5?from:to));
    if(p>0&&p<1)for(let i=0;i<5;i++)line(c,a.x,a.y-7+i*3,mix(a.x,b.x,p),a.y-7+i*3,STEEL);
  }
  if(v===2) {
    cell(c,'sclc',...(p<.5?from:to));
    for(const at of [a,b])ring(c,at.x,at.y-4,12+Math.sin(p*Math.PI)*10,STEEL,.7);
    if(p>0&&p<1)burst(c,p<.5?a.x:b.x,a.y-4,p<.5?p*2:2-p*2,STEEL,20,25);
  }
  if(t>1.8)tissueRing(c,b,STEEL);
  label(c,'五格跃进 · 中途不定殖、不收取',160,166,STEEL);
}

function warburg(c,v,t) {
  ground(c,0,0,true);const p=cell(c,'sclc',0,0),flow=stage(t,.3,1.8);
  for(let i=0;i<10;i++) {
    const u=(flow+i/10)%1,a=i*2.399;
    if(v===0)pixel(c,p.x+Math.cos(a)*(1-u)*42,p.y+Math.sin(a)*(1-u)*28,FIRE,2);
    if(v===1) {
      const x=p.x-36+i*8,y=p.y+16-u*35;
      line(c,x,y,x+4,y-3,i%2?FIRE:'#ffd59a',2);
    }
    if(v===2) {
      const x=p.x+Math.cos(a+t*2)*24,y=p.y+Math.sin(a+t*2)*17;
      line(c,x,y,p.x+Math.cos(a+t*2)*16,p.y+Math.sin(a+t*2)*11,FIRE);
    }
  }
  if(t>1.5){ring(c,p.x,p.y,19+Math.sin(t*5)*2,FIRE,.7);spark(c,p.x,p.y-27,'#ffdda7',4);}
  label(c,t<1.5?'无氧呼吸 · 糖酵解运转':'产出110% · 向上取整到十分位',160,166,FIRE);
}

export const cancerEffects={cancer_homing:homing,cancer_pseudopod:pseudopod,cancer_armor:armor,
  cancer_ossify:ossify,cancer_barrier:barrier,cancer_minimal:minimal,cancer_jump:jump,cancer_warburg:warburg};
