import {clamp,mix,pixel,line,ring,disc,cell,position,tile,sprite,burst} from './draw.js';
import {necrosis,tissueHex} from './textures.js';

const dirs=[[1,0],[1,-1],[0,-1],[-1,0],[-1,1],[0,1]];
const phase=(t,start,length)=>clamp((t-start)/length);
function trail(c,a,b,p,color,count=7) {
  for(let i=0;i<count;i++) {
    const f=clamp(p-i*.035);pixel(c,mix(a.x,b.x,f),mix(a.y,b.y,f),color,i<2?2:1);
  }
}
export function lyse(c,v,t) {
  const a=cell(c,'tcell',-1,0),b=position(1,0),detonate=[1.65,1.85,1.9][v],hit=phase(t,detonate,.8);
  const ink=['#ff8958','#efb96e','#8edee7'][v];
  if(t<detonate){tissueHex(c,b.x,b.y,'#b2aa91','#676962');
    for(let i=0;i<5;i++)line(c,b.x-12+i*6,b.y+5,b.x-8+i*6,b.y-6,'#e4dfc8',2);
  }else necrosis(c,b.x,b.y,v);
  if(t>.4&&t<detonate)for(let i=0;i<(v===1?3:4);i++) {
    const p=phase(t,.4+i*(v===1?.27:.18),.5),end={x:b.x+(v===1?(i-1)*9:0),y:b.y-4};
    if(p>0&&p<1){trail(c,a,end,p,ink,4);disc(c,mix(a.x,end.x,p),mix(a.y,end.y,p),v===1?3:2,'#fff0cb');}
    if(p===1)disc(c,end.x+(v===1?0:-6+i*4),end.y,2,ink);
  }
  if(t>=detonate&&t<detonate+.85) {
    if(v===0){burst(c,b.x,b.y-4,hit,ink,24,35);ring(c,b.x,b.y-4,hit*29,'#ffe3b9',.75);}
    if(v===1)for(let i=0;i<3;i++) {
      const local=phase(t,detonate+i*.17,.4);
      if(t>=detonate+i*.17&&local<1){burst(c,b.x-10+i*10,b.y-3,local,ink,10,18);disc(c,b.x-10+i*10,b.y-4,3*(1-local),'#fff1ce');}
    }
    if(v===2)for(let i=0;i<16;i++) {
      const x=b.x-14+(i%8)*4,y=b.y-5-Math.sin(hit*Math.PI)*32+(i%3)*3;
      line(c,x,y,x+(i%2?2:-2),y+6,ink,2);
      pixel(c,x+hit*(i-8),y+10,'#e5f7ef',2);
    }
  }
}
export function headMarker(c,p,v,t) {
  const y=p.y-29,k=phase(t,.3,.6),ink=['#ff609c','#c39bff','#79e8ff'][v];
  const size=5+Math.round((1-k)*13);
  line(c,p.x,y-size,p.x+size,y,ink,2);line(c,p.x+size,y,p.x,y+size,ink,2);
  line(c,p.x,y+size,p.x-size,y,ink,2);line(c,p.x-size,y,p.x,y-size,ink,2);
  pixel(c,p.x-1,y-1,'#fff0ff',3);
  for(const side of [-1,1]) {
    line(c,p.x+side*9,y+3,p.x+side*14,y-2,ink,2);
    line(c,p.x+side*14,y-2,p.x+side*14,y-7,ink);
  }
  for(let i=0;i<4;i++){const a=i*Math.PI/2+t*2;pixel(c,p.x+Math.cos(a)*18,y+Math.sin(a)*10,ink,2);}
}
export function marker(c,v,t) {headMarker(c,cell(c,'melanoma',0,0),v,t);}
export function homing(c,v,t) {
  const a=position(-2,0),b=position(1,0),p=phase(t,.7,1.25);
  const infected=[[2,0],[1,1],[0,1]].map(([q,r],i)=>({...position(q,r),start:2.25+i*.18}));
  tile(c,a.x,a.y,false);sprite(c,'vessel',a.x,a.y+3);tile(c,b.x,b.y,t>1.95);
  infected.forEach(at=>tile(c,at.x,at.y,t>=at.start));
  for(const [at,arrival] of [[a,false],[b,true]]) {
    const open=arrival?phase(t,.85,.45):1-phase(t,1.65,.6);
    if(open>0){ring(c,at.x,at.y-7,19*open,'#dd5265',.85);ring(c,at.x,at.y-7,16*open,'#ffc1d3',.85,t*3,t*3+4.7);}
  }
  if(p>0&&p<1)for(let i=0;i<13;i++) {
    const f=clamp(p-i*.022),x=mix(a.x,b.x,f),y=a.y-7+Math.sin(f*Math.PI*4)*4;
    pixel(c,x,y,i%3?'#dc536d':'#ffd1db',i%4?2:3);
  }
  c.save();c.globalAlpha=p<.5?1-clamp(p*2):clamp((p-.5)*2);
  cell(c,'melanoma',...(p<.5?[-2,0]:[1,0]));c.restore();
  if(t>1.95&&t<2.5)burst(c,b.x,b.y-4,phase(t,1.95,.55),'#f7a0b7',17,23);
  for(const at of infected) {
    const approach=phase(t,at.start-.25,.25),spread=phase(t,at.start,.65);
    if(approach>0&&approach<1)trail(c,b,at,approach,'#dc738b',5);
    if(t>=at.start&&spread<1) {
      c.save();c.globalAlpha=1-spread;
      for(let i=0;i<9;i++) {
        const angle=i*2.399,radius=3+spread*13;
        pixel(c,at.x+Math.cos(angle)*radius,at.y+Math.sin(angle)*radius*.45-spread*7,i%3?'#dc738b':'#ffd1db',i%3?1:2);
      }
      c.restore();
    }
  }
}
export function pseudopod(c,v,t) {
  const from={q:-1,r:0},to={q:0,r:0};
  const origin=position(from.q,from.r),target=position(to.q,to.r),p=phase(t,1.15,.85),reach=phase(t,.5,.6),retract=phase(t,2.05,.5);
  const actor={x:mix(origin.x,target.x,p),y:mix(origin.y,target.y,p)-5};
  const neighboringTissues=dirs.map(([dq,dr])=>({q:to.q+dq,r:to.r+dr,cancer:true}));
  const roots=neighboringTissues.filter(a=>a.cancer&&!(a.q===from.q&&a.r===from.r)).map(a=>position(a.q,a.r));
  [...neighboringTissues,{...to,cancer:p===1}].map(a=>({...position(a.q,a.r),cancer:a.cancer}))
    .sort((a,b)=>a.y-b.y||a.x-b.x).forEach(a=>tile(c,a.x,a.y,a.cancer));
  const sprout=phase(t,.2,.3)*(1-retract);
  if(sprout>0)for(const a of roots) {
    disc(c,a.x,a.y,3*sprout,'#704449',.6);
    line(c,a.x,a.y,a.x,a.y-4*sprout,'#cb807d',2);
  }
  const arm=a=>{
    const angle=Math.atan2(a.y-actor.y,a.x-actor.x),grip={x:actor.x+Math.cos(angle)*9,y:actor.y+Math.sin(angle)*7};
    const extension=reach*(1-retract),end={x:mix(a.x,grip.x,extension),y:mix(a.y,grip.y,extension)};
    if(extension<=0)return;
    const points=Array.from({length:17},(_,i)=>{const f=i/16;return {x:mix(a.x,end.x,f),y:mix(a.y,end.y,f)-Math.sin(f*Math.PI)*(8+v*4)*extension};});
    for(const [color,width,offset] of [['#593941',4,0],['#cb807d',2,-1]])for(let i=1;i<points.length;i++) {
      line(c,points[i-1].x,points[i-1].y+offset,points[i].x,points[i].y+offset,color,width);
    }
    disc(c,end.x,end.y-1,2,'#f3b7a3');
  };
  roots.filter(a=>a.y<=actor.y).forEach(arm);
  cell(c,'melanoma',-1+p,0);
  roots.filter(a=>a.y>actor.y).forEach(arm);
}
export function armor(c,v,t) {
  const p=position(0,0),color=['#bd91a8','#91a9bc','#92b4aa'][v];
  const shields=Array.from({length:2},(_,i)=>{
    const angle=t*.85+i*Math.PI;
    return {x:p.x+Math.cos(angle)*18,y:p.y-3+Math.sin(angle)*7,front:Math.sin(angle)>=0};
  });
  const drawShield=s=>{
    c.save();c.globalAlpha=.42;
    line(c,s.x-3,s.y-3,s.x+3,s.y-3,color);
    line(c,s.x-3,s.y-3,s.x-2,s.y+1,color);line(c,s.x+3,s.y-3,s.x+2,s.y+1,color);
    line(c,s.x-2,s.y+1,s.x,s.y+3,color);line(c,s.x+2,s.y+1,s.x,s.y+3,color);
    c.restore();
  };
  shields.filter(s=>!s.front).forEach(drawShield);cell(c,'signet',0,0);
  shields.filter(s=>s.front).forEach(drawShield);
}
export function ossify(c,v,t) {
  const p=position(0,0),grow=phase(t,1.9,1),bones=['#ded5b8','#d2dcd8','#e7c9a5'];
  tissueHex(c,p.x,p.y,'#846d68','#4e4d49');
  const branch=(i,front)=>{
    const x=p.x-17+i*8.5,y=p.y+(front?10:-6),g=clamp(grow*1.5-i*.07),height=front?8:21;
    line(c,x,y,x,y-2-g*height,g>0?bones[v]:'#a3918a',2);
    if(g>0){line(c,x,y-g*height*.45,x-4,y-g*height*.8,bones[v],2);line(c,x,y-g*height*.6,x+3,y-g*height,'#faf0d6');}
  };
  for(let i=0;i<5;i++)branch(i,false);
  cell(c,'osteo',0,0);
  for(let i=0;i<5;i++)branch(i,true);
  if(t<1.6)for(let i=0;i<8;i++){const a=i*2.4;pixel(c,p.x+Math.cos(a)*17,p.y+Math.sin(a)*10,'#d1bcac',2);}
  if(grow>0&&grow<1)burst(c,p.x,p.y,grow,'#d6c8a9',12,24,true);
}
export function barrier(c,v,t) {
  const p=position(0,0),palette=[['#72665a','#cbbb97','#f0e2bd'],['#59676b','#a7c0c4','#deeded'],['#7a665d','#d1ad93','#f3dcc4']][v];
  tissueHex(c,p.x,p.y,palette[0],'#363d3c');
  disc(c,p.x,p.y+3,15,'#303938',.45);disc(c,p.x,p.y+1,14,palette[1],.42);
  disc(c,p.x,p.y,11,palette[0],.4);
  const teeth=dirs.map(([q,r])=>({x:p.x+q*13+r*6.5,y:p.y+r*7})).sort((a,b)=>a.y-b.y);
  const tooth=a=>{
    const direction=Math.sign(a.x-p.x),height=v===2?9:6;
    for(let k=0;k<height;k++) {
      const half=3*(1-k/height),x=a.x+direction*k*.28;
      line(c,x-half,a.y-k,x+half,a.y-k,palette[1]);
      pixel(c,x-half,a.y-k,palette[2]);
    }
  };
  teeth.filter(a=>a.y<p.y).forEach(tooth);cell(c,'osteo',0,0);
  teeth.filter(a=>a.y>=p.y).forEach(tooth);
}
export function anaerobic(c,v,t) {
  const center=position(0,0),p=phase(t,.4,2.1);
  const connected=[[0,0],...dirs,[2,0],[2,-1],[-2,1],[-2,0]];
  for(const [q,r] of connected){const a=position(q,r);tile(c,a.x,a.y,true);
    if((q||r)&&p>0&&p<1)for(let i=0;i<3;i++) {
      const f=(p*1.6+i/3)%1,end={x:center.x,y:center.y-5};
      trail(c,a,end,f,['#e58b65','#edb184','#d97c9b'][v],5);
    }
  }
  cell(c,'melanoma',0,0);
  if(p>.5)for(let i=0;i<6;i++)pixel(c,center.x-9+i*3,center.y-18-((t*9+i*3)%14),'#f5c79a',2);
}
export const revisedEffects={immune_lyse:lyse,mark_visual:marker,cancer_homing:homing,
  cancer_pseudopod:pseudopod,cancer_armor:armor,cancer_ossify:ossify,cancer_barrier:barrier,cancer_respire:anaerobic};
