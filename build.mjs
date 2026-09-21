import {mkdir,copyFile,readFile,writeFile} from 'node:fs/promises';
await mkdir('dist',{recursive:true});
for(const file of ['index.html','app.js','money.js','formats.js','style.css','icon.svg','manifest.webmanifest'])await copyFile(file,'dist/'+file);

const config=JSON.parse(await readFile('vercel.json','utf8'));await writeFile('dist/vercel.json',JSON.stringify({headers:config.headers}));
