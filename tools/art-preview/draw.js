export const WIDTH = 320;
export const HEIGHT = 200;
export const DURATION = 3.6;
const images = new Map();
export const assetNames = ['tissue_normal','tissue_cancer','cells/dendritic','cells/macrophage','cells/bcell','cells/tcell','cells/signet','cells/melanoma'];
export async function loadArt() {
  await Promise.all(assetNames.map(async name => {
    const image = new Image();
    image.src = `../../game/assets/art/${name}.png`;
    await image.decode();
    images.set(name,image);
  }));
}
export const clamp = value => Math.max(0,Math.min(1,value));
export const mix = (a,b,t) => a+(b-a)*t;
export function pixel(c,x,y,color,size=1) {
  c.fillStyle=color;
  c.fillRect(Math.round(x),Math.round(y),size,size);
}
export function line(c,x,y,xx,yy,color,width=1) {
  const n=Math.ceil(Math.max(Math.abs(xx-x),Math.abs(yy-y),1));
  for(let i=0;i<=n;i++)pixel(c,mix(x,xx,i/n),mix(y,yy,i/n),color,width);
}
export function ring(c,x,y,r,color,squash=1,start=0,end=Math.PI*2,tilt=0) {
  for(let a=start;a<=end;a+=1/Math.max(24,r*2)) {
    const u=Math.cos(a)*r,v=Math.sin(a)*r*squash;
    pixel(c,x+u*Math.cos(tilt)-v*Math.sin(tilt),y+u*Math.sin(tilt)+v*Math.cos(tilt),color);
  }
}
export function disc(c,x,y,r,color,squash=1) {
  for(let j=-Math.ceil(r*squash);j<=r*squash;j++)
    for(let i=-Math.ceil(r);i<=r;i++)
      if(i*i/(r*r)+j*j/(r*r*squash*squash)<=1)pixel(c,x+i,y+j,color);
}
export function label(c,word,x,y,color='#a4b2a8') {
  c.fillStyle=color;c.font='8px "Microsoft YaHei"';c.textAlign='center';c.fillText(word,x,y);
}
export function sprite(c,name,x,y,scale=1) {
  const img=images.get(name);
  c.drawImage(img,Math.round(x-img.width*scale/2),Math.round(y-img.height*scale/2),Math.round(img.width*scale),Math.round(img.height*scale));
}
// All preview tiles and actors use the same axial projection as board.gd.
export function position(q,r) {return {x:160+q*36+r*18,y:102+r*20};}
export function tile(c,x,y,cancer=false) {sprite(c,cancer?'tissue_cancer':'tissue_normal',x,y+4);}
export function board(c,show) {
  if(!show)return;
  for(let r=-3;r<=3;r++)for(let q=-3;q<=3;q++) {
    const {x,y}=position(q,r);
    if(x<18||x>302)continue;
    tile(c,x,y,q>=0&&(r+q)%3!==0);
  }
}
export function cell(c,name,q,r) {
  const at=position(q,r);
  disc(c,at.x,at.y+3,10,'#1c2925',.3);
  sprite(c,`cells/${name}`,at.x,at.y-4);
  return {...at,y:at.y-4};
}
export function spark(c,x,y,color,size=3) {
  line(c,x-size,y,x+size,y,color);line(c,x,y-size,x,y+size,color);
}
export function burst(c,x,y,p,color,count=20,radius=45,inward=false) {
  for(let i=0;i<count;i++) {
    const a=i*2.399,d=(inward?1-p:p)*(radius+i%5*2);
    pixel(c,x+Math.cos(a)*d,y+Math.sin(a)*d*.7,color,1+i%2);
  }
}
export function startFrame(c) {
  c.imageSmoothingEnabled=false;c.globalAlpha=1;c.fillStyle='#101a19';c.fillRect(0,0,WIDTH,HEIGHT);
}
