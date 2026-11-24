// Build-time extraction only. No browser or JavaScript runtime on the phone.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname,'../..');
const html = fs.readFileSync(path.join(root,'AiboOS/Web/index.html'),'utf8');
const take = (a,b) => {
  const start = html.indexOf(a), end = html.indexOf(b,start+1);
  if(start<0||end<0)throw Error('AiboOS source boundary missing: '+a);
  return html.slice(start,end);
};
if(!html.includes("const VERSION = '1.8';"))throw Error('Expected AiboOS 1.8');
const order = take('const APP_ORDER =','const DEFAULTS =');
const dock = html.match(/dock: (\['phone', 'messages', 'aibobrowser', 'camera'\])/);
if(!dock)throw Error('Default dock missing');
const names = take('const APP_NAMES =','const APPS =');
const icons = take('function mkIcon(','function iconURL(');
const ctx = vm.createContext({result:null},{codeGeneration:{strings:false,wasm:false}});
vm.runInContext(order+names+'const WDAYS=["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"];'+icons+
  'const dock='+dock[1]+';const home=APP_ORDER.filter(id=>!dock.includes(id));'+
  'result={home,dock,icons:[...home,...dock].map(id=>({id,name:APP_NAMES[id]||id,svg:id==="aibostore"?null:id==="clock"?clockIconSVG():id==="calendar"?calIconSVG():(ICON_SRC[id]||ICON_SRC.notes)()}))};',ctx,{timeout:2000});
const out=process.argv[2];
if(!out)throw Error('Output directory required');
fs.mkdirSync(out,{recursive:true});
const data=ctx.result;
if(data.home.length!==14||data.dock.length!==4||new Set(data.icons.map(x=>x.id)).size!==18)throw Error('Unexpected original app layout');
for(const item of data.icons){
  if(!/^[a-z0-9]+$/.test(item.id))throw Error('Invalid icon id');
  const svg=item.svg||fs.readFileSync(path.join(root,'AiboOS/Web/logo.svg'),'utf8');
  if(!svg.includes('<svg'))throw Error('Invalid SVG');
  fs.writeFileSync(path.join(out,item.id+'.svg'),svg);
}
fs.writeFileSync(path.join(out,'layout.json'),JSON.stringify({version:'1.8',home:data.home,dock:data.dock,apps:data.icons.map(({id,name})=>({id,name})),limitations:'Original icon artwork and layout; native app implementations pending. Clock/calendar artwork reflects export time.'},null,2)+'\n');
console.log('PASS exported 18 original AiboOS 1.8 icons and layout');
