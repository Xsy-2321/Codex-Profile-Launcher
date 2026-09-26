const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),vm=require('node:vm');
const {patchArchive,archiveHeaderHash,updateArchiveIntegrity}=require('./prepare-runtime.cjs');
const root=fs.mkdtempSync(path.resolve(__dirname,'../../config-test-runtime-'));
function fixture(file,code){
  const data=Buffer.from(code);
  const header=Buffer.from(JSON.stringify({files:{'.vite':{files:{build:{files:{'bootstrap-test.js':{size:data.length,offset:'0'}}}}}}}));
  const padded=Math.ceil((4+header.length)/4)*4,prefix=Buffer.alloc(12+padded);
  prefix.writeUInt32LE(4,0);prefix.writeUInt32LE(4+padded,4);prefix.writeUInt32LE(padded,8);prefix.writeUInt32LE(header.length,12);
  header.copy(prefix,16);fs.writeFileSync(file,Buffer.concat([prefix,data]));
}
for(const [label,expression] of Object.entries({legacy:'e.app.setAppUserModelId(n.r(flavor))',current:'e.app.setAppUserModelId(resolveId(flavor))'})){
  const source=path.join(root,label+'.asar'),output=path.join(root,label+'-patched.asar');
  fixture(source,'process.platform===`win32`&&('+expression+');');
  patchArchive(source,output,'');
  const b=fs.readFileSync(output),code=b.subarray(8+b.readUInt32LE(4)).toString();
  for(const platform of ['win32','linux']){
    const calls=[];
    vm.runInNewContext(code,{process:{platform,resourcesPath:'test'},flavor:'release',e:{app:{setAppUserModelId:v=>calls.push(v)}},n:{r:x=>x},resolveId:x=>x,require:()=>({configure:()=>calls.push('profile')})});
    assert.deepEqual(calls,platform==='win32'?['release','profile']:[]);
  }
  const exe=path.join(root,label+'.exe');
  const originalHash=archiveHeaderHash(source),newHash=archiveHeaderHash(output);
  const bytes=Buffer.from('UNCHANGED CODE'+JSON.stringify([{file:'resources\\app.asar',alg:'SHA256',value:originalHash}])+'UNCHANGED FUSES');
  fs.writeFileSync(exe,bytes);
  const change=updateArchiveIntegrity(exe,source,output),patched=fs.readFileSync(exe);
  assert.equal(patched.subarray(change.offset,change.offset+64).toString(),newHash);
  patched.write(originalHash,change.offset,64,'ascii');assert.deepEqual(patched,bytes);
  assert.throws(()=>updateArchiveIntegrity(exe,source,output),/does not match/);
}
for(const [label,code]of Object.entries({missing:'console.log("unsupported")',duplicate:'e.app.setAppUserModelId(f(x));e.app.setAppUserModelId(f(x));'})){
  const source=path.join(root,label+'.asar'),output=path.join(root,label+'-patched.asar');
  fixture(source,code);assert.throws(()=>patchArchive(source,output,''),/notification identity hook changed/);assert.equal(fs.existsSync(output),false);
}
console.log('PASS: legacy/current hooks preserve platform gating; only the declared integrity digest changes; mismatched hashes and ambiguous hooks are rejected.');
console.log('Fixtures:',root);
