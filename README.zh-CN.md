# dsh-windows-open-in-app-fix

一键修复 **Windows 上 DeepSeek Harness 桌面版「在应用中打开 → VS Code」失败**
（界面提示「打开失败，请重试」）。

> 非官方社区修复方案，与 DeepSeek 官方无关，请自行评估风险后使用。

## 问题原因

DSH 桌面版用 `ELECTRON_RUN_AS_NODE=1` 启动 Host 进程，该变量会被所有子进程继承。
外部应用启动器只过滤凭据类变量（`*KEY*`、`*PASSWORD*`、`*SECRET*`、`*TOKEN*`、`DSH_*`），
于是这个标记传到了 `Code.exe`。

VS Code 本身是 Electron 应用，带该标记启动会以 **Node 模式**运行，把工作区目录当成入口脚本，
约 50ms 内以非零码退出：

```
Error: Cannot find module 'C:\Users\YourName\workspace'
Node.js v24.x
```

启动监视窗口于是判定失败，DSH 报「打开失败」。资源管理器、Windows Terminal、Git Bash、
JetBrains 系列（非 Electron）不受影响。

上游讨论：
- https://github.com/deepseek-ai/deepseek-harness/discussions/10404
- https://github.com/deepseek-ai/deepseek-harness/discussions/9920

## 修复方式

`install.ps1` 只在外置应用启动点删除该变量：

```
...scrubbedParentEnv(),                      ->  ...((env) => (delete env.ELECTRON_RUN_AS_NODE, env))(scrubbedParentEnv()),
```

补丁写入 `resources\app.asar`，采用**等长字节替换**：所有归档偏移保持不变，
原始文件可被完整还原。不改注册表、不改全局环境变量、不重装。

## 使用方法

下载本仓库（Code → Download ZIP），在解压目录打开 PowerShell：

```powershell
# 只演练，不写盘
.\install.ps1 -DryRun

# 应用修复
.\install.ps1

# 恢复原状
.\uninstall.ps1
```

之后重启 DSH 桌面版。脚本会自动查找安装目录；如安装在其他位置，使用
`-DshRoot "D:\Apps\DeepSeek Harness"` 指定。

写入前会把完整原始 `app.asar` 备份到 `%LOCALAPPDATA%\dsh-open-in-app-fix\backups`。

## 已验证环境

| 项目 | 值 |
|---|---|
| DSH Desktop | 0.2.2-rc.3 |
| 系统 | Windows 11 x64 |
| 应用内 Electron / Node | Electron 44 / Node 24 |
| 启动器 | 该版本自带的 `@deepseek-ai/dsh-host-open-in-app` |

**不承诺**其他版本可用。脚本在以下情况一律拒绝修改并退出：
启动器代码形态不匹配、匹配点不唯一、无法保持字节长度一致、归档布局无法解析。
此时不会写入任何内容。

## 脚本遵守的安全规则

- 校验启动器形态，并要求匹配唯一；
- 保持补丁文件字节数完全一致（偏移不变）；
- 写入前备份整个原始 `app.asar`；
- 写入后回读校验，并在有 Node 运行时执行语法检查；
- 幂等：已打补丁时直接跳过；
- 不碰注册表、全局环境变量和其他应用；
- 无遥测、无联网、不收集任何数据。

## 注意事项

- DSH 升级会覆盖 `app.asar`，升级后需重新执行本脚本（直到上游不再泄漏该变量）。
- 补丁修改的是应用自带的一个内部文件，请保留备份；随时可用 `uninstall.ps1` 还原。
- 仅在上述版本验证过。

## 隐私

脚本只读取 DSH 安装目录内的 `app.asar`，只写入该文件和本地备份目录，不上传任何内容。

## 许可证

MIT，见 [LICENSE](LICENSE)。
