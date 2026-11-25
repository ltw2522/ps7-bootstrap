# PowerShell 7 引导

一键把本机的 Windows PowerShell 5.1 之外的 PowerShell 7 装好、接进系统，并把 harness 自己的命令执行器切到 7 上。

## 为什么需要它

Windows 自带的 5.1 是系统组件，只能并存、不能替换。而"装好 7"和"用上 7"是两件事：装完 `pwsh.exe` 之后，`Win+R` 敲 `powershell` 仍然启动 5.1，双击 `.ps1` 仍然交给 5.1，harness 的 `pwsh` 工具在进程启动时就缓存了解析结果，也不会自动换过去。这个插件把后面这些收尾动作一次做完。

## 六个动作

| action | 作用 | 是否改动系统 |
| --- | --- | --- |
| `detect` | 检查是否已装、别名是否存在、终端委托与 App Paths 现状 | 只读 |
| `install` | 下载 MSIX 包并做当前用户级安装 | 装包 |
| `integrate` | 写终端默认 profile、系统默认终端委托、资源管理器右键、`Win+R` 解析、`.ps1` 关联 | 写 HKCU 与终端 settings.json |
| `lock` | 在 DSH profile 的 patch 层钉死 `pwshPath` | 写 `~/.dsh/profiles/<profile>/cordis.patch.yml` |
| `verify` | 实跑 pwsh 取版本，逐项复核上述配置 | 只读 |
| `all` | `install` → `integrate` → `lock` → `verify` | 全套 |
| `auto` | 先做廉价判定：已就绪就一步不动，有缺口才补上面那些 | 视缺口而定 |

所有动作幂等：重复执行只补缺失项，不会重复注入。

## 装上插件就已经配好了

插件加载时会自动跑一次 `auto`，所以正常流程里不需要再手动敲任何命令——装完插件、等几秒，配置就位。

它的第一步很便宜：查一次 `WindowsApps\pwsh.exe` 别名在不在、读一次当前 profile 的 patch 有没有 `pwsh-sandbox` 条目。两样都在就立刻返回，连子进程都不起。缺哪样补哪样，PS7 已装时不会再去碰网络。

自动行为由配置项 `autoRun` 控制：

| 取值 | 行为 |
| --- | --- |
| `full`（默认） | 缺什么补什么，包括 PS7 没装时自动下载安装 |
| `lock-only` | 只补 DSH 的 `pwshPath` 锁定，不下载、不改终端与注册表 |
| `off` | 加载时什么都不做，全靠手动调 `ps7_bootstrap` |

想改成不自动下载，在 profile 的 `cordis.patch.yml` 里给本插件加一行即可：

```yaml
- id: ps7-bootstrap-tool
  name: ps7-bootstrap
  config:
    autoRun: lock-only
```

自动引导不会阻塞启动，失败也不影响宿主：结果只记在模块内的 `lastAutoRun` 里，随时可以手动跑 `ps7_bootstrap(action:"verify")` 看实际状态。

## 安装方式与权限

走 MSIX 用户级部署（`Add-AppxPackage`），不需要管理员。5.1 保持原样，两者并存。

下载默认按 `ghproxy.net` → `gh-proxy.com` → `ghfast.top` → GitHub 直连的顺序轮询，因为国内直连 `github.com` 常在大文件上超时。可用 `mirror` 参数指定自己的前缀。7.7.0 的 SHA-256 内置校验；其他版本只校验包大小（>100 MB 视为下载完整）。

## 会写哪些东西

- `HKCU\Console\%%Startup` 的 `DelegationConsole` / `DelegationTerminal`——两个 CLSID 必须不同，写同一个会导致交接失败并静默回退 conhost。CLSID 在运行时从 Windows Terminal 的 `AppxManifest.xml` 读取，不硬编码。
- Windows Terminal 的 `settings.json`：改 `defaultProfile` 并补一条 `PowerShell 7` 配置档。该文件是 JSONC，用正则改写而非 JSON 解析器；改前留 `.ps7bak` 备份。
- `HKCU\Console\%%Startup`、`Directory\shell\PowerShell7Here`、`Directory\Background\shell\PowerShell7Here`、`App Paths\powershell.exe`、`Microsoft.PowerShellScript.1\Shell\0\Command`——全部 HKCU，仅影响当前用户。

## 改完还是 5.1 的地方

在 `cmd` 或 Git Bash 里敲 `powershell` 仍然进 5.1。这是 PATH 决定的：`System32\WindowsPowerShell\v1.0` 排在前面，而 `WindowsApps` 里只有 `pwsh.exe`、没有 `powershell.exe` 别名。改这个需要动机器级 PATH（管理员权限），本插件不做。

`Win+R`、运行框、地址栏、快捷方式、`Start-Process` 这些走 `ShellExecute` 的入口会被接管——但也别用 `Start-Process powershell` 去验证，那条路走的是 `CreateProcess` 的 PATH 搜索，本来就不查 App Paths。验证请直接看 `$PSVersionTable.PSEdition`。

## 回退

```powershell
# 卸载 7（保留 5.1）
Get-AppxPackage Microsoft.PowerShell | Remove-AppxPackage

# 撤销系统集成：删掉上面列出的 HKCU 键，并用 .ps7bak 覆盖回 settings.json
```
