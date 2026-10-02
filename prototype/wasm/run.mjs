// node run.mjs <module.wasm> [args...]: run a wasm32-wasi command module under node's WASI
import { readFile } from 'node:fs/promises';
import { WASI } from 'node:wasi';

const wasi = new WASI({ version: 'preview1', args: process.argv.slice(2) });
const mod = await WebAssembly.compile(await readFile(process.argv[2]));
wasi.start(await WebAssembly.instantiate(mod, wasi.getImportObject()));
