const fs=require('node:fs');
const path=require('node:path');
const identity=JSON.parse(fs.readFileSync(path.join(process.resourcesPath,'profile-identity.json'),'utf8'));
const journal=path.join(identity.profileRoot,'notification-routing.jsonl');
function record(event,details={}) {
  fs.appendFileSync(journal,JSON.stringify({time:new Date().toISOString(),pid:process.pid,event,...details})+'\n');
}
function resetStartupPage(){
  const webData=path.join(identity.profileRoot,'web-data');
  const state=path.join(webData,'browser-sidebar-page-states.json');
  const backup=state+'.before-fresh-start.json';
  // A direct Start Menu shortcut also carries this flag. Do not touch state
  // when another Electron process still owns the profile lock.
  if(fs.existsSync(path.join(webData,'lockfile'))){record('fresh-start-skipped',{reason:'profile-lock-exists'});return;}
  if(!fs.existsSync(state)){return;}
  try{
    if(!fs.existsSync(backup))fs.copyFileSync(state,backup);
    fs.writeFileSync(state,'{"version":1,"pages":{}}\n');
    record('fresh-start');
  }catch(error){record('fresh-start-failed',{error:String(error)});}
}
exports.environment=()=>{
  process.env.CODEX_HOME=path.join(identity.profileRoot,'codex-home');
  process.env.CODEX_ELECTRON_USER_DATA_PATH=path.join(identity.profileRoot,'web-data');
  // This is an unpackaged profile-owned copy. Use its bundled backend rather
  // than the newer registered MSIX core, which requires the main app identity.
  if(process.platform==='win32')process.env.CODEX_CLI_PATH=path.join(process.resourcesPath,'codex.exe');
  // Keep the release behavior; notification identity is configured explicitly.
  delete process.env.BUILD_FLAVOR;
  if(process.argv.includes('--profile-fresh-start'))resetStartupPage();
};
exports.configure=()=>{
  const {app,shell,Notification,BrowserWindow}=require('electron');
  app.setName('Codex - '+identity.label);
  app.setAppUserModelId(identity.appId);
  if(typeof app.setToastActivatorCLSID!=='function') throw new Error('This runtime lacks independent toast activation');
  app.setToastActivatorCLSID(identity.clsid);
  // Codex keeps Windows instances alive after the last window by default.
  // Personal should actually exit when its only window is closed so the next
  // shortcut launch creates a clean page instead of reviving the old one.
  app.on('window-all-closed',()=>app.quit());
  // On Windows Codex's primary window may prevent the native close event and
  // hide itself. In that case window-all-closed never fires, leaving the
  // private Electron process alive. Observe the primary window's close request
  // early and explicitly terminate this isolated profile.
  let profileQuitting=false;
  app.on('browser-window-created',(_event,win)=>{
    win.on('close',()=>{
      if(win.isDestroyed()||profileQuitting)return;
      const title=win.getTitle();
      const [width,height]=win.getSize();
      const isPrimary=title===app.getName()||title==='ChatGPT'||(width>=900&&height>=600);
      if(!isPrimary)return;
      profileQuitting=true;
      record('window-close-request',{title,width,height});
      app.quit();
    });
  });
  const shortcut=path.join(process.env.APPDATA,'Microsoft','Windows','Start Menu','Programs','Codex - '+identity.label+'.lnk');
  if(!fs.existsSync(shortcut)) throw new Error('Run Register-ProfileNotifications.ps1 before launching this runtime');
  record('identity',{appId:identity.appId,clsid:app.toastActivatorCLSID,executable:process.execPath,shortcut});
  app.whenReady().then(()=>{
    record('runtime-ready',{version:app.getVersion(),name:app.getName(),userData:app.getPath('userData'),codexHome:process.env.CODEX_HOME,cliPath:process.env.CODEX_CLI_PATH});
    if(process.argv.includes('--profile-runtime-check'))app.exit(0);
  });
  // Trace the same native notifications used for real approvals, without recording message contents.
  const originalShow=Notification.prototype.show;
  Notification.prototype.show=function(...args){
    if(!this.__profileTraced){
      this.__profileTraced=true;
      this.on('click',()=>record('notification-click'));
      this.on('failed',(_event,error)=>record('notification-failed',{error:String(error)}));
    }
    record('notification-show');
    return originalShow.apply(this,args);
  };
  if(process.argv.includes('--profile-notification-test')){
    app.whenReady().then(()=>setTimeout(()=>{
      const toast=new Notification({title:'Codex 副账号 · 点击测试',body:'点击后应只打开 Personal 副账号。这不是权限申请。'});
      toast.on('click',()=>{
        const win=BrowserWindow.getAllWindows().find(w=>!w.isDestroyed()&&w.isVisible());
        if(win){if(win.isMinimized())win.restore();win.show();win.focus();record('test-click',{windowId:win.id});}
        else record('test-no-window');
      });
      toast.show();
      global.__profileTestNotification=toast;
    },12000));
  }
};
