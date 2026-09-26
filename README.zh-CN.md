# Codex 双账号启动器（Windows）

[English documentation / 英文说明](README.md)

> 这是依赖 Codex Windows 应用内部结构的非官方方案，后续应用更新可能需要调整，不属于官方多账号功能。

## 本 Fork 的主要功能

- `Work` 继续使用原版 Codex 的正常数据。
- `Personal` 使用独立的 Codex、Chromium 和 Electron 数据目录。
- 将已安装的 Codex 复制为独立运行副本，不修改 WindowsApps 中的原始安装文件。
- 使用文件凭据和独立的 unelevated Windows 沙盒配置。
- 为 Personal 设置独立的通知身份、开始菜单入口和激活注册。
- Personal 已运行时，点击快捷方式会恢复已有窗口，避免重复启动。
- 处理 AppX 无法发现、WMI 进程查询受限以及 Codex 更新后补丁不兼容等情况，并提供安全回退。
- 包含运行时完整性、启动器配置和沙盒权限测试。

## 使用要求

- Windows，并已安装 Codex 桌面应用。
- PowerShell。
- 首次构建 Personal 运行副本时，需要 `node.exe` 已加入 `PATH`。

启动器不会复制或提交账号数据。Personal 数据仍保存在：

```text
%LOCALAPPDATA%\CodexProfiles\personal\codex-home
%LOCALAPPDATA%\CodexProfiles\personal\web-data
```

准备好的应用副本位于本仓库旁边的 `profile-runtime` 目录中。这些内容属于本地构建产物，已被 `.gitignore` 排除，不应上传到 GitHub。

## 使用方法

请在 `Codex-Profile.ps1` 所在目录执行：

```powershell
# 启动默认的 Work 主账号
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Codex-Profile.ps1 Work

# 启动隔离的 Personal 副账号
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Codex-Profile.ps1 Personal

# 查看正在运行的隔离实例
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Codex-Profile.ps1 -Status

# 为已配置的账号安装桌面快捷方式
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Codex-Profile.ps1 -InstallShortcuts

# Personal 关闭时发送无害的通知路由测试
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Codex-Profile.ps1 Personal -TestNotification
```

如果需要使用其他本地数据根目录，也可以传入 `-ProfilesRoot` 参数。

## 应用更新时的行为

Work 通过 Windows 程序包激活入口启动，确保应用获得 MSIX 程序包身份。桌面快捷方式的图标会复制到固定的 `shortcut-assets` 目录，避免指向更新后被移除的 WindowsApps 版本目录。已有快捷方式可运行一次 `-InstallShortcuts` 修复图标。

Personal 通过 `CODEX_CLI_PATH` 使用副本自带的 `resources/codex.exe` 后端，保持与已安装应用的 MSIX 后端独立。v2 副本兼容已知的新旧通知初始化结构。对于启用了 ASAR 完整性校验的版本，会同步更新副本 exe 中的归档头校验值，继续保留完整性校验。副本因此属于本地修改版本，原版安装文件不变；完整性测试会核对只有启动代码和这 64 字节的校验值发生变化。

Codex 更新后，启动器会尝试为新版本准备对应的隔离运行副本。如果新版本的内部结构与补丁不兼容，启动器会复用最近可用的独立运行副本，不会修改已安装的原版应用，也不会悄悄回退到共享账号。如果不存在可复用的独立副本，启动器会报错停止。

当 AppX 注册暂时不可用时，启动器也会尝试从正在运行的原版 Codex 进程取得程序路径。这些回退逻辑仍然保持两个账号的数据目录相互隔离。

## 隐私与安全

- 不要提交 `auth.json`、`CodexProfiles`、`codex-home`、`web-data`、通知日志或已构建的运行副本。
- 不要将账号数据放入 Git、OneDrive、Dropbox、共享目录或网络盘。
- 不要让两个 Personal 进程同时访问同一个数据目录。
- 通知日志只记录路由事件和进程元数据，不记录通知正文。
- 启动器不会修改原始安装的 Codex 文件，只会修改复制出来的运行副本。

## 测试

`scripts` 目录包含以下测试：

- 启动器配置解析和幂等更新测试；
- 新旧启动代码兼容性、校验记录不匹配时的拒绝测试；
- 运行时复制和完整性测试；
- Windows 沙盒读写边界测试。

测试只创建临时本地夹具，不调用模型。
