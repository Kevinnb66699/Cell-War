import {position,tile,cell,pixel,line,burst,clamp,mix,sprite} from './draw.js';
import {necrosis} from './textures.js';
import {anaerobic} from './revised-effects.js';

const phase=(t,s,d)=>clamp((t-s)/d),dirs=[[1,0],[1,-1],[0,-1],[-1,0],[-1,1],[0,1]];
const area=[];
function headMarker(c,p,v,t){const y=p.y-29,s=5+Math.round((1-phase(t,0,.6))*10),ink='#ff609c';line(c,p.x,y-s,p.x+s,y,ink);line(c,p.x+s,y,p.x,y+s,ink);line(c,p.x,y+s,p.x-s,y,ink);line(c,p.x-s,y,p.x,y-s,ink);for(const side of [-1,1]){line(c,p.x+side*9,y+3,p.x+side*14,y-2,ink);line(c,p.x+side*14,y-2,p.x+side*14,y-7,ink);}pixel(c,p.x,y,'#eaf8fc',2);}
for(let r=-2;r<=2;r++)for(let q=-2;q<=2;q++)if(Math.max(Math.abs(q),Math.abs(r),Math.abs(q+r))<=2)area.push([q,r]);
function ground(c,q,r,cancer){const p=position(q,r);tile(c,p.x,p.y,cancer);return p;}
function dust(c,p,f,color,r=23,inward=false){if(f>0&&f<1){c.save();c.globalAlpha=Math.min(1,(1-f)*4);burst(c,p.x,p.y-4,f,color,16,r,inward);c.restore();}}
function flow(c,a,b,f,color){if(f<=0||f>=1)return;for(let i=0;i<7;i++){const p=clamp(f-i*.035);pixel(c,mix(a.x,b.x,p),mix(a.y,b.y,p)-7,color,i?1:2);}}
function actor(c,name,q,r,alpha=1,recoil=0){c.save();c.globalAlpha=alpha;c.translate(Math.round(recoil),0);const p=cell(c,name,q,r);c.restore();return p;}
function blessingShield(c,p,t){
  if(t<.35||t>=2.3)return;
  const shrink=phase(t,.35,.8),ease=1-(1-shrink)**3;
  const scale=mix(2.1,1,ease);
  const opacity=phase(t,.35,.15)*(1-phase(t,1.75,.55)),cy=p.y-5;
  const profile=[[0,-17],[9,-14],[13,-10],[12,3],[8,10],[0,16],[-8,10],[-12,3],[-13,-10],[-9,-14]];
  const points=profile.map(([x,y])=>({x:Math.round(p.x+x*scale),y:Math.round(cy+y*scale)}));
  c.save();c.globalAlpha=opacity*.1;
  for(let y=points[0].y;y<=Math.round(cy+16*scale);y++){
    const intersections=[];
    for(let i=0;i<points.length;i++){
      const a=points[i],b=points[(i+1)%points.length];
      if((a.y<=y&&b.y>y)||(b.y<=y&&a.y>y))intersections.push(a.x+(y-a.y)*(b.x-a.x)/(b.y-a.y));
    }
    intersections.sort((a,b)=>a-b);
    if(intersections.length>=2)line(c,Math.ceil(intersections[0]),y,Math.floor(intersections.at(-1)),y,'#30d1fa');
  }
  for(const [color,width,alpha] of [['#141f2e',3,.55],['#30d1fa',1,.8]]){
    c.globalAlpha=opacity*alpha;
    for(let i=0;i<points.length;i++){const a=points[i],b=points[(i+1)%points.length];line(c,a.x,a.y,b.x,b.y,color,width);}
  }
  c.globalAlpha=opacity*.9;
  for(const i of [7,8,9]){const a=points[i],b=points[(i+1)%points.length];line(c,a.x,a.y,b.x,b.y,'#9cdff1');}
  c.globalAlpha=opacity*.5;
  for(const side of [-1,1])line(c,p.x+side*9*scale,cy+3*scale,p.x+side*6*scale,cy+9*scale,'#9cdff1');
  const crestY=cy-12*scale;
  c.globalAlpha=opacity*.85;
  line(c,p.x,crestY-2*scale,p.x+2*scale,crestY,'#eaf8fc');
  line(c,p.x+2*scale,crestY,p.x,crestY+2*scale,'#9cdff1');
  line(c,p.x,crestY+2*scale,p.x-2*scale,crestY,'#30d1fa');
  line(c,p.x-2*scale,crestY,p.x,crestY-2*scale,'#9cdff1');
  c.restore();
}
function ranged(c,key,t){
  const region=key==='radiation'?area.filter(([q,r])=>!(q===-2||q===2&&r===0)):key==='inflammation'?[[0,0],...dirs]:area;
  const color=key==='inflammation'?'#ffb03a':key==='radiation'?'#e8d9a0':'#30d1fa';
  for(const [q,r] of region){ground(c,q,r,key==='storm'&&t>1.65&&!(q===1&&r===0)?false:q>0);if(key==='radiation'&&t>1.65){const p=position(q,r);necrosis(c,p.x,p.y,0);}}
  if(key!=='radiation'){cell(c,'immune',0,0);actor(c,'melanoma',1,0,1,t>1.65&&t<2.1?Math.sin(t*50)*2:0);}
  region.forEach(([q,r],i)=>{const p=position(q,r),f=phase(t,.45+i*.02,1);if(key==='radiation'&&f>0&&f<1)line(c,p.x,p.y-55+f*40,p.x,p.y-38+f*30,color);else dust(c,p,f,color,17);dust(c,p,phase(t,1.65,.65),color,17);});
}
function hit(c,key,t){
  const acid=key==='acid',target=acid?[0,0]:[1,0],a=ground(c,-1,0,acid),b=ground(c,...target,!acid);
  const neighbors=[[2,-1],[1,1]];
  if(key==='cascade')neighbors.forEach(([q,r],i)=>ground(c,q,r,t<2.4+i*.2));
  cell(c,acid?'melanoma':key==='granule'?'tcell':'bcell',-1,0);
  actor(c,acid?'immune':'melanoma',...target,1,t>1.45&&t<2?Math.sin(t*48)*2:0);
  const color=acid?'#c980a0':key==='granule'?'#ffb03a':'#9cdff1',f=phase(t,.5,.9);
  if(key==='antibody'&&f>0&&f<1){const x=mix(a.x,b.x,f),y=a.y-7;line(c,x,y+4,x,y,color,2);line(c,x,y,x-4,y-4,color,2);line(c,x,y,x+4,y-4,color,2);}
  else for(let i=0;i<3;i++)flow(c,a,b,phase(t,.45+i*.16,.7),color);
  dust(c,b,phase(t,1.45,.65),color,25);
  if(key==='cascade')neighbors.forEach(([q,r],i)=>{const p=position(q,r);flow(c,b,p,phase(t,1.8+i*.2,.6),color);dust(c,p,phase(t,2.4+i*.2,.6),color,14);});
}
function support(c,key,t){
  const a=ground(c,-1,0,false),b=ground(c,1,0,key==='mark'),p=position(0,0),f=phase(t,.5,1.1);
  if(key==='transfer'){cell(c,'immune',-1,0);cell(c,'immune',1,0);for(let i=0;i<3;i++)flow(c,a,b,phase(t,.5+i*.25,.8),'#30d1fa');dust(c,b,phase(t,1.3,1.1),'#9cdff1',22,true);}
  if(key==='teleport'){actor(c,'immune',-1,0,1-f);actor(c,'immune',1,0,phase(t,1.65,.8));dust(c,a,f,'#30d1fa');dust(c,b,phase(t,1.65,.8),'#9cdff1',23,true);}
  if(key==='mark'){cell(c,'dendritic',-1,0);const target=cell(c,'melanoma',1,0);flow(c,{x:a.x,y:a.y-21},{x:b.x,y:b.y-21},f,'#ff609c');if(t>1.6)headMarker(c,target,0,t-1.6);}
  if(key==='repair'){cell(c,'immune',0,0);blessingShield(c,p,t);}
  if(key==='survive'){ground(c,0,0,true);actor(c,'melanoma',0,0,t<1.4?1-f*.65:.35+phase(t,1.4,.9)*.65);dust(c,p,t<1.4?phase(t,.5,.9):phase(t,1.4,.9),'#c980a0',23,t>=1.4);}
}
function tissue(c,key,t){
  if(key==='energy'){anaerobic(c,0,t);return;}
  if(key==='degrade'){const p=ground(c,1,0,true);if(t<1.65)sprite(c,'solidify/tissue_cancer_20_0',p.x,p.y+4);cell(c,'immune',0,0);dust(c,p,phase(t,.55,1.1),'#e8d9a0');}
  if(key==='clone'){ground(c,0,0,true);dirs.slice(0,3).forEach(([q,r],i)=>ground(c,q,r,t>1.3+i*.3));cell(c,'melanoma',0,0);dirs.slice(0,3).forEach(([q,r],i)=>{const p=position(q,r);flow(c,position(0,0),p,phase(t,.5+i*.3,.8),'#c980a0');dust(c,p,phase(t,1.3+i*.3,.55),'#ffb03a',14);});}
  if(key==='blood'){const coords=[[-1,0],[1,0],[0,1]];coords.forEach(([q,r])=>ground(c,q,r,true));coords.forEach(([q,r],i)=>{cell(c,'melanoma',q,r);dust(c,position(q,r),phase(t,.5+i*.06,1.3),'#c980a0',i===0?30:23,true);});}
}
const keys=['radiation','storm','inflammation','antibody','granule','acid','cascade','transfer','teleport','mark','repair','survive','energy','degrade','clone','blood'];
export const cardEffects=Object.fromEntries(keys.map(key=>[`card_${key}`,(c,v,t)=>{
  if(['radiation','storm','inflammation'].includes(key))ranged(c,key,t);
  else if(['antibody','granule','acid','cascade'].includes(key))hit(c,key,t);
  else if(['transfer','teleport','mark','repair','survive'].includes(key))support(c,key,t);
  else tissue(c,key,t);
}]));
