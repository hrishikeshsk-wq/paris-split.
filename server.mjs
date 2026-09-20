import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {resolve,extname,sep} from 'node:path';
const root=resolve(import.meta.dirname);
const mime={'.html':'text/html','.js':'text/javascript','.mjs':'text/javascript','.css':'text/css','.svg':'image/svg+xml','.json':'application/json','.webmanifest':'application/manifest+json'};
http.createServer(async(req,res)=>{try{
 const pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
 const review=pathname.startsWith('/review/');
 const file=resolve(root,review?pathname.slice(8):pathname==='/'?'index.html':pathname.slice(1));
 if(!file.startsWith(root+sep)||file.includes(`${sep}.git${sep}`)||(!review&&pathname.startsWith('/backend/')))throw Error();
 const data=await readFile(file);res.writeHead(200,{'Content-Type':review?'text/plain; charset=utf-8':(mime[extname(file)]||'text/plain')+'; charset=utf-8','Cache-Control':'no-store'});res.end(data);
}catch{res.writeHead(404);res.end('Not found');}}).listen(4173,'127.0.0.1',()=>console.log('Paris Split http://127.0.0.1:4173'));
