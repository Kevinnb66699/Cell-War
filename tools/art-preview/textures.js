import {tile,pixel,line,disc,ring,label} from './draw.js';

export function tissueHex(c,x,y,top,side) {
  for(let row=-10;row<=18;row++) {
    const span=Math.floor(16-Math.max(0,-row-5,row-13)*3.2);
    line(c,x-span,y+row,x+span,y+row,side);
  }
  for(let row=-10;row<=10;row++) {
    const span=Math.floor(16-Math.max(0,Math.abs(row)-5)*3.2);
    line(c,x-span,y+row,x+span,y+row,top);
  }
}
export function necrosis(c,x,y,v=0) {
  const palettes=[['#686761','#393d3b','#939084'],['#726356','#403e39','#a49278'],['#666e69','#343f3e','#9caaa0']];
  const [base,dark,light]=palettes[v];tissueHex(c,x,y,base,dark);
  line(c,x-9,y-2,x-3,y,dark);line(c,x-3,y,x+2,y-3,dark);
  line(c,x+5,y+4,x+10,y+3,dark);
  pixel(c,x-8,y+4,light,2);pixel(c,x+7,y-5,light,2);
}
export function marrow(c,x,y,v,cancer=false,empty=false) {
  const palettes=[['#69644f','#b2a17c','#e2d3a6','#ab6250'],['#5d6955','#9ba486','#ced1ad','#b0765e'],['#715747','#baa486','#e4d3b4','#a75844']];
  const [dark,bone,light,red]=palettes[v];
  tissueHex(c,x,y,bone,dark);
  for(let row=-8;row<=8;row++)for(let col=-14;col<=14;col++) {
    if(Math.abs(col)>16-Math.max(0,Math.abs(row)-5)*3.2)continue;
    const seed=Math.abs(col*23+row*41+col*row*7);
    if(seed%19<6)pixel(c,x+col,y+row,seed%3?dark:light);
    if(!empty&&seed%31<3)pixel(c,x+col,y+row,red);
  }
  const core=empty?(cancer?'#8d6456':'#727765'):red;
  if(v===0) {
    disc(c,x,y,10,dark,.7);disc(c,x,y,7,core,.65);
    for(const [a,b,aa,bb] of [[-8,-5,6,5],[-8,4,8,-4],[-2,-7,0,7]])line(c,x+a,y+b,x+aa,y+bb,bone,2);
    [[-7,-5],[6,-4],[0,5]].forEach(([a,b])=>pixel(c,x+a,y+b,light,2));
    if(!empty){pixel(c,x-5,y+1,'#d89a75',2);pixel(c,x+4,y-1,'#d89a75',2);}
  } else if(v===1) {
    for(let i=0;i<6;i++) {
      const a=i*Math.PI/3,px=x+Math.cos(a)*7,py=y+Math.sin(a)*5;
      disc(c,px,py,4,dark);disc(c,px,py-1,3,bone);pixel(c,px-1,py-2,light);
    }
    disc(c,x,y,4,dark);disc(c,x,y,2,core);
  } else {
    for(let j=-6;j<=6;j++){const span=8-Math.floor(Math.abs(j)/2);line(c,x-span,y+j,x+span,y+j,dark);}
    for(let j=-5;j<=5;j++)line(c,x-5,y+j,x+5,y+j,bone);
    for(let j=-4;j<=4;j++)line(c,x-3,y+j,x+3,y+j,core);
    line(c,x-5,y-5,x-5,y+3,light);pixel(c,x+4,y-5,light,2);
    if(!empty)pixel(c,x-2,y-2,'#e4a48b',2);
  }
}
export function mucus(c,x,y,v,t=0,amount=1) {
  c.save();c.globalAlpha=.68*amount;
  if(v===0) {
    disc(c,x,y+1,11,'#789a42',.5);disc(c,x-3,y,8,'#b6c970',.45);
    line(c,x-9,y+1,x-6,y-2,'#e1eaaa');line(c,x+5,y+3,x+9,y+1,'#e1eaaa');pixel(c,x+3,y-2,'#dfeaaa',2);
  } else if(v===1) {
    for(let i=0;i<5;i++) {
      const px=x-8+i*4,py=y+Math.sin(i*2+Math.floor(t*6)%3)*3;
      disc(c,px,py,5,'#849b43');ring(c,px,py-1,3,'#d8eaa0',.7,3.2,5.7);
    }
    line(c,x-9,y+2,x-7,y+8,'#99b458',2);line(c,x+8,y+2,x+7,y+6,'#b4cc77');
  } else {
    disc(c,x,y,10,'#788945',.55);
    for(let i=0;i<7;i++){const a=i*2.4;line(c,x,y,x+Math.cos(a)*12,y+Math.sin(a)*7,'#c2d980');}
    [[-6,-2],[3,3],[6,-3]].forEach(([a,b])=>{disc(c,x+a,y+b,3,'#93b151');pixel(c,x+a,y+b-1,'#f0ebaf');});
  }
  c.restore();
}
export function drawTexture(c,id,v,t) {
  if(id==='necrosis') {
    for(let i=0;i<3;i++) {
      const x=55+i*105;c.save();c.translate(x,77);c.scale(2,2);necrosis(c,0,0,v);c.restore();
      necrosis(c,x,145,v);label(c,'低密度裂纹',x,125);
    }
    label(c,'坏死组织 · 整格灰褐暗纹',160,187);
  } else if(id==='marrow') {
    [[false,false],[true,false],[false,true],[true,true]].forEach(([cancer,empty],i)=>{
      const x=40+i*80;c.save();c.translate(x,68);c.scale(2,2);marrow(c,0,0,v,cancer,empty);c.restore();
      label(c,['健康 · 有卡','癌变 · 有卡','健康 · 空仓','癌变 · 空仓'][i],x,112);
      marrow(c,x,146,v,cancer,empty);
    });
    label(c,'上：2× 细节　下：1× 原尺寸 · 骨白 / 髓红',160,187);
  } else {
    for(let i=0;i<3;i++) {
      const x=55+i*105;c.save();c.translate(x,83);c.scale(2,2);
      if(i===2)marrow(c,0,0,0);else tile(c,0,0,i===1);
      mucus(c,0,0,v,t);c.restore();label(c,['健康底色','癌变底色','骨髓叠加'][i],x,137);
    }
    label(c,'半透明覆膜 · 保留底层组织识别',160,180);
  }
}
