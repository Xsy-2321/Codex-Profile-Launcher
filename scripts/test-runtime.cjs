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
const originalExe=fs.readFileSync(path.join(meta.source,'ChatGPT.exe'));
const runtimeExe=fs.readFileSync(path.join(runtime,'ChatGPT.exe'));
if(meta.archiveIntegrity){
  const {archiveHeaderHash}=require('./prepare-runtime.cjs');
  const {offset,before:originalHash,after:patchedHash}=meta.archiveIntegrity;
  assert.equal(originalHash,archiveHeaderHash(path.join(meta.source,'resources/app.asar')));
  assert.equal(patchedHash,archiveHeaderHash(path.join(runtime,'resources/app.asar')));
  assert.equal(originalExe.subarray(offset,offset+64).toString(),originalHash);
  assert.equal(runtimeExe.subarray(offset,offset+64).toString(),patchedHash);
  const normalized=Buffer.from(runtimeExe);
  normalized.write(originalHash,offset,64,'ascii');
  assert.deepEqual(normalized,originalExe,'Only the ASAR resource digest may differ in ChatGPT.exe');
}else assert.deepEqual(runtimeExe,originalExe,'ChatGPT.exe');
for(const name of ['resources/codex.exe','resources/codex-windows-sandbox-setup.exe']){
  const hash=root=>crypto.createHash('sha256').update(fs.readFileSync(path.join(root,name))).digest('hex');
  assert.equal(hash(runtime),hash(meta.source),name);
}
console.log(`PASS: ${before.size} archive entries checked; only bootstrap differs; executable differs only by its declared ASAR digest; CLI and sandbox helper binaries match the installed package.`);
