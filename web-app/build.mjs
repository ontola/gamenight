import { build } from 'esbuild';
import { compile } from 'svelte/compiler';
import { readFile } from 'node:fs/promises';
await build({entryPoints:['src/main.ts'],outfile:'../web/shell.js',bundle:true,format:'iife',target:'es2022',minify:true,define:{'process.env.NODE_ENV':'"production"'},legalComments:'eof',plugins:[{
  name:'svelte',setup(build){build.onLoad({filter:/\.svelte$/},async({path})=>({contents:compile(await readFile(path,'utf8'),{filename:path,generate:'client',css:'external'}).js.code,loader:'js'}));}
}]});
