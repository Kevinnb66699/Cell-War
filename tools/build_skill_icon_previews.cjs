// Export the picker's actual candidate pixels; no second copy of the icon designs.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(__dirname, 'skill_icon_picker.html'), 'utf8');
const script = html.split('<script>')[1].split('</script>')[0];
const data = vm.runInNewContext(script.split('const skills=')[0] + ';({S,C})');
const candidates = [];
for (const skill of Object.values(data.S)) {
  skill.v.forEach((ops, i) => {
    const rects = ops.map(([color, x, y, w, h]) => {
      if (!data.C[color] || ![x,y,w,h].every(Number.isInteger) || x<0 || y<0 || x+w>16 || y+h>16) throw Error('Invalid pixel: '+skill.key);
      return `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${data.C[color]}"/>`;
    }).join('');
    candidates.push({key:skill.key, name:skill.name, variant:'ABC'[i], svg:`<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">${rects}</svg>`});
  });
}
if (candidates.length !== 39) throw Error('Expected 39 candidates');
const out = path.join(__dirname, 'skill-icon-renders');
fs.mkdirSync(out, {recursive:true});
fs.writeFileSync(path.join(out, 'candidates.json'), JSON.stringify(candidates, null, 2)+'\n');
console.log('Exported 39 candidate SVGs, all integer coordinates: '+out);
