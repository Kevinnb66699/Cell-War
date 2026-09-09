import {items,letters,initialSelections} from './catalog.js';
import {loadArt,startFrame,board,label,DURATION} from './draw.js';
import {drawTexture} from './textures.js';
import {hunt,neutralize,excalibur} from './combat.js';
import {chain,rupture} from './feeding.js';

const $=id=>document.getElementById(id);
const storageKey='cellwar-art-r2';
const effects={hunt,neutralize,excalibur,chain,rupture};
let selections={...initialSelections};
try {
  const saved=JSON.parse(localStorage.getItem(storageKey)??'null');
  if(saved&&typeof saved==='object'&&!Array.isArray(saved)) {
    selections={};
    for(const item of items)if(Number.isInteger(saved[item.id])&&saved[item.id]>=0&&saved[item.id]<3)selections[item.id]=saved[item.id];
  }
}catch { /* Invalid or unavailable browser storage must not hide the design drafts. */ }
let current=items[0],time=.1,playing=!matchMedia('(prefers-reduced-motion: reduce)').matches;
let contexts=[],ready=false,last=0,lastPaint='';
function summary() {
  return 'Cell War 像素美术选稿 R2（待实装）\n'+items.map(item=>{
    const v=selections[item.id];return `${item.name}：${v===undefined?'未选':letters[v]+' · '+item.names[v]}`;
  }).join('\n');
}
function updateSelections() {
  $('selected-count').textContent=`${Object.keys(selections).length} / ${items.length}`;
  $('picks').replaceChildren(...items.map(item=>{
    const b=document.createElement('button'),v=selections[item.id];
    b.className=v===undefined?'':'picked';b.textContent=`${item.name} / ${v===undefined?'待选择':letters[v]}`;
    b.onclick=()=>open(item);return b;
  }));
  document.querySelectorAll('.study').forEach((card,v)=>{
    const selected=selections[current.id]===v,b=card.querySelector('button');
    card.classList.toggle('chosen',selected);b.textContent=selected?`✓ 已选 ${letters[v]}`:`选择 ${letters[v]}`;
    b.setAttribute('aria-pressed',String(selected));
  });
  $('summary').value=summary();
}
function choose(v) {
  if(selections[current.id]===v)delete selections[current.id];else selections[current.id]=v;
  try{localStorage.setItem(storageKey,JSON.stringify(selections));$('feedback').textContent='已保存这份搭配。完成后复制清单发回对话。';}
  catch{$('feedback').textContent='浏览器无法保存，请复制下方清单留存。';$('summary').hidden=false;}
  updateSelections();
}
function paint(force=false) {
  if(!ready)return;
  const frameTime=Math.floor(time*12)/12;
  const key=`${current.id}/${frameTime}/${$('context').checked}`;
  if(!force&&key===lastPaint)return;
  lastPaint=key;
  contexts.forEach((c,v)=>{
    startFrame(c);
    if(current.id==='marrow'||current.id==='mucus')drawTexture(c,current.id,v,frameTime);
    else {board(c,$('context').checked);effects[current.id](c,v,frameTime);label(c,'像素草稿 · 格子顶面定位',160,192,'#718970');}
  });
  $('time').value=String(Math.round(time/DURATION*1000));$('seconds').value=`${time.toFixed(2)}s`;
  $('phase').value=current.phases[time<.65?0:time<2.6?1:2];
}
function open(item) {
  current=item;time=item.id==='marrow'?0:.1;
  $('title').textContent=item.name;$('category').textContent=item.group;$('revision').textContent=item.tag;
  $('description').textContent=item.description;$('note').textContent=item.note;
  document.querySelectorAll('nav button').forEach((b,i)=>{
    b.classList.toggle('active',items[i]===item);b.setAttribute('aria-current',items[i]===item?'page':'false');
  });
  $('studies').replaceChildren(...letters.map((letter,v)=>{
    const card=document.createElement('article');card.className='study';
    card.innerHTML=`<div class="study-head"><span class="letter">${letter}</span><small>R2 / 像素逐帧</small></div><canvas width="320" height="200" role="img" aria-label="${item.name}方案${letter}像素草稿"></canvas><div class="study-body"><h3>${item.names[v]}</h3><p>${item.details[v]}</p><button></button></div>`;
    card.querySelector('button').onclick=()=>choose(v);return card;
  }));
  contexts=[...document.querySelectorAll('canvas')].map(canvas=>canvas.getContext('2d'));
  const texture=item.id==='marrow'||item.id==='mucus';
  $('context').disabled=texture;
  for(const id of ['play','replay','time','speed'])$(id).disabled=item.id==='marrow';
  updateSelections();paint(true);
}
items.forEach((item,i)=>{
  const b=document.createElement('button');b.innerHTML=`${item.name}<span>0${i+1}</span>`;
  b.onclick=()=>open(item);$('nav').append(b);
});
function setPlaying(value) {playing=value;$('play').textContent=value?'暂停':'播放';}
setPlaying(playing);
$('play').onclick=()=>setPlaying(!playing);
$('replay').onclick=()=>{time=0;setPlaying(true);paint(true);};
$('time').oninput=()=>{time=Number($('time').value)/1000*DURATION;setPlaying(false);paint(true);};
$('context').onchange=()=>paint(true);
$('copy').onclick=async()=>{
  $('summary').hidden=false;$('summary').value=summary();
  try{await navigator.clipboard.writeText(summary());$('feedback').textContent='已复制。请把选稿清单粘贴回对话。';}
  catch{$('summary').focus();$('summary').select();$('feedback').textContent='请手动复制下方选稿内容。';}
};
$('download').onclick=()=>{
  const data={revision:2,status:'draft-selection',pixelArt:true,selections:items.map(item=>({id:item.id,name:item.name,variant:letters[selections[item.id]]??null,design:item.names[selections[item.id]]??null}))};
  const content=JSON.stringify(data,null,2);$('summary').hidden=false;$('summary').value=content;
  const url=URL.createObjectURL(new Blob([content],{type:'application/json'}));const a=document.createElement('a');
  a.href=url;a.download='cell-war-art-r2.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  $('feedback').textContent='已请求下载；若浏览器未下载，可复制下方 JSON。';
};
function tick(now) {
  const delta=Math.min(.1,(now-last)/1000);last=now;
  if(playing&&current.id!=='marrow'&&!document.hidden)time=(time+delta*Number($('speed').value))%DURATION;
  paint();requestAnimationFrame(tick);
}
open(current);
try{await loadArt();ready=true;paint(true);requestAnimationFrame(tick);}
catch(error){$('feedback').textContent=`素材未加载成功：${error.message}。请从仓库启动本地预览服务。`;}
