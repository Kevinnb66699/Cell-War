import {test,expect} from 'bun:test';
import {loadArt,position} from './draw.js';
import {rupture} from './feeding.js';
import {items,effects,matches} from './registry.js';

const mucusColors=new Set(['#789a42','#b6c970','#e1eaaa','#dfeaaa']);
class PixelCapture {
  fillStyle='';globalAlpha=1;pixels=new Set();stack=[];mask=null;path=[];
  save(){this.stack.push({alpha:this.globalAlpha,mask:this.mask});}
  restore(){const state=this.stack.pop();this.globalAlpha=state.alpha;this.mask=state.mask;}
  beginPath(){this.path=[];}
  rect(x,y,w,h){this.path.push([x,y,w,h]);}
  clip(){this.mask=[...this.path];}
  drawImage(){}
  fillText(){}
  fillRect(x,y,w,h){
    if(!mucusColors.has(this.fillStyle)||this.globalAlpha<=0)return;
    for(let py=y;py<y+h;py++)for(let px=x;px<x+w;px++){
      if(this.mask&&!this.mask.some(([rx,ry,rw,rh])=>px>=rx&&px<rx+rw&&py>=ry&&py<ry+rh))continue;
      this.pixels.add(`${px},${py}`);
    }
  }
}
globalThis.Image=class{width=32;height=34;async decode(){}};
await loadArt();

test('完整目录可逐帧绘制，所有方案坐标有限且画布状态平衡',()=>{
  expect(items.length).toBe(25);
  expect(new Set(items.map(item=>item.id)).size).toBe(items.length);
  let depth=0,draws=0;
  const finite=(...args)=>{for(const value of args)if(typeof value==='number'&&!Number.isFinite(value))throw new Error('Non-finite canvas coordinate');};
  const c={save(){depth++;},restore(){depth--;if(depth<0)throw new Error('Unbalanced restore');},
    beginPath(){},rect:finite,clip(){},fillText:finite,translate:finite,rotate:finite,scale:finite,
    drawImage(image,...args){if(!image)throw new Error('Missing image');finite(...args);draws++;},
    fillRect(...args){finite(...args);draws++;}};
  for(const item of items){
    expect(item.names.length).toBe(3);expect(item.details.length).toBe(3);
    if(['marrow','mucus','necrosis'].includes(item.id))continue;
    expect(typeof effects[item.id]).toBe('function');
    for(let v=0;v<3;v++)for(let f=0;f<44;f++){
      effects[item.id](c,v,f/12);expect(depth).toBe(0);
    }
  }
  expect(draws).toBeGreaterThan(0);
});
test('分类和搜索保留原有七项并覆盖两阵营',()=>{
  expect(items.filter(item=>matches(item,'original','')).length).toBe(8);
  expect(items.filter(item=>matches(item,'all','黏液破裂')).map(item=>item.id)).toEqual(['rupture']);
  for(const item of items.filter(item=>item.id.startsWith('immune_')))expect(matches(item,'immune','')).toBe(true);
  for(const item of items.filter(item=>item.id.startsWith('cancer_')))expect(matches(item,'cancer','')).toBe(true);
  expect(items.filter(item=>matches(item,'all','找不到的技能')).length).toBe(0);
});
test('细胞毒素的一环包含施法者脚下格',()=>{
  const tissueCalls=[];
  const c={fillStyle:'',font:'',textAlign:'',fillRect(){},fillText(){},
    drawImage(image,...args){if(image.src.includes('tissue_'))tissueCalls.push([image.src,...args]);}};
  effects.immune_toxin(c,0,2);
  expect(tissueCalls.filter(([src])=>src.includes('tissue_normal')).length).toBe(7);
  expect(tissueCalls.some(([src,x,y])=>src.includes('tissue_normal')&&x===144&&y===89)).toBe(true);
});

test('黏液只能出现在扩散前沿内，不能先跳到外圈格子',()=>{
  const origin=position(0,0);
  for(const variant of [0,1,2])for(const time of [.7,.9,1.1,1.4,1.7]){
    const capture=new PixelCapture();rupture(capture,variant,time);
    const radius=Math.min(1,(time-.65)/1.1)*92;
    expect(capture.pixels.size).toBeGreaterThan(0);
    for(const key of capture.pixels){
      const [x,y]=key.split(',').map(Number);
      expect(Math.hypot(x-origin.x,(y-origin.y)/.6),`variant ${variant}, time ${time}, pixel ${key} ahead of wave ${radius}`).toBeLessThanOrEqual(radius+2);
    }
  }
});
test('覆盖从内向外累积，重播蓄势期不残留黏液',()=>{
  for(const variant of [0,1,2]){
    let previous=new Set();
    for(const time of [.7,.9,1.1,1.4,1.7,2,3.5]){
      const capture=new PixelCapture();rupture(capture,variant,time);
      for(const key of previous)expect(capture.pixels.has(key)).toBe(true);
      previous=capture.pixels;
    }
    const restart=new PixelCapture();rupture(restart,variant,.1);
    expect(restart.pixels.size).toBe(0);
  }
});
