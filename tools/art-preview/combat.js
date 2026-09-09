import {clamp,mix,pixel,line,ring,label,cell,position,spark,burst} from './draw.js';

function reticle(c,x,y,r,v,locked,t) {
  const ink=locked?'#ff6b8a':'#61d7e8';
  if(v===2) {
    for(const dx of [-1,1])for(const dy of [-1,1]) {
      const xx=x+dx*r,yy=y+dy*r;
      line(c,xx,yy,xx-dx*r*.35,yy,ink,2);line(c,xx,yy,xx,yy-dy*r*.35,ink,2);
    }
    ring(c,x,y,r*.8,ink,1);
  } else {
    if(v===0)ring(c,x,y,r,ink);
    else for(let i=0;i<4;i++)ring(c,x,y,r,ink,1,i*Math.PI/2+.15+t*.4,i*Math.PI/2+1.25+t*.4);
    for(let i=0;i<12;i++) {
      const a=i*Math.PI/6;
      line(c,x+Math.cos(a)*(r-3),y+Math.sin(a)*(r-3),x+Math.cos(a)*(r+2),y+Math.sin(a)*(r+2),ink);
    }
  }
  for(let i=0;i<4;i++) {
    const a=i*Math.PI/2;
    line(c,x+Math.cos(a)*r*.57,y+Math.sin(a)*r*.57,x+Math.cos(a)*(r+9),y+Math.sin(a)*(r+9),ink);
  }
  if(!locked){line(c,x-5,y,x+5,y,ink);line(c,x,y-5,x,y+5,ink);}
  else spark(c,x,y-r-10,'#ffd166',2);
}
export function hunt(c,v,t) {
  cell(c,'dendritic',-2,1);
  const target=cell(c,'melanoma',2,-1);
  const search=clamp(t/.65),lock=clamp((t-.65)/.95);
  const eased=1-Math.pow(1-lock,3);
  const x=mix(130+Math.sin(search*4)*22,target.x,lock>0?1:search);
  const y=mix(100,target.y,search);
  const r=Math.round(mix(87,19,eased));
  if(t<.65) {
    const scan=24+search*270;
    line(c,scan,34,scan,168,'#768273');
    label(c,'GLOBAL SEARCH / 全局搜索',160,18,'#c6c8a7');
  } else label(c,t<1.6?'目标发现 · 收缩':'全局通缉 · 目标已捕获',160,18,'#ff8fab');
  reticle(c,x,y,r,v,t>=1.6,t);
}
function antibody(c,x,y,color,size=4) {
  line(c,x,y,x,y+size,color,2);line(c,x,y,x-size,y-size,color,2);line(c,x,y,x+size,y-size,color,2);
}
function seal(c,x,y,v,t,front) {
  const start=front?0:Math.PI,end=start+Math.PI;
  const tilts=v===0?[-.7,.7]:v===1?[0,Math.PI/2]:[-.4,1.1];
  // Both rings keep a radius of 20; only their rune particles move in opposite directions.
  tilts.forEach((tilt,i)=>{
    const color=i===0?'#7de3ff':'#b99cff';
    ring(c,x,y,20,color,.48,start,end,tilt);
    for(let j=0;j<4;j++) {
      const a=(t*(i===0?1:-1)*2+j*Math.PI/2+Math.PI*20)%(Math.PI*2);
      if((a<Math.PI)!==front)continue;
      const u=Math.cos(a)*20,w=Math.sin(a)*20*.48;
      const px=x+u*Math.cos(tilt)-w*Math.sin(tilt),py=y+u*Math.sin(tilt)+w*Math.cos(tilt);
      pixel(c,px,py,color,2);
      if(j===0)spark(c,px,py,'#e7f7ff',2);
    }
  });
}
export function neutralize(c,v,t) {
  const source=cell(c,'bcell',-2,1);
  const targets=[[0,-1],[2,0],[1,-2]];
  targets.forEach((coord,i)=>{
    const tile=position(...coord),target={x:tile.x,y:tile.y-4};
    const p=clamp((t-i*.12)/.95);
    if(p===1)seal(c,target.x,target.y,v,t,false);
    cell(c,'melanoma',...coord);
    if(p<1)antibody(c,mix(source.x,target.x,p),mix(source.y,target.y,p),'#7de3ff');
    else {
      seal(c,target.x,target.y,v,t,true);
      if(t<1.45+i*.12)antibody(c,target.x,target.y-25,'#d9c7ff',3);
    }
  });
  label(c,t<1.2?'抗体投递':'中和封禁 · 双环反向运行',160,18,'#d9e1cd');
}
export function excalibur(c,v,t) {
  const source=cell(c,'tcell',-2,0);
  cell(c,'melanoma',2,0);
  if(t<.65){burst(c,source.x,source.y,t/.65,'#f8dfaa',16,30,true);return;}
  const phase=clamp((t-.65)/1.9),reach=clamp((t-.65)/.55),tip=mix(source.x+17,304,reach),y=source.y;
  if(v===0) {
    line(c,source.x+16,y-2,tip,y-2,'#bc924f',5);line(c,source.x+16,y,tip,y,'#f9eac1',2);
    line(c,tip-8,y-7,tip,y,'#fff5d4');line(c,tip-8,y+7,tip,y,'#fff5d4');
  } else if(v===1) {
    for(let x=source.x+16;x<tip;x++) {
      const d=Math.sin((x-source.x-16)/200*Math.PI)*7;
      pixel(c,x,y+Math.sin(x*.1-t*9)*d,'#e3c071',2);
      pixel(c,x,y-Math.sin(x*.1-t*9)*d,'#fff3c5',2);
    }
    line(c,source.x+16,y,tip,y,'#faf3d4');
  } else {
    const w=Math.max(1,Math.round((1-phase)*9));
    for(let x=source.x+16;x<tip;x++)line(c,x,y-w,x,y+w,'#e1b773');
    line(c,source.x+16,y,tip,y,'#fff7d5',3);line(c,source.x+18,y-14,source.x+18,y+14,'#fff0bd',2);
  }
  if(t>1&&t<2.2)for(const coord of [[1,-1],[2,1]]) {
    const at=position(...coord);burst(c,at.x,at.y,clamp((t-1)/1.2),'#dabb80',8,13);
  }
}
