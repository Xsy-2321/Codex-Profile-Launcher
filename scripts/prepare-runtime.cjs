// Builds a profile-owned runtime. Never modifies the installed application.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const vm = require('node:vm');

function archiveHeaderHash(archive) {
  const fd = fs.openSync(archive, 'r');
  try {
    const prefix = Buffer.alloc(16);
    if (fs.readSync(fd, prefix, 0, 16, 0) !== 16) throw new Error('Truncated ASAR prefix');
    const header = Buffer.alloc(prefix.readUInt32LE(12));
    if (fs.readSync(fd, header, 0, header.length, 16) !== header.length) throw new Error('Truncated ASAR header');
    return crypto.createHash('sha256').update(header).digest('hex');
  } finally { fs.closeSync(fd); }
}

function updateArchiveIntegrity(executable, sourceArchive, patchedArchive) {
  // Keep Electron's integrity enforcement enabled. Update only the expected
  // header digest in the copied executable's existing ElectronAsar resource.
  const before = archiveHeaderHash(sourceArchive);
  const after = archiveHeaderHash(patchedArchive);
  const bytes = fs.readFileSync(executable);
  const marker = Buffer.from('"file":"resources\\\\app.asar"');
  const markerOffset = bytes.indexOf(marker);
  if (markerOffset < 0) return null; // Older Owl builds have no embedded entry.
  if (bytes.indexOf(marker, markerOffset + 1) >= 0) throw new Error('Ambiguous ASAR integrity resource');
  const recordEnd = bytes.indexOf(Buffer.from('}'), markerOffset);
  if (recordEnd < 0 || recordEnd - markerOffset > 512) throw new Error('Unsupported ASAR integrity resource');
  const record = JSON.parse('{' + bytes.subarray(markerOffset, recordEnd + 1).toString());
  if (record.alg.toUpperCase() !== 'SHA256' || record.value !== before) {
    throw new Error('Embedded ASAR integrity does not match the installed archive');
  }
  const offset = bytes.indexOf(Buffer.from(before), markerOffset);
  if (offset < markerOffset || offset + 64 > recordEnd) throw new Error('Cannot locate ASAR integrity digest');
  bytes.write(after, offset, 64, 'ascii');
  fs.writeFileSync(executable, bytes);
  return {offset, before, after};
}

function patchArchive(source, destination, initialCode) {
  const input = fs.readFileSync(source);
  const header = JSON.parse(input.subarray(16, 16 + input.readUInt32LE(12)));
  const base = 8 + input.readUInt32LE(4);
  const build = header.files['.vite'].files.build.files;
  const names = Object.keys(build).filter(n => /^bootstrap-.*\.js$/.test(n));
  if (names.length !== 1) throw new Error('Unsupported app: bootstrap is not unique');
  const entry = build[names[0]];
  const old = input.subarray(base + Number(entry.offset), base + Number(entry.offset) + entry.size).toString();
  // Rollup emits either a namespace call (old builds) or a direct function
  // call (new builds). Match only the known one-argument identity expression.
  const hook = /[\w$]+\.app\.setAppUserModelId\([\w$]+(?:\.[\w$]+)?\([\w$]+\)\)/g;
  if ([...old.matchAll(hook)].length !== 1) throw new Error('Unsupported app: notification identity hook changed');
  const changed = initialCode + '\n' + old.replace(hook, '$& ,require(process.resourcesPath+"/profile-bootstrap.cjs").configure()');
  // The original hook is in a comma expression, so the injected call remains in that expression.
  new vm.Script(changed, { filename: names[0] });
  const replacement = Buffer.from(changed);
  const entries = [];
  function walk(tree) {
    for (const item of Object.values(tree)) {
      if (item.files) walk(item.files);
      else if (!item.unpacked && item.offset !== undefined) entries.push(item);
    }
  }
  walk(header.files);
  entries.sort((a,b) => Number(a.offset)-Number(b.offset));
  const chunks = [];
  let offset = 0;
  for (const item of entries) {
    const data = item === entry ? replacement : input.subarray(base + Number(item.offset), base + Number(item.offset) + item.size);
    item.offset = String(offset); item.size = data.length; offset += data.length;
    if (item === entry) {
      const blockSize = 4194304;
      const hash = b => crypto.createHash('sha256').update(b).digest('hex');
      item.integrity = { algorithm: 'SHA256', hash: hash(data), blockSize, blocks: [] };
      for (let i=0;i<data.length;i+=blockSize) item.integrity.blocks.push(hash(data.subarray(i,i+blockSize)));
    }
    chunks.push(data);
  }
  const json = Buffer.from(JSON.stringify(header));
  const padded = Math.ceil((4+json.length)/4)*4;
  const prefix = Buffer.alloc(16 + padded - 4);
  prefix.writeUInt32LE(4,0); prefix.writeUInt32LE(4+padded,4);
  prefix.writeUInt32LE(padded,8); prefix.writeUInt32LE(json.length,12);
  const fd = fs.openSync(destination,'wx');
  try { fs.writeSync(fd,prefix.subarray(0,16)); fs.writeSync(fd,json); fs.writeSync(fd,Buffer.alloc(padded-4-json.length)); for(const b of chunks) fs.writeSync(fd,b); }
  finally { fs.closeSync(fd); }
}

function prepare(source, target, profileRoot, label) {
  source=path.resolve(source); target=path.resolve(target); profileRoot=path.resolve(profileRoot);
  if (target===source || target.startsWith(source+path.sep)) throw new Error('Destination must be outside the installed app');
  if (!/^[A-Za-z0-9_-]+$/.test(label)) throw new Error('Unsupported profile name');
  if (fs.existsSync(target)) throw new Error('Runtime destination already exists; choose a new version directory');
  const digest=crypto.createHash('sha256').update(profileRoot.toLowerCase()).digest('hex');
  const clsid=`{${digest.slice(0,8)}-${digest.slice(8,12)}-${digest.slice(12,16)}-${digest.slice(16,20)}-${digest.slice(20,32)}}`;
  const identity={label,profileRoot,appId:`CodexProfile.${label}.${digest.slice(0,12)}`,clsid};
  // Validate bootstrap compatibility before copying anything.
  const scratch=target+'.asar';
  fs.mkdirSync(path.dirname(target),{recursive:true});
  patchArchive(path.join(source,'resources','app.asar'),scratch,
    'require(process.resourcesPath+"/profile-bootstrap.cjs").environment();');
  fs.cpSync(source,target,{recursive:true,dereference:true,filter:p=>p!==path.join(source,'resources','app.asar')});
  fs.renameSync(scratch,path.join(target,'resources','app.asar'));
  const archiveIntegrity = updateArchiveIntegrity(path.join(target,'ChatGPT.exe'),
    path.join(source,'resources','app.asar'),path.join(target,'resources','app.asar'));
  fs.copyFileSync(path.join(__dirname,'profile-bootstrap.cjs'),path.join(target,'resources','profile-bootstrap.cjs'));
  fs.writeFileSync(path.join(target,'resources','profile-identity.json'),JSON.stringify(identity,null,2));
  fs.writeFileSync(path.join(target,'profile-runtime.json'),JSON.stringify({source,...identity,archiveIntegrity,builtAt:new Date().toISOString()},null,2));
  console.log(JSON.stringify({executable:path.join(target,'ChatGPT.exe'),...identity}));
}

if(require.main===module){try{prepare(...process.argv.slice(2));}catch(e){console.error(e.message);process.exitCode=1;}}
module.exports={patchArchive,prepare,archiveHeaderHash,updateArchiveIntegrity};
