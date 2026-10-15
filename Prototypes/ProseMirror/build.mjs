// Throwaway prototype: npm ci && npm run build. The result runs offline by itself.
import {build} from 'esbuild';
import {readFile, writeFile, readdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';

const result = await build({entryPoints:[fileURLToPath(new URL('main.js', import.meta.url))],
  bundle:true, write:false, format:'iife', target:'safari17', minify:true, legalComments:'inline'});
const template = await readFile(new URL('shell.html', import.meta.url), 'utf8');
const editorCSS = await readFile(new URL('node_modules/prosemirror-view/style/prosemirror.css', import.meta.url), 'utf8');
const css = await readFile(new URL('style.css', import.meta.url), 'utf8');
const html = template.replace('/* STYLES */', editorCSS+'\n'+css)
  .replace('/* SCRIPT */', result.outputFiles[0].text.replaceAll('</script', '<\\/script'));
await writeFile(new URL('../../Sources/Luna/Resources/ProseMirrorPrototype.html', import.meta.url), html);

// Preserve every bundled runtime dependency's notice, including transitive packages.
const lock = JSON.parse(await readFile(new URL('package-lock.json', import.meta.url), 'utf8'));
let notices = 'Luna ProseMirror prototype — bundled runtime licenses\n';
for (const [name, pkg] of Object.entries(lock.packages)) {
  if (!name || pkg.dev) continue;
  const directory=new URL(name+'/',import.meta.url);
  const filename=(await readdir(directory)).find(file=>/^licen[cs]e(?:[-.]|$)/i.test(file));
  if(!filename)throw new Error('Missing license for '+name);
  const license=await readFile(new URL(filename,directory),'utf8');
  notices += '\n\n'+name.replace('node_modules/','')+' '+pkg.version+'\n'+license;
}
await writeFile(new URL('../../Sources/Luna/Resources/ProseMirrorPrototype-LICENSES.txt', import.meta.url), notices);
console.log('Built offline ProseMirrorPrototype.html ('+Math.round(Buffer.byteLength(html)/1024)+' KB)');
