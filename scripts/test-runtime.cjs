const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const runtime=path.resolve(process.argv[2]);
const meta=JSON.parse(fs.readFileSync(path.join(runtime,'profile-runtime.json'),'utf8'));
function archive(root){
  const bytes=fs.readFileSync(path.join(root,'resources/app.asar'));
  const header=JSON.parse(bytes.subarray(16,16+bytes.readUInt32LE(12)));
  const base=8+bytes.readUInt32LE(4),files=new Map();
  function visit(tree,dir=''){for(const [name,entry] of Object.entries(tree)){
    const key=dir+name;
    if(entry.files)visit(entry.files,key+'/');
    else files.set(key,{entry,data:entry.offset===undefined?null:bytes.subarray(base+Number(entry.offset),base+Number(entry.offset)+entry.size)});
  }}
  visit(header.files);return files;
}
const before=archive(meta.source),after=archive(runtime);
assert.deepEqual([...before.keys()].sort(),[...after.keys()].sort());
let patched=0;
for(const [name,a] of before){
  const b=after.get(name);
  if(/^\.vite\/build\/bootstrap-.*\.js$/.test(name)){
    patched++;assert.match(b.data.toString(),/profile-bootstrap\.cjs/);
    assert.equal(crypto.createHash('sha256').update(b.data).digest('hex'),b.entry.integrity.hash);
  }else assert.deepEqual(b.data,a.data,name);
}
assert.equal(patched,1);
for(const name of ['ChatGPT.exe','resources/codex.exe','resources/codex-windows-sandbox-setup.exe']){
  const hash=root=>crypto.createHash('sha256').update(fs.readFileSync(path.join(root,name))).digest('hex');
  assert.equal(hash(runtime),hash(meta.source),name);
}
console.log(`PASS: ${before.size} archive entries checked; only bootstrap differs; application, CLI and sandbox helper binaries match the installed package.`);
