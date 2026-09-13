import {letters,initialSelections} from './catalog.js';
import {items,effects,matches} from './registry.js';
import {loadArt,startFrame,board,label,DURATION} from './draw.js';
import {drawTexture} from './textures.js';
import {requestedSelections} from './revised-catalog.js';

const $=id=>document.getElementById(id);
const requestedCard=new URLSearchParams(location.search).get('card');
const cardOption=document.createElement('option');cardOption.value='cards';cardOption.textContent='卡牌粒子';$('filter').append(cardOption);
if(requestedCard){
  document.body.classList.add('cards');$('filter').value='cards';document.title='Cell War · 原贴图卡牌粒子';
  document.querySelector('aside h1').textContent='卡牌粒子';
  document.querySelector('.intro').textContent='原游戏细胞与组织贴图 · 16 张卡牌';
  document.querySelector('.side-note').textContent='优先：范围结算、单体命中、生存状态、能量转移和组织变化。费用与概率卡牌采用轻提示。';
  document.querySelector('.status').textContent='原素材 · 仅 HTML 预览';
}
const storageKey='cellwar-art-r2';
let selections={...initialSelections};
try {
  const saved=JSON.parse(localStorage.getItem(storageKey)??'null');
  if(saved&&typeof saved==='object'&&!Array.isArray(saved)) {
    selections={};
    for(const item of items)if(Number.isInteger(saved[item.id])&&saved[item.id]>=0&&saved[item.id]<3)selections[item.id]=saved[item.id];
  }
}catch { /* Invalid or unavailable browser storage must not hide the design drafts. */ }
try {
  if(localStorage.getItem('cellwar-art-selected-directions-r4')!=='applied') {
    Object.assign(selections,requestedSelections);
    localStorage.setItem(storageKey,JSON.stringify(selections));
    localStorage.setItem('cellwar-art-selected-directions-r4','applied');
  }
}catch {Object.assign(selections,requestedSelections);}
try {
  if(localStorage.getItem('cellwar-art-a-variants-r5')!=='applied') {
    Object.assign(selections,{immune_antibody:0,immune_toxin:0});
    localStorage.setItem(storageKey,JSON.stringify(selections));
    localStorage.setItem('cellwar-art-a-variants-r5','applied');
  }
}catch {Object.assign(selections,{immune_antibody:0,immune_toxin:0});}
const variants=()=>current.variants??[0,1,2];
const isTexture=()=>['marrow','mucus','necrosis'].includes(current.id);
let current=items[0],time=.1,playing=!matchMedia('(prefers-reduced-motion: reduce)').matches;
let contexts=[],ready=false,last=0,lastPaint='';
function summary() {
  return 'Cell War 像素美术选稿 R4（仅 HTML 预览）\n'+items.map(item=>{
    const v=selections[item.id];return `${item.name}：${v===undefined?'未选':letters[v]+' · '+item.names[v]}`;
  }).join('\n');
}
function updateSelections() {
  $('selected-count').textContent=`${items.filter(item=>selections[item.id]!==undefined).length} / ${items.length}`;
  $('picks').replaceChildren(...items.map(item=>{
    const b=document.createElement('button'),v=selections[item.id];
    b.className=v===undefined?'':'picked';b.textContent=`${item.name} / ${v===undefined?'待选择':letters[v]}`;
    b.onclick=()=>open(item);return b;
  }));
  document.querySelectorAll('.study').forEach((card,index)=>{
    const v=variants()[index];
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
  contexts.forEach((c,index)=>{
    const v=variants()[index];
    startFrame(c);
    if(isTexture())drawTexture(c,current.id,v,frameTime);
    else {board(c,$('context').checked);effects[current.id](c,v,frameTime);label(c,'像素草稿 · 格子顶面定位',160,192,'#718970');}
  });
  $('time').value=String(Math.round(time/DURATION*1000));$('seconds').value=`${time.toFixed(2)}s`;
  $('phase').value=current.phases[time<.65?0:time<2.6?1:2];
}
function open(item) {
  current=item;time=item.id==='marrow'?0:.1;
  $('title').textContent=item.name;$('category').textContent=item.group;$('revision').textContent=item.tag;
  $('description').textContent=item.description;$('note').textContent=item.note+(item.palette?` 配色：${item.palette}。`:'');
  document.querySelectorAll('nav button').forEach((b,i)=>{
    b.classList.toggle('active',items[i]===item);b.setAttribute('aria-current',items[i]===item?'page':'false');
  });
  $('studies').classList.toggle('single-study',variants().length===1);
  $('studies').setAttribute('aria-label',variants().length===1?'选定方案优化':'三种像素设计');
  $('studies').replaceChildren(...variants().map(v=>{
    const letter=letters[v];
    const card=document.createElement('article');card.className='study';
    card.innerHTML=`<div class="study-head"><span class="letter">${letter}</span><small>像素逐帧 / HTML</small></div><canvas width="320" height="200" role="img" aria-label="${item.name}方案${letter}像素草稿"></canvas><div class="study-body"><h3>${item.names[v]}</h3><p>${item.details[v]}</p><button></button></div>`;
    card.querySelector('button').onclick=()=>choose(v);return card;
  }));
  contexts=[...document.querySelectorAll('canvas')].map(canvas=>canvas.getContext('2d'));
  const texture=isTexture();
  $('context').disabled=texture;
  for(const id of ['play','replay','time','speed'])$(id).disabled=item.id==='marrow';
  updateSelections();paint(true);
}
items.forEach((item,i)=>{
  const b=document.createElement('button');b.innerHTML=`${item.name}<span>${String(i+1).padStart(2,'0')}</span>`;
  b.onclick=()=>open(item);$('nav').append(b);
});
function filterNavigation() {
  let count=0;
  document.querySelectorAll('#nav button').forEach((b,i)=>{
    b.hidden=!matches(items[i],$('filter').value,$('search').value);
    if(!b.hidden)count++;
  });
  $('results').textContent=count?`${count} 项 / 共 ${items.length} 项`:'没有匹配项目';
}
$('search').oninput=filterNavigation;$('filter').onchange=filterNavigation;filterNavigation();
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
  const data={revision:4,status:'html-preview-only',pixelArt:true,selections:items.map(item=>({id:item.id,name:item.name,variant:letters[selections[item.id]]??null,design:item.names[selections[item.id]]??null}))};
  const content=JSON.stringify(data,null,2);$('summary').hidden=false;$('summary').value=content;
  const url=URL.createObjectURL(new Blob([content],{type:'application/json'}));const a=document.createElement('a');
  a.href=url;a.download='cell-war-art-r4.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  $('feedback').textContent='已请求下载；若浏览器未下载，可复制下方 JSON。';
};
function tick(now) {
  const delta=Math.min(.1,(now-last)/1000);last=now;
  if(playing&&current.id!=='marrow'&&!document.hidden)time=(time+delta*Number($('speed').value))%DURATION;
  paint();requestAnimationFrame(tick);
}
open(items.find(item=>item.id===requestedCard)??current);
try{await loadArt();ready=true;paint(true);requestAnimationFrame(tick);}
catch(error){$('feedback').textContent=`素材未加载成功：${error.message}。请从仓库启动本地预览服务。`;}
