import {resolve,relative,extname,sep} from 'node:path';

const root=resolve(import.meta.dir,'../..');
const types={'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.png':'image/png','.ttf':'font/ttf'};
const port=Number(Bun.env.ART_PREVIEW_PORT??4317);
Bun.serve({hostname:'127.0.0.1',port,async fetch(request){
  let pathname;
  try{pathname=decodeURIComponent(new URL(request.url).pathname);}catch{return new Response('Bad request',{status:400});}
  if(pathname==='/')return Response.redirect(new URL('/tools/art-preview/index.html?card=card_radiation',request.url),302);
  const path=resolve(root,'.'+pathname),inside=relative(root,path);
  const allowed=inside.startsWith(`tools${sep}art-preview${sep}`)||inside.startsWith(`game${sep}assets${sep}art${sep}`)||inside.startsWith(`game${sep}assets${sep}fonts${sep}`);
  if(!allowed||!types[extname(path)])return new Response('Not found',{status:404});
  const file=Bun.file(path);if(!await file.exists())return new Response('Not found',{status:404});
  return new Response(file,{headers:{'Content-Type':types[extname(path)],'Cache-Control':'no-store'}});
}});
console.log(`Cell War art: http://127.0.0.1:${port}/tools/art-preview/index.html?card=card_radiation`);
