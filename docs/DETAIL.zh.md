# PowerShell 7 引导

一键把本机的 Windows PowerShell 5.1 之外的 PowerShell 7 装好、接进系统，并把 harness 自己的命令执行器切到 7 上。

## 为什么需要它

Windows 自带的 5.1 是系统组件，只能并存、不能替换。而"装好 7"和"用上 7"是两件事：装完 `pwsh.exe` 之后，`Win+R` 敲 `powershell` 仍然启动 5.1，双击 `.ps1` 仍然交给 5.1，harness 的 `pwsh` 工具在进程启动时就缓存了解析结果，也不会自动换过去。这个插件把后面这些收尾动作一次做完。

## 八个动作

| action | 作用 | 是否改动系统 |
| --- | --- | --- |
| `plan` | 只读列出 7 个候选改动项，逐条给出状态（已就绪 / 待改动 / 无法执行）与落点 | 只读 |
| `confirm` | 把 `plan` 的清单做成确认窗口：每行写明会写哪个文件或注册表键，勾选后才执行 | 由用户勾选决定 |
| `detect` | 检查是否已装、别名是否存在、终端委托与 App Paths 现状 | 只读 |
| `install` | 下载 MSIX 包并做当前用户级安装 | 装包 |
| `integrate` | 写终端默认 profile、系统默认终端委托、资源管理器右键、`Win+R` 解析、`.ps1` 关联 | 写 HKCU 与终端 settings.json |
| `lock` | 在 DSH profile 的 patch 层钉死 `pwshPath` | 写 `~/.dsh/profiles/<profile>/cordis.patch.yml` |
| `verify` | 实跑 pwsh 取版本，逐项复核上述配置 | 只读 |
| `all` / `auto` | 不问用户的批量路径（`auto` 先做廉价判定，已就绪就一步不动） | 全套 / 视缺口而定 |

所有动作幂等：重复执行只补缺失项，不会重复注入。

## 装上插件先看一张确认卡

插件加载后约 2 秒会先算一份清单：本机已装什么、还差什么、每一项会写到哪里。只要还有待改的项，就弹一个窗口把清单摊开——两列，左边是改动项，右边是落点（文件路径或注册表键），悬停还能看到现状说明。待改项默认勾选，已就绪的项灰掉、勾了也不会重复改，缺依赖的项标橙。

点「应用选中项」只执行你勾的那几行，然后自动跑一次 `verify`；点「取消，什么都不改」则一个字节都不写，连备份文件都不会多出来。已经配置好的机器连窗口都不弹——两次文件探测就判定就绪。

自动行为由配置项 `autoRun` 控制：

| 取值 | 行为 |
| --- | --- |
| `ask`（默认） | 弹确认窗口，勾选后才动手 |
| `off` | 加载时什么都不做，全靠手动调 `ps7_bootstrap` |
| `lock-only` | 只补 DSH 的 `pwshPath` 锁定，不下载、不改终端与注册表 |
| `full` | 旧行为：不问用户，缺什么补什么（只建议无人值守机器这么配） |

想调整，在 profile 的 `cordis.patch.yml` 里给本插件加一行即可：

```yaml
- id: ps7-bootstrap-tool
  name: ps7-bootstrap
  config:
    autoRun: off
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
