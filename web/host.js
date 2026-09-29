// Keep installer sizes current without downloading the installers themselves.
let checked = false;
async function updateDownloadSizes() {
  if (checked || location.pathname !== '/host') return;
  checked = true;
  await Promise.allSettled([
    ['windows', '/download/GameNight-Setup.exe'],
    ['macos', '/download/GameNight.dmg'],
  ].map(async ([platform, url]) => {
    const response = await fetch(url, { method: 'HEAD', signal: AbortSignal.timeout(5000) });
    const bytes = Number(response.headers.get('content-length'));
    if (!response.ok || !Number.isFinite(bytes) || bytes <= 0) return;
    const label = document.querySelector(`[data-download-size="${platform}"]`);
    if (label) label.textContent = `${(bytes / 1e6).toFixed(1)} MB`;
  }));
}
window.addEventListener('gamenight-page-change', updateDownloadSizes);
void updateDownloadSizes();

// Draw the same native-pixel outfit and face composition as the character editor.
// Only a single idle frame is needed; these illustrations have no animation loop.
let hostOutfit;
function loadHostOutfit() {
  if (!hostOutfit) hostOutfit = new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => { hostOutfit = null; reject(new Error('Could not load lobby outfit')); };
    image.src = '/assets/characters/living-room';
  });
  return hostOutfit;
}
async function renderHostCharacters() {
  const data = document.getElementById('host-character-data');
  if (location.pathname !== '/host' || !data) return;
  const targets = document.querySelectorAll('.host-guide canvas');
  if ([...targets].every(canvas => canvas.dataset.rendered === 'true')) return;
  try {
    const outfit = await loadHostOutfit();
    const faces = JSON.parse(data.content.textContent);
    const palette = {cheeky:'#87dec8',pirate:'#ffa594',surprised:'#c1a3fa',grin:'#f3d083'};
    const sprites = {};
    for (const [id, runs] of Object.entries(faces)) {
      const sprite = document.createElement('canvas');sprite.width=96;sprite.height=80;
      const context = sprite.getContext('2d');context.imageSmoothingEnabled=false;
      context.drawImage(outfit,0,0,96,80,0,0,96,80);
      const pixels=context.getImageData(0,0,96,80),rgb=[1,3,5].map(i=>parseInt(palette[id].slice(i,i+2),16));
      for(let i=0;i<pixels.data.length;i+=4){
        if(!pixels.data[i+3])continue;
        const skin=pixels.data[i]>200&&pixels.data[i+1]>170&&pixels.data[i+2]<pixels.data[i+1];
        const shade=skin?pixels.data[i]/245:Math.max(pixels.data[i],pixels.data[i+1],pixels.data[i+2])/255;
        for(let channel=0;channel<3;channel++)pixels.data[i+channel]=Math.min(255,Math.round(rgb[channel]*shade));
      }
      context.putImageData(pixels,0,0);
      context.clearRect(34,18,30,27);
      context.fillStyle=palette[id];context.beginPath();context.arc(51,32,12,0,Math.PI*2);context.fill();
      for(const [x,y,width,color] of runs){context.fillStyle=color;context.fillRect(27+x,4+y,width,1);}
      sprites[id]=sprite;
    }
    for(const canvas of targets){
      const context=canvas.getContext('2d');context.imageSmoothingEnabled=false;
      context.clearRect(0,0,canvas.width,canvas.height);
      if(canvas.dataset.hostPerson){
        context.drawImage(sprites[canvas.dataset.hostPerson],16,4,64,72,0,0,64,72);
      }else if(canvas.classList.contains('host-lobby-crew')){
        const crew=[['cheeky',366,397,false],['pirate',370,546,true],['surprised',598,345,false],['grin',670,546,true]];
        for(const [id,x,y,flip] of crew){
          context.save();context.translate(x+(flip?96:0),y);context.scale(flip?-1:1,1);
          context.drawImage(sprites[id],0,0);context.restore();
        }
        canvas.dataset.faces=crew.map(([id])=>id).join(',');
      }
      canvas.dataset.rendered='true';
    }
  }catch(error){console.warn(error.message);}
}
window.addEventListener('gamenight-page-change',renderHostCharacters);
void renderHostCharacters();
