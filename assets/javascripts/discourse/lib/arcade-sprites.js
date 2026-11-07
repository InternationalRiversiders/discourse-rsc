// Original merge_qshp artwork, preserved byte-for-byte. See public/arcade/merge/source.json.
export const mergeSpriteFiles = Object.freeze(["00-973df787c094.png", "01-22a658c02581.png", "02-690977014d67.png", "03-3f62e392f2c9.png", "04-799a4a503725.png", "05-977c9c41d76b.png", "06-906829a14b81.png", "07-544ca786e264.png", "08-336ebbcf460a.png", "09-bb68a2bb9cd6.png", "10-bce7f4a63be4.png"]);
const loads=new Map();
export function loadMergeSprites(base='/plugins/discourse-rsc/arcade/merge/'){
 if(!loads.has(base)){
  loads.set(base,Promise.all(mergeSpriteFiles.map(file=>new Promise(resolve=>{
   const img=new Image();img.decoding='async';img.onload=()=>resolve(img);img.onerror=()=>resolve(null);img.src=base+file;
  }))).then(images=>{if(images.some(img=>!img)){loads.delete(base);}return images;}));
 }
 return loads.get(base);
}
