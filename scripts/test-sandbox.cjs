// No model calls, account changes, or privilege elevation inside the sandbox.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {spawnSync}=require('node:child_process');
const assert=require('node:assert/strict');
const [cli,profileRoot]=process.argv.slice(2);
if(!cli||!profileRoot)throw new Error('Usage: node test-sandbox.cjs CLI PROFILE_ROOT');
const root=fs.mkdtempSync(path.resolve(__dirname,'../../sandbox-test-'));
const allowed=path.join(root,'allowed'),denied=path.join(root,'denied.txt');
fs.mkdirSync(allowed);
const command=`$ErrorActionPreference='Stop'; Set-Content -LiteralPath '${allowed.replaceAll("'","''")}\\allowed.txt' -Value 'ok' -NoNewline; if((Get-Content -Raw -LiteralPath '${allowed.replaceAll("'","''")}\\allowed.txt') -ne 'ok'){throw 'Read failed'}; try {Set-Content -LiteralPath '${denied.replaceAll("'","''")}' -Value 'not allowed'; throw 'OUTSIDE_WRITE_ALLOWED'} catch [UnauthorizedAccessException] {Write-Output 'OUTSIDE_WRITE_BLOCKED'}; Write-Output 'PERSONAL_SANDBOX_READ_WRITE_OK'`;
const profile=`permissions.routing_test={filesystem={":root"="read","${allowed.replaceAll('\\','/')}"="write"},network={enabled=false}}`;
const result=spawnSync(cli,['sandbox','-C',allowed,'-P','routing_test','-c',profile,'--',path.join(process.env.SystemRoot,'System32/WindowsPowerShell/v1.0/powershell.exe'),'-NoProfile','-NonInteractive','-EncodedCommand',Buffer.from(command,'utf16le').toString('base64')],{encoding:'utf8',timeout:60000,env:{...process.env,CODEX_HOME:path.join(profileRoot,'codex-home')}});
console.log('Test fixtures:',root);console.log(result.stdout);console.error(result.stderr);
assert.ifError(result.error);assert.equal(result.status,0);
assert.match(result.stdout,/OUTSIDE_WRITE_BLOCKED/);assert.match(result.stdout,/PERSONAL_SANDBOX_READ_WRITE_OK/);
assert.equal(fs.existsSync(denied),false);assert.equal(fs.readFileSync(path.join(allowed,'allowed.txt'),'utf8'),'ok');
