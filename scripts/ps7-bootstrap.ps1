<#
.SYNOPSIS
    PowerShell 7 一键引导脚本：检测 / 安装 / 系统集成 / DSH 锁定 / 验证。

.DESCRIPTION
    由 DSH 插件 ps7-bootstrap 调用，也可单独在 PowerShell 5.1 里直接执行。
    设计前提：脚本本身必须能在「尚未安装 PowerShell 7」的机器上运行，
    因此全程只使用 Windows PowerShell 5.1 兼容语法，不用 7 才有的
    ??、?:、-Parallel 等特性。

    每一步的结果都以结构化步骤记录，最后统一以一行 JSON 输出，
    前缀标记为 ##PS7RESULT##，方便宿主侧解析；人读日志走 Write-Host。

.PARAMETER Action
    detect    只读检测，不改任何配置
    plan      只读：列出「将会改动哪些设置」，逐条给出状态（已就绪 / 待改动 / 无法执行）
    confirm   先弹确认窗口，把将改动的项、落点、备份位置逐条摊给用户看，勾选后才执行
              （插件加载时的默认动作；用户关掉窗口则一个字节都不改）
    install   下载并安装 PowerShell 7（MSIX 用户级，免管理员）
    integrate 写系统集成项（终端默认 / 终端委托 / 右键菜单 / App Paths / .ps1 关联）
    lock      把 DSH 的 shell 执行器锁定到 PowerShell 7
    verify    全量校验
    all       依次执行 install → integrate → lock → verify
    auto      智能引导：先做一次廉价判定，已就绪就一步不动；有缺口才走完整流程。
              不具备交互条件时（例如无人值守脚本）才用这个，它不会询问用户。

.PARAMETER Version
    目标版本号，默认 7.7.0；需与 GitHub release 的 tag 一致。

.PARAMETER Mirror
    自定义下载镜像前缀，例如 https://ghproxy.net/https://github.com
    留空时按内置镜像列表依次尝试，最后回退 GitHub 直连。

.PARAMETER Force
    即使已安装同版本也重新下载安装。

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ps7-bootstrap.ps1 -Action detect
#>

[CmdletBinding()]
param(
    [ValidateSet('detect', 'plan', 'confirm', 'install', 'integrate', 'lock', 'verify', 'all', 'auto')]
    [string]$Action = 'detect',

    [string]$Version = '7.7.0',

    [string]$Mirror = '',

    [switch]$Force,

    # 显式指定 DSH profile 目录；留空时按「环境变量 → 唯一 profile → 最近修改」自动探测
    [string]$ProfileDir = '',

    # 静默模式：不打印人读日志，只留最终 JSON
    [switch]$Quiet
)

# ═══════════════════════════════════════════════════════════════
# 输出编码
# ═══════════════════════════════════════════════════════════════

# 被宿主以管道捕获时，5.1 默认按 OEM 代码页（简体中文为 936/GBK）编码输出，
# 而调用方通常按 UTF-8 解码，于是中文整片变成乱码。
# 这里统一改成无 BOM 的 UTF-8，脚本自身的中文才不会被吃掉。
# 用 try 包住：极少数受限环境不允许改控制台编码，那时退回默认行为即可，
# 宁可显示乱码也不能因此中断引导。
try {
    $script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $script:Utf8NoBom
    $OutputEncoding = $script:Utf8NoBom
} catch {
    # 改不动就跳过
}

# ═══════════════════════════════════════════════════════════════
# 常量区
# ═══════════════════════════════════════════════════════════════

# 已知版本的安装包 SHA256，用于下载完整性校验；缺失时跳过校验并告警。
$script:KnownSha256 = @{
    '7.7.0' = 'e00c349858c2d273f29485541ece91617b435accdd5e3f156d68d5cb97740022'
}

# 下载镜像前缀，按顺序尝试；空字符串代表 GitHub 直连。
# 国内直连 github.com 常因 TLS/路由超时失败，所以镜像优先。
$script:Mirrors = @(
    'https://ghproxy.net/https://github.com'
    'https://gh-proxy.com/https://github.com'
    'https://ghfast.top/https://github.com'
    ''
)

# Windows Terminal 的固定 profile GUID：显式声明可避免依赖终端版本自动生成。
$script:TerminalProfileGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'

# 步骤收集表，最终整体序列化成 JSON 返回给宿主。
$script:Steps = New-Object System.Collections.ArrayList

# 当前用户作用域下的 pwsh 执行别名（App Execution Alias），不带版本号，抗升级。
$script:PwshAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'

# ═══════════════════════════════════════════════════════════════
# 通用工具函数
# ═══════════════════════════════════════════════════════════════

<#
.SYNOPSIS
    记录一个步骤结果，并按需打印人读日志。

.PARAMETER Step
    步骤标识，形如 install / integrate.terminal 等，供宿主侧聚合。

.PARAMETER Ok
    该步骤是否成功；失败不会中断整体流程，由调用方决定是否继续。

.PARAMETER Detail
    面向人的补充说明，尽量包含实测值而非仅结论。
#>
function Add-Step {
    param(
        [string]$Step,
        [bool]$Ok,
        [string]$Detail
    )

    # ArrayList 的 Add 会返回索引，必须吞掉以免污染输出流
    [void]$script:Steps.Add([pscustomobject]@{
        step   = $Step
        ok     = $Ok
        detail = $Detail
    })

    if (-not $Quiet) {
        # 5.1 没有三元运算符，用子表达式模拟
        $tag = if ($Ok) { ' OK ' } else { 'FAIL' }
        Write-Host ('[{0}] {1,-24} {2}' -f $tag, $Step, $Detail)
    }
}

<#
.SYNOPSIS
    读取当前 PowerShell 7 的安装状态。

.DESCRIPTION
    用两条互不依赖的证据判定：MSIX 应用包清单（权威，含版本号）
    与执行别名文件是否存在（用于判断命令行能否直接敲 pwsh）。
    某些精简系统没有 Appx 子系统，此时仅靠别名路径探测。
#>
function Get-Ps7State {
    $state = [pscustomobject]@{
        Installed   = $false
        Version     = $null
        PackageFull = $null
        AliasExists = $false
        AliasPath   = $script:PwshAlias
        PSHOME      = $null
    }

    try {
        # 只取一个：同一台机器可能有多个架构变体
        $pkg = Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction Stop |
            Select-Object -First 1
        if ($null -ne $pkg) {
            $state.Installed = $true
            $state.Version = $pkg.Version.ToString()
            $state.PackageFull = $pkg.PackageFullName
            $state.PSHOME = $pkg.InstallLocation
        }
    } catch {
        # 非 Appx 环境（Server Core、精简镜像）会抛错，降级为纯文件探测
    }

    $state.AliasExists = Test-Path -LiteralPath $state.AliasPath
    return $state
}

<#
.SYNOPSIS
    把镜像前缀与 GitHub release 资产路径拼成完整下载地址。

.PARAMETER Prefix
    镜像前缀；空串表示走 github.com 直连。
#>
function Resolve-InstallerUri {
    param(
        [string]$Prefix,
        [string]$Ver
    )

    # 资产名固定为 PowerShell-<版本>.msixbundle；该版本线不提供 MSI
    $asset = 'PowerShell-' + $Ver + '.msixbundle'
    $tail = '/PowerShell/PowerShell/releases/download/v' + $Ver + '/' + $asset

    if ([string]::IsNullOrWhiteSpace($Prefix)) {
        return 'https://github.com' + $tail
    }
    return $Prefix.TrimEnd('/') + $tail
}

# ═══════════════════════════════════════════════════════════════
# detect：只读检测
# ═══════════════════════════════════════════════════════════════

<#
.SYNOPSIS
    汇总当前机器的 PowerShell 7 落地情况，不做任何写入。
#>
function Invoke-Detect {
    $state = Get-Ps7State

    if ($state.Installed) {
        Add-Step 'detect.powershell' $true ('已安装 {0}，包 {1}' -f $state.Version, $state.PackageFull)
    } else {
        Add-Step 'detect.powershell' $false '未检测到 Microsoft.PowerShell 应用包'
    }

    if ($state.AliasExists) {
        Add-Step 'detect.alias' $true ('执行别名存在：' + $state.AliasPath)
    } else {
        Add-Step 'detect.alias' $false ('执行别名缺失：' + $state.AliasPath)
    }

    # 终端委托现状：两个 CLSID 必须不同，写同一个会静默回退 conhost
    $delegation = Get-ItemProperty -Path 'HKCU:\Console\%%Startup' -ErrorAction SilentlyContinue
    if ($null -eq $delegation) {
        Add-Step 'detect.delegation' $false '未配置系统默认终端（仍走 conhost）'
    } else {
        $c = $delegation.DelegationConsole
        $t = $delegation.DelegationTerminal
        Add-Step 'detect.delegation' ([bool]$c -and [bool]$t) ('Console={0} Terminal={1}' -f $c, $t)
    }

    # App Paths：决定「运行框 / Win+R 敲 powershell」解析到哪个可执行文件
    $appPath = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\powershell.exe' -ErrorAction SilentlyContinue
    if ($null -eq $appPath) {
        Add-Step 'detect.apppaths' $false 'App Paths 未配置，Win+R 敲 powershell 走系统默认 5.1'
    } else {
        Add-Step 'detect.apppaths' $true ('App Paths 指向 ' + $appPath.'(default)')
    }

    # DSH 锁定：profile 的 patch 层里是否有 pwsh-sandbox 条目
    $patch = Get-DshPatchPath
    if ($null -eq $patch) {
        Add-Step 'detect.lock' $false '未找到 DSH profile 配置目录'
    } elseif ((Get-Content -LiteralPath $patch -Raw -ErrorAction SilentlyContinue) -match 'id:\s*pwsh-sandbox') {
        Add-Step 'detect.lock' $true ('已锁定 pwshPath：' + $patch)
    } else {
        Add-Step 'detect.lock' $false ('尚未锁定，DSH 会按解析链自行查找：' + $patch)
    }
}

# ═══════════════════════════════════════════════════════════════
# install：下载并安装
# ═══════════════════════════════════════════════════════════════

<#
.SYNOPSIS
    下载 MSIX 安装包并做用户级安装。

.DESCRIPTION
    之所以选 MSIX 而不是 MSI：PowerShell 7.7.0 这条版本线的 release
    不提供 .msi 资产，官方清单也只登记了 msixbundle；MSIX 走
    Add-AppxPackage 用户级安装，无需管理员权限，回退只需 Remove-AppxPackage。
#>
function Invoke-Install {
    param(
        [string]$Ver,
        [string]$MirrorPrefix,
        [bool]$ForceReinstall
    )

    $state = Get-Ps7State

    # 已装且版本前缀一致就不重复下载（7.7.0.0 与 7.7.0 视为同版本）
    if ($state.Installed -and -not $ForceReinstall) {
        if ($state.Version -like ($Ver + '*')) {
            Add-Step 'install.skip' $true ('已安装 ' + $state.Version + '，跳过下载')
            return
        }
        Add-Step 'install.upgrade' $true ('检测到旧版本 ' + $state.Version + '，将执行覆盖安装')
    }

    $asset = 'PowerShell-' + $Ver + '.msixbundle'
    $dest = Join-Path $env:TEMP $asset

    # 已下载且大小合理时复用，避免重复拉 350MB
    $reuse = (Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 100MB)
    if ($reuse -and -not $ForceReinstall) {
        Add-Step 'install.reuse' $true ('复用已下载安装包 ' + $dest)
    } else {
        # 镜像轮询：任一成功即停
        $prefixes = if ([string]::IsNullOrWhiteSpace($MirrorPrefix)) { $script:Mirrors } else { @($MirrorPrefix) }
        $downloaded = $false

        foreach ($prefix in $prefixes) {
            $uri = Resolve-InstallerUri -Prefix $prefix -Ver $Ver
            Write-Host ('  下载中：' + $uri)

            try {
                if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                    # curl 自带进度条与重试，比 Invoke-WebRequest 稳定
                    & curl.exe -L --fail --retry 2 --connect-timeout 20 --max-time 3600 -o $dest $uri 2>$null
                    $curlOk = ($LASTEXITCODE -eq 0)
                } else {
                    # 兜底：老系统没有 curl.exe 时用内置 HTTP 客户端
                    $old = $ProgressPreference
                    $ProgressPreference = 'SilentlyContinue'
                    Invoke-WebRequest -Uri $uri -OutFile $dest -TimeoutSec 1800 -UseBasicParsing
                    $ProgressPreference = $old
                    $curlOk = $true
                }
            } catch {
                $curlOk = $false
            }

            # 判定成功需要三个条件同时成立：退出码为 0、文件存在、体积合理
            if ($curlOk -and (Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 100MB)) {
                $downloaded = $true
                break
            }
        }

        if (-not $downloaded) {
            Add-Step 'install.download' $false '所有镜像均下载失败，请检查网络或改用 -Mirror 指定可用镜像'
            return
        }

        $sizeMb = [math]::Round((Get-Item -LiteralPath $dest).Length / 1MB, 1)
        Add-Step 'install.download' $true ('已下载 ' + $sizeMb + ' MB → ' + $dest)
    }

    # SHA256 校验：只对内置表里登记过的版本做强制校验
    $expected = $script:KnownSha256[$Ver]
    if ($expected) {
        $actual = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $expected) {
            Add-Step 'install.hash' $false ('校验不符：期望 ' + $expected + '，实际 ' + $actual)
            return
        }
        Add-Step 'install.hash' $true 'SHA256 与官方清单一致'
    } else {
        Add-Step 'install.hash' $true '该版本无内置哈希，跳过校验'
    }

    # 用户级安装：MSIX 不需要管理员，失败通常是包已被另一用户安装
    try {
        Add-AppxPackage -Path $dest -ForceUpdateFromAnyVersion -ErrorAction Stop
        $after = Get-Ps7State
        Add-Step 'install.deploy' $true ('安装完成，版本 ' + $after.Version)
    } catch {
        Add-Step 'install.deploy' $false ('Add-AppxPackage 失败：' + $_.Exception.Message)
    }
}

# ═══════════════════════════════════════════════════════════════
# integrate：系统集成
# ═══════════════════════════════════════════════════════════════

<#
.SYNOPSIS
    读取 Windows Terminal 包清单，取出两个宿主 COM 组件的 CLSID。

.DESCRIPTION
    终端委托需要两个不同的 CLSID：
      DelegationConsole  → com.microsoft.windows.console.host（OpenConsole.exe）
      DelegationTerminal → com.microsoft.windows.terminal.host（WindowsTerminal.exe）
    两者写成同一个值时，WindowsTerminal 会以 -Embedding 被拉起但交接失败，
    静默回退到 conhost，表现为「还是经典黑框」。这里直接读清单，避免硬编码失效。
#>
function Get-TerminalHostClsids {
    $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $pkg) {
        return $null
    }

    $manifestPath = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return $null
    }

    try {
        [xml]$xml = Get-Content -LiteralPath $manifestPath -Raw
    } catch {
        return $null
    }

    $clsids = [pscustomobject]@{ Console = $null; Terminal = $null }

    # 清单带 uap3 命名空间，AppExtension 里嵌套 Properties，用 local-name() 定位
    # 且必须走后代轴（.//）：Clsid 在 uap3:Properties 下面，不是 AppExtension 的直接子节点。
    # 写成 ./ 会拿到空节点，表现为「解析不到 CLSID」却看不出哪里错。
    foreach ($ext in $xml.SelectNodes("//*[local-name()='AppExtension']")) {
        $extName = $ext.GetAttribute('Name')
        $cls = $ext.SelectSingleNode(".//*[local-name()='Clsid']")
        if ($null -eq $cls) { continue }

        if ($extName -eq 'com.microsoft.windows.console.host') {
            $clsids.Console = $cls.InnerText.Trim()
        } elseif ($extName -eq 'com.microsoft.windows.terminal.host') {
            $clsids.Terminal = $cls.InnerText.Trim()
        }
    }

    if ($clsids.Console -and $clsids.Terminal) { return $clsids }
    return $null
}

<#
.SYNOPSIS
    把 Windows Terminal 的默认 profile 指向 PowerShell 7。

.DESCRIPTION
    settings.json 是 JSONC（含注释），不能用 ConvertFrom-Json 解析，
    因此走文本替换：
      1) profiles.list 里没有我们的 GUID 条目时，插入一条显式条目；
         显式声明比依赖终端自动生成的动态 profile 稳定，动态 GUID 会随版本变化。
      2) defaultProfile 一律改写成本条目的 GUID。
#>
function Set-TerminalDefaultProfile {
    $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $pkg) {
        Add-Step 'integrate.terminal' $false '未安装 Windows Terminal，跳过'
        return
    }

    $settings = Join-Path $env:LOCALAPPDATA ('Packages\' + $pkg.PackageFamilyName + '\LocalState\settings.json')
    if (-not (Test-Path -LiteralPath $settings)) {
        Add-Step 'integrate.terminal' $false ('未找到 settings.json：' + $settings)
        return
    }

    try {
        $text = Get-Content -LiteralPath $settings -Raw -Encoding UTF8

        # 幂等闸门：默认 profile 已指向我们的 GUID，且配置档条目也在，
        # 就原样返回。否则每次 integrate 都会重写 settings.json 并留一份备份，
        # 反复调用会把备份文件刷成一堆同内容副本。
        $hasEntry = $text -match [regex]::Escape($script:TerminalProfileGuid)
        $isDefault = $text -match ('"defaultProfile"\s*:\s*"' + [regex]::Escape($script:TerminalProfileGuid) + '"')
        if ($hasEntry -and $isDefault) {
            Add-Step 'integrate.terminal' $true '默认 profile 已是 PowerShell 7，无需改动'
            return
        }

        # 确实要改，才备份，便于一键回滚
        Copy-Item -LiteralPath $settings -Destination ($settings + '.ps7bak') -Force

        # JSON 字符串里的反斜杠必须成对转义
        $escaped = $script:PwshAlias.Replace('\', '\\')

        if (-not $hasEntry) {
            $entry = @"
    {
      "guid": "$($script:TerminalProfileGuid)",
      "name": "PowerShell 7",
      "commandline": "$escaped",
      "icon": "$escaped",
      "hidden": false
    },
"@
            # 只替换第一处 "list": [，把新条目插到数组首部
            $text = [regex]::Replace($text, '("list"\s*:\s*\[)', ('${1}' + "`r`n" + $entry), 1)
        }

        # 无论是否新插入，都保证默认 profile 指向它
        $text = [regex]::Replace(
            $text,
            '"defaultProfile"\s*:\s*"[^"]*"',
            ('"defaultProfile": "' + $script:TerminalProfileGuid + '"')
        )

        # 不追加 BOM，保持终端自己对文件编码的预期
        [System.IO.File]::WriteAllText($settings, $text, (New-Object System.Text.UTF8Encoding($false)))
        Add-Step 'integrate.terminal' $true ('默认 profile 已设为 PowerShell 7（已备份 ' + (Split-Path $settings -Leaf) + '.ps7bak）')
    } catch {
        Add-Step 'integrate.terminal' $false ('写入失败：' + $_.Exception.Message)
    }
}

<#
.SYNOPSIS
    把系统默认终端委托给 Windows Terminal。
#>
function Set-TerminalDelegation {
    $clsids = Get-TerminalHostClsids
    if ($null -eq $clsids) {
        Add-Step 'integrate.delegation' $false '无法从 Windows Terminal 清单解析 CLSID，跳过'
        return
    }

    try {
        $key = 'HKCU:\Console\%%Startup'
        if (-not (Test-Path -LiteralPath $key)) {
            New-Item -Path $key -Force | Out-Null
        }
        # 两个值必须不同，否则交接失败回退 conhost
        Set-ItemProperty -LiteralPath $key -Name 'DelegationConsole' -Value $clsids.Console
        Set-ItemProperty -LiteralPath $key -Name 'DelegationTerminal' -Value $clsids.Terminal
        Add-Step 'integrate.delegation' $true ('Console=' + $clsids.Console + ' Terminal=' + $clsids.Terminal)
    } catch {
        Add-Step 'integrate.delegation' $false ('写入失败：' + $_.Exception.Message)
    }
}

<#
.SYNOPSIS
    写入「在此处打开 PowerShell 7」资源管理器右键菜单（仅当前用户）。
#>
function Set-ExplorerContextMenu {
    try {
        foreach ($base in @('Directory\shell', 'Directory\Background\shell')) {
            $key = 'HKCU:\Software\Classes\' + $base + '\PowerShell7Here'
            New-Item -Path $key -Force | Out-Null
            Set-ItemProperty -LiteralPath $key -Name '(default)' -Value '在此处打开 PowerShell 7'
            Set-ItemProperty -LiteralPath $key -Name 'Icon' -Value $script:PwshAlias

            # %V 在文件夹空白处右键时展开为当前目录，%1 在选中文件夹时展开
            $cmdKey = $key + '\command'
            New-Item -Path $cmdKey -Force | Out-Null
            Set-ItemProperty -LiteralPath $cmdKey -Name '(default)' `
                -Value ('"' + $script:PwshAlias + '" -NoExit -Command Set-Location -LiteralPath ''%V''')
        }
        Add-Step 'integrate.contextmenu' $true '已写入文件夹与目录背景两处菜单项'
    } catch {
        Add-Step 'integrate.contextmenu' $false ('写入失败：' + $_.Exception.Message)
    }
}

<#
.SYNOPSIS
    用 HKCU 的 App Paths 把「运行框/地址栏敲 powershell」导向 pwsh.exe。

.DESCRIPTION
    只影响 ShellExecute 解析路径（Win+R、资源管理器地址栏、快捷方式、
    Start-Process 的 ShellExecute 分支）。命令行里敲 powershell 仍走 PATH，
    那是 System32 优先，HKCU 无法改变。
#>
function Set-AppPaths {
    try {
        $key = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\powershell.exe'
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -LiteralPath $key -Name '(default)' -Value $script:PwshAlias
        Set-ItemProperty -LiteralPath $key -Name 'Path' -Value (Split-Path -Parent $script:PwshAlias)
        Add-Step 'integrate.apppaths' $true ('powershell → ' + $script:PwshAlias)
    } catch {
        Add-Step 'integrate.apppaths' $false ('写入失败：' + $_.Exception.Message)
    }
}

<#
.SYNOPSIS
    让 .ps1 双击默认用 PowerShell 7 打开（HKCU 覆盖 HKLM 的系统关联）。
#>
function Set-ScriptAssociation {
    try {
        $key = 'HKCU:\SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell\0\Command'
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -LiteralPath $key -Name '(default)' `
            -Value ('"' + $script:PwshAlias + '" -NoExit -File "%1"')
        Add-Step 'integrate.ps1' $true '.ps1 关联已指向 PowerShell 7'
    } catch {
        Add-Step 'integrate.ps1' $false ('写入失败：' + $_.Exception.Message)
    }
}

<#
.SYNOPSIS
    依次写入全部系统集成项。
#>
function Invoke-Integrate {
    Set-TerminalDefaultProfile
    Set-TerminalDelegation
    Set-ExplorerContextMenu
    Set-AppPaths
    Set-ScriptAssociation
}

# ═══════════════════════════════════════════════════════════════
# lock：锁定 DSH 的 shell 到 PowerShell 7
# ═══════════════════════════════════════════════════════════════

<#
.SYNOPSIS
    定位当前 DSH profile 的 patch 配置文件。

.DESCRIPTION
    优先用运行环境注入的 DSH_PROFILE_DIR；缺失时回退到
    ~/.dsh/profiles/desktop/cordis.patch.yml（桌面版默认 profile）。
#>
function Get-DshPatchPath {
    # 探测顺序，靠前的优先：
    #   1) 用户显式指定的 -ProfileDir
    #   2) DSH 注入给子进程的 DSH_PROFILE_DIR（在 DSH 里跑时最准）
    #   3) 扫 ~/.dsh/profiles/*，只有一个 profile 就用它
    #   4) 多个 profile 时优先 DSH_PROFILE 指定的名字
    #   5) 仍无法唯一确定，取最近修改的那个（用户当前在用的最可能是它）
    #
    # 之所以不写死 desktop：新机器上的 profile 可能叫别的名字，
    # 而写错目录的后果是「lock 报成功但 shell 还是 5.1」，极难排查。
    $candidates = New-Object System.Collections.ArrayList

    if (-not [string]::IsNullOrWhiteSpace($ProfileDir)) {
        [void]$candidates.Add((Join-Path $ProfileDir 'cordis.patch.yml'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_PROFILE_DIR)) {
        [void]$candidates.Add((Join-Path $env:DSH_PROFILE_DIR 'cordis.patch.yml'))
    }

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }

    $root = $env:DSH_HOME
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path $env:USERPROFILE '.dsh'
    }
    $profilesRoot = Join-Path $root 'profiles'
    if (-not (Test-Path -LiteralPath $profilesRoot)) { return $null }

    $found = @(
        Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'cordis.patch.yml' } |
            Where-Object { Test-Path -LiteralPath $_ }
    )

    if ($found.Count -eq 0) { return $null }
    if ($found.Count -eq 1) { return $found[0] }

    if (-not [string]::IsNullOrWhiteSpace($env:DSH_PROFILE)) {
        $preferred = Join-Path (Join-Path $profilesRoot $env:DSH_PROFILE) 'cordis.patch.yml'
        if (Test-Path -LiteralPath $preferred) { return $preferred }
    }

    $latest = $found |
        ForEach-Object { Get-Item -LiteralPath $_ } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -ne $latest) { return $latest.FullName }

    return $null
}

<#
.SYNOPSIS
    在 profile 的 patch 层追加 pwsh-sandbox 条目，把 pwshPath 钉死。

.DESCRIPTION
    dsh-pwsh-local 的 pwshPath 是 z.string().volatile()，patch 层写成
    非空值后 resolvePwshPath 会直接返回该值，不再走 PATH 探测链。
    指向 App Execution Alias 而非带版本号的包内路径，可抗 PS7 升级。

    该配置是热重载的：保存后下一次命令即生效，无需重启 DSH。
#>
function Invoke-Lock {
    $patch = Get-DshPatchPath
    if ($null -eq $patch) {
        Add-Step 'lock' $false '未找到 DSH profile 的 cordis.patch.yml（可用 -ProfileDir 显式指定）'
        return
    }

    # 版本护栏：不同 DSH 版本的插件 id 可能不同。若这个版本根本没有
    # dsh-pwsh-sandbox，写进去只是一条无人认领的配置——lock 报成功、
    # shell 却纹丝不动，属于最难查的那类失败。这里提前喊一声。
    $installDir = $env:DSH_INSTALL_DIR
    if (-not [string]::IsNullOrWhiteSpace($installDir)) {
        $sandboxPkg = Join-Path (Split-Path $installDir -Parent) 'dsh-pwsh-sandbox'
        if (-not (Test-Path -LiteralPath $sandboxPkg)) {
            Write-Host ('[WARN] 未找到 ' + $sandboxPkg + '，当前 DSH 版本可能不使用 pwsh-sandbox，锁定可能无效')
        }
    }

    # 命中的 profile 名要在结果里露脸：多 profile 的机器上万一探测错，
    # 只有这一行能让人立刻看出它写进了哪个目录。
    $profileName = Split-Path (Split-Path $patch -Parent) -Leaf

    try {
        $text = Get-Content -LiteralPath $patch -Raw -Encoding UTF8
        if ($text -match 'id:\s*pwsh-sandbox') {
            Add-Step 'lock' $true ('profile [' + $profileName + '] 已存在 pwsh-sandbox 条目，无需重复写入')
            return
        }

        Copy-Item -LiteralPath $patch -Destination ($patch + '.ps7bak') -Force

        # YAML 单引号字符串里的反斜杠是字面量，不需要转义
        $block = "`r`n- id: pwsh-sandbox`r`n" +
                 "  name: `"@deepseek-ai/dsh-pwsh-sandbox`"`r`n" +
                 "  config:`r`n" +
                 "    pwshPath: '" + $script:PwshAlias + "'`r`n"

        # 文件末尾若没有换行，先补一个，避免和上一条粘在一起
        if (-not $text.EndsWith("`n")) { $block = "`r`n" + $block }
        Add-Content -LiteralPath $patch -Value $block -Encoding UTF8 -NoNewline

        Add-Step 'lock' $true ('profile [' + $profileName + '] 已锁定 pwshPath → ' + $script:PwshAlias)
    } catch {
        Add-Step 'lock' $false ('写入失败：' + $_.Exception.Message)
    }
}

# ═══════════════════════════════════════════════════════════════
# verify：全量校验
# ═══════════════════════════════════════════════════════════════

<#
.SYNOPSIS
    实测所有落地项，而不是只看注册表里有没有键。
#>
function Invoke-Verify {
    $state = Get-Ps7State

    # 真正跑一次 pwsh 拿版本，避免只验文件存在
    if ($state.AliasExists) {
        try {
            $ver = & $script:PwshAlias -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
            $edition = & $script:PwshAlias -NoProfile -Command '$PSVersionTable.PSEdition' 2>$null
            Add-Step 'verify.pwsh' $true ('实跑版本 ' + $ver + ' (' + $edition + ')')
        } catch {
            Add-Step 'verify.pwsh' $false ('pwsh 无法执行：' + $_.Exception.Message)
        }
    } else {
        Add-Step 'verify.pwsh' $false '执行别名不存在'
    }

    # 终端委托
    $delegation = Get-ItemProperty -Path 'HKCU:\Console\%%Startup' -ErrorAction SilentlyContinue
    if ($null -ne $delegation -and $delegation.DelegationConsole -and $delegation.DelegationTerminal) {
        $differ = ($delegation.DelegationConsole -ne $delegation.DelegationTerminal)
        Add-Step 'verify.delegation' $differ ('Console/Terminal 两个 CLSID ' + $(if ($differ) { '不同（正确）' } else { '相同（会回退 conhost）' }))
    } else {
        Add-Step 'verify.delegation' $false '终端委托未配置'
    }

    # App Paths
    $appPath = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\powershell.exe' -ErrorAction SilentlyContinue
    if ($null -ne $appPath -and $appPath.'(default)') {
        $isPs7 = ($appPath.'(default)' -like '*pwsh.exe')
        Add-Step 'verify.apppaths' $isPs7 ('App Paths → ' + $appPath.'(default)')
    } else {
        Add-Step 'verify.apppaths' $false 'App Paths 未配置'
    }

    # DSH 锁定
    $patch = Get-DshPatchPath
    if ($null -ne $patch -and ((Get-Content -LiteralPath $patch -Raw) -match 'id:\s*pwsh-sandbox')) {
        Add-Step 'verify.lock' $true 'DSH patch 层已锁定 pwshPath'
    } else {
        Add-Step 'verify.lock' $false 'DSH 未锁定，重启后可能按 PATH 顺序命中 5.1'
    }
}

# ═══════════════════════════════════════════════════════════════
# auto：智能引导（插件每次加载都会调这个）
# ═══════════════════════════════════════════════════════════════

<#
.SYNOPSIS
    先做一次廉价判定：已就绪就一步不动，有缺口才走完整流程。

.DESCRIPTION
    这个 action 会被插件在每次加载时自动触发，所以第一步必须便宜——
    只查一次 PS7 安装状态、读一次 profile 文件。

    不能简单粗暴地跑 all：全量集成会写注册表、动 settings.json，
    在已经配置好的机器上重复执行不但浪费，还会不断刷新文件时间戳，
    把「什么时候真正改过」这个线索抹掉。
#>
function Invoke-Auto {
    $state = Get-Ps7State

    # 只读判定：patch 里有没有 pwsh-sandbox 条目
    $patch = Get-DshPatchPath
    $locked = $false
    if ($null -ne $patch) {
        try {
            $locked = ((Get-Content -LiteralPath $patch -Raw -Encoding UTF8) -match 'id:\s*pwsh-sandbox')
        } catch {
            $locked = $false
        }
    }

    # 快速路径：两件事都到位就退出。配置好的机器每次冷启动都走这里，
    # 代价只有一次注册表读 + 一次文件读。
    if ($state.Installed -and $locked) {
        Add-Step 'auto' $true ('已就绪：PS7 ' + $state.Version + ' 已安装，pwshPath 已锁定，未做任何改动')
        return
    }

    # 缺口 1：PS7 本体。已装则跳过下载，避免每次启动都碰网络。
    if (-not $state.Installed) {
        Invoke-Install -Ver $script:Version -MirrorPrefix $script:Mirror -ForceReinstall $false
    } else {
        Add-Step 'auto.install' $true ('PS7 ' + $state.Version + ' 已安装，跳过下载')
    }

    # 缺口 2：系统集成 + DSH 锁定。两个函数内部都有幂等闸门，
    # 即使前一步失败也不会把已经配好的项改坏。
    Invoke-Integrate
    Invoke-Lock
    Invoke-Verify
}

# ═══════════════════════════════════════════════════════════════
# plan / confirm：先把「要改什么」摊开给人看，勾选后才动手
# ═══════════════════════════════════════════════════════════════

<#
.SYNOPSIS
    逐项算出「这一项现在什么状态、如果要改会写到哪里」，全程只读。

.DESCRIPTION
    返回 7 个条目，每条带三个字段：
      id      动作标识，与 Invoke-PlanApply 里的分支一一对应
      title   给人看的名字
      where   会落到哪个文件 / 注册表键（写进确认窗口的第二列）
      state   ready=已经到位、pending=需要改动、blocked=本机条件不满足
      detail  一句话现状说明（悬停提示与 plan 输出共用）

    这里刻意不复用 Invoke-Detect：那个函数是给「体检报告」用的，粒度和措辞
    都不同（它把「别名缺失」和「未安装」分两条讲），而确认窗口需要的是
    「做还是不做」这个二选一视图。两份判据同源（都读注册表/文件现状），
    真正动手的函数也只有一套，所以不会出现判据分叉。
#>
function Get-PlanItems {
    param(
        [string]$Ver
    )

    $items = New-Object System.Collections.ArrayList

    # ① PowerShell 7 本体：MSIX 用户级部署，下载落在 %TEMP%
    $state = Get-Ps7State
    if ($state.Installed) {
        if ($state.Version -like ($Ver + '*')) {
            $st = 'ready'
            $dt = '已安装 ' + $state.Version
        } else {
            $st = 'pending'
            $dt = '已安装 ' + $state.Version + '，将覆盖安装 ' + $Ver
        }
    } else {
        $st = 'pending'
        $dt = '未安装，将下载并安装 ' + $Ver + '（约 350 MB）'
    }
    [void]$items.Add([pscustomobject]@{
        id     = 'install'
        title  = '安装 PowerShell ' + $Ver
        where  = '当前用户 MSIX 包；安装包下载到 %TEMP%\PowerShell-' + $Ver + '.msixbundle'
        state  = $st
        detail = $dt
    })

    # ② Windows Terminal 默认 profile
    $tst = 'blocked'
    $tdt = '未安装 Windows Terminal，本项跳过'
    $tpkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $tpkg) {
        $tset = Join-Path $env:LOCALAPPDATA ('Packages\' + $tpkg.PackageFamilyName + '\LocalState\settings.json')
        if (-not (Test-Path -LiteralPath $tset)) {
            $tdt = '找不到 settings.json：' + $tset
        } else {
            try {
                $ttext = Get-Content -LiteralPath $tset -Raw -Encoding UTF8
                $hasEntry = $ttext -match [regex]::Escape($script:TerminalProfileGuid)
                $isDefault = $ttext -match ('"defaultProfile"\s*:\s*"' + [regex]::Escape($script:TerminalProfileGuid) + '"')
                if ($hasEntry -and $isDefault) {
                    $tst = 'ready'
                    $tdt = '默认 profile 已是 PowerShell 7'
                } else {
                    $tst = 'pending'
                    $tdt = '将把 Windows Terminal 的默认 profile 指向 PowerShell 7'
                }
            } catch {
                $tdt = '读取 settings.json 失败：' + $_.Exception.Message
            }
        }
    }
    [void]$items.Add([pscustomobject]@{
        id     = 'terminal'
        title  = 'Windows Terminal 默认 profile'
        where  = 'Windows Terminal 的 settings.json（改前备份为 settings.json.ps7bak）'
        state  = $tst
        detail = $tdt
    })

    # ③ 系统默认终端委托：依赖终端包提供的两个 CLSID
    $clsids = Get-TerminalHostClsids
    if ($null -eq $clsids) {
        $dst = 'blocked'
        $ddt = '无法从 Windows Terminal 清单解析 CLSID，本项跳过'
    } else {
        $delegation = Get-ItemProperty -Path 'HKCU:\Console\%%Startup' -ErrorAction SilentlyContinue
        if ($null -ne $delegation -and $delegation.DelegationConsole -and $delegation.DelegationTerminal -and ($delegation.DelegationConsole -ne $delegation.DelegationTerminal)) {
            $dst = 'ready'
            $ddt = '已委托给 Windows Terminal'
        } else {
            $dst = 'pending'
            $ddt = '将把新开的控制台交给 Windows Terminal（不再回退 conhost）'
        }
    }
    [void]$items.Add([pscustomobject]@{
        id     = 'delegation'
        title  = '系统默认终端委托'
        where  = 'HKCU\Console\%%Startup（DelegationConsole / DelegationTerminal 两个值）'
        state  = $dst
        detail = $ddt
    })

    # ④ 资源管理器右键菜单
    if (Test-Path -LiteralPath 'HKCU:\Software\Classes\Directory\shell\PowerShell7Here\command') {
        $cst = 'ready'
        $cdt = '右键菜单已存在'
    } else {
        $cst = 'pending'
        $cdt = '将新增「在此处打开 PowerShell 7」菜单项'
    }
    [void]$items.Add([pscustomobject]@{
        id     = 'contextmenu'
        title  = '资源管理器右键菜单'
        where  = 'HKCU\Software\Classes\Directory{,\Background}\shell\PowerShell7Here'
        state  = $cst
        detail = $cdt
    })

    # ⑤ App Paths：决定 Win+R 敲 powershell 落到哪个可执行文件
    $appPath = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\powershell.exe' -ErrorAction SilentlyContinue
    if ($null -ne $appPath -and $appPath.'(default)' -like '*pwsh.exe') {
        $ast = 'ready'
        $adt = 'Win+R 敲 powershell 已指向 pwsh.exe'
    } else {
        $ast = 'pending'
        $adt = '将把 Win+R / 运行框里的 powershell 导向 pwsh.exe'
    }
    [void]$items.Add([pscustomobject]@{
        id     = 'apppaths'
        title  = 'App Paths（Win+R 的 powershell）'
        where  = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\powershell.exe'
        state  = $ast
        detail = $adt
    })

    # ⑥ .ps1 关联
    $scriptCmd = (Get-ItemProperty -LiteralPath 'HKCU:\SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell\0\Command' -ErrorAction SilentlyContinue).'(default)'
    if ($scriptCmd -like '*pwsh.exe*') {
        $sst = 'ready'
        $sdt = '.ps1 已用 PowerShell 7 打开'
    } else {
        $sst = 'pending'
        $sdt = '将让 .ps1 双击默认用 PowerShell 7 打开'
    }
    [void]$items.Add([pscustomobject]@{
        id     = 'ps1'
        title  = '.ps1 文件关联'
        where  = 'HKCU\SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell\0\Command'
        state  = $sst
        detail = $sdt
    })

    # ⑦ DSH 自身的执行器锁定
    $patch = Get-DshPatchPath
    if ($null -eq $patch) {
        $lst = 'blocked'
        $ldt = '找不到 DSH profile 配置目录，本项跳过'
        $lwhere = '（未定位到 profile）'
    } else {
        $lwhere = $patch + '（改前备份为 cordis.patch.yml.ps7bak）'
        $locked = $false
        try {
            $locked = ((Get-Content -LiteralPath $patch -Raw -Encoding UTF8) -match 'id:\s*pwsh-sandbox')
        } catch {
            $locked = $false
        }
        if ($locked) {
            $lst = 'ready'
            $ldt = 'DSH 已锁定在 PowerShell 7 上'
        } else {
            $lst = 'pending'
            $ldt = '将往 profile 的 patch 层写入 pwsh-sandbox.pwshPath'
        }
    }
    [void]$items.Add([pscustomobject]@{
        id     = 'lock'
        title  = '锁定 DSH 的 shell 到 PowerShell 7'
        where  = $lwhere
        state  = $lst
        detail = $ldt
    })

    return $items
}

<#
.SYNOPSIS
    只读地把清单打成步骤行，供 ps7_bootstrap 的 plan 动作使用。
#>
function Invoke-Plan {
    param(
        [string]$Ver
    )

    $items = Get-PlanItems -Ver $Ver
    foreach ($it in $items) {
        $tag = switch ($it.state) {
            'ready'   { '已就绪' }
            'pending' { '待改动' }
            default   { '无法执行' }
        }
        Add-Step ('plan.' + $it.id) ($it.state -eq 'ready') ('[' + $tag + '] ' + $it.title + ' → ' + $it.where + '；' + $it.detail)
    }
}

<#
.SYNOPSIS
    弹确认窗口：逐条列出会改什么、写到哪里，勾选后返回选中的 id 列表。

.DESCRIPTION
    返回 $null 表示用户取消（必须一个字节都不写）。
    返回空数组表示用户一个都没勾。

    宿主以 windowsHide 方式起本脚本时，进程的 STARTUPINFO 带着 SW_HIDE，
    Windows 会把本进程「第一次 ShowWindow」的 nCmdShow 强制成隐藏，
    于是窗口建出来了却看不见。这里先显式 ShowWindow 一次把这个额度消耗掉，
    再 ShowDialog，窗口才会真的出现在屏幕上（与 DSH 提示卡插件踩过的是同一个坑）。
#>
function Show-PlanDialog {
    param(
        $Items
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if ($null -eq ('Ps7Dialog.Native' -as [type])) {
        Add-Type -Namespace Ps7Dialog -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'PowerShell 7 引导 · 确认改动'
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(780, 500)

    # 标题
    $title = New-Object System.Windows.Forms.Label
    $title.Text = '下面这些改动会落在你的本机上，勾选后才会执行：'
    $title.Location = New-Object System.Drawing.Point(16, 14)
    $title.Size = New-Object System.Drawing.Size(748, 22)
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($title)

    # 说明
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '灰色=已经到位，勾了也不会重复改；橙色=本机缺少依赖，做不了。取消则一个字节都不改。'
    $hint.Location = New-Object System.Drawing.Point(16, 38)
    $hint.Size = New-Object System.Drawing.Size(748, 20)
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $form.Controls.Add($hint)

    # 清单：两列（改动项 / 会写到哪里），带复选框
    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(16, 64)
    $list.Size = New-Object System.Drawing.Size(748, 320)
    $list.View = 'Details'
    $list.CheckBoxes = $true
    $list.FullRowSelect = $true
    $list.HeaderStyle = 'Nonclickable'
    $list.ShowItemToolTips = $true
    $list.MultiSelect = $false
    [void]$list.Columns.Add('改动项', 240)
    [void]$list.Columns.Add('会写到哪里', 480)

    foreach ($it in $Items) {
        $row = New-Object System.Windows.Forms.ListViewItem($it.title)
        [void]$row.SubItems.Add($it.where)
        $row.ToolTipText = $it.detail

        if ($it.state -eq 'ready') {
            $row.Checked = $false
            $row.ForeColor = [System.Drawing.Color]::FromArgb(130, 130, 130)
        } elseif ($it.state -eq 'pending') {
            # 待改动的项默认全勾上：用户点「应用选中项」就是最常见的意图
            $row.Checked = $true
            $row.ForeColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
        } else {
            $row.Checked = $false
            $row.ForeColor = [System.Drawing.Color]::FromArgb(190, 120, 20)
        }

        # id 挂在 Tag 上，收结果时不必再按标题反查
        $row.Tag = $it.id
        [void]$list.Items.Add($row)
    }
    $form.Controls.Add($list)

    # 底部说明：备份与权限
    $foot = New-Object System.Windows.Forms.Label
    $foot.Text = '需要管理员权限：不需要（MSIX 用户级安装）。改动前都会留备份：settings.json.ps7bak / cordis.patch.yml.ps7bak。'
    $foot.Location = New-Object System.Drawing.Point(16, 392)
    $foot.Size = New-Object System.Drawing.Size(748, 36)
    $foot.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $form.Controls.Add($foot)

    # 按钮：应用 / 取消
    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = '应用选中项'
    $okBtn.Location = New-Object System.Drawing.Point(520, 444)
    $okBtn.Size = New-Object System.Drawing.Size(120, 34)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = '取消，什么都不改'
    $cancelBtn.Location = New-Object System.Drawing.Point(648, 444)
    $cancelBtn.Size = New-Object System.Drawing.Size(120, 34)

    $form.Controls.Add($okBtn)
    $form.Controls.Add($cancelBtn)
    $form.AcceptButton = $okBtn
    $form.CancelButton = $cancelBtn

    # 结果容器：$null 表示取消
    $script:PlanChosen = $null

    $okBtn.Add_Click({
        $picked = New-Object System.Collections.ArrayList
        foreach ($row in $list.Items) {
            if ($row.Checked) { [void]$picked.Add($row.Tag) }
        }
        $script:PlanChosen = $picked
        $form.Close()
    })

    $cancelBtn.Add_Click({
        $script:PlanChosen = $null
        $form.Close()
    })

    # 先 Show 再自己补一次 ShowWindow：
    # 宿主以 windowsHide 起本进程时，STARTUPINFO 带 SW_HIDE，Windows 会把本进程
    # 「第一次 ShowWindow」的 nCmdShow 强制成隐藏——于是窗口建出来却看不见。
    # 第一次已经被 Show() 消耗掉，第二次起到的是真实参数，窗口才真的出现在屏幕上。
    #
    # 用 Show() + 自转消息循环而不是 ShowDialog()：ShowWindow 已经让窗口可见，
    # 此时再调 ShowDialog 会抛「Form that is already visible cannot be displayed
    # as a modal dialog box」，而且这一步在 5.1 里只会在 stderr 留一行异常，
    # 用户侧表现为「窗口一闪而过」，极难查。
    $form.Show()
    [void][Ps7Dialog.Native]::ShowWindow($form.Handle, 5)
    [void][Ps7Dialog.Native]::SetForegroundWindow($form.Handle)
    $form.Activate()

    while (-not $form.IsDisposed -and $form.Visible) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 40
    }
    $form.Dispose()

    return $script:PlanChosen
}

<#
.SYNOPSIS
    按用户勾选的 id 执行对应的落盘动作（顺序固定，互不依赖）。
#>
function Invoke-PlanApply {
    param(
        [string[]]$Ids,
        [string]$Ver,
        [string]$MirrorPrefix,
        [bool]$ForceReinstall
    )

    if ($Ids -contains 'install') {
        Invoke-Install -Ver $Ver -MirrorPrefix $MirrorPrefix -ForceReinstall $ForceReinstall
    }
    if ($Ids -contains 'terminal') { Set-TerminalDefaultProfile }
    if ($Ids -contains 'delegation') { Set-TerminalDelegation }
    if ($Ids -contains 'contextmenu') { Set-ExplorerContextMenu }
    if ($Ids -contains 'apppaths') { Set-AppPaths }
    if ($Ids -contains 'ps1') { Set-ScriptAssociation }
    if ($Ids -contains 'lock') { Invoke-Lock }
}

<#
.SYNOPSIS
    confirm：清单 → 确认窗口 → 只执行勾选项 → 校验。
#>
function Invoke-Confirm {
    param(
        [string]$Ver,
        [string]$MirrorPrefix,
        [bool]$ForceReinstall
    )

    $items = Get-PlanItems -Ver $Ver
    $pending = @($items | Where-Object { $_.state -eq 'pending' })

    # 已经什么都不用做时，不打扰用户：连窗口都不弹
    if ($pending.Count -eq 0) {
        Add-Step 'confirm' $true '本机已就绪，无需任何改动（未弹确认窗口）'
        return
    }

    $chosen = Show-PlanDialog -Items $items

    if ($null -eq $chosen) {
        Add-Step 'confirm' $true '用户取消，未做任何改动'
        return
    }

    # PS 5.1 里 ArrayList 为空时会被当成标量，统一成数组再判
    $ids = @($chosen)
    if ($ids.Count -eq 0) {
        Add-Step 'confirm' $true '未勾选任何项，未做任何改动'
        return
    }

    Add-Step 'confirm.approved' $true ('用户确认执行：' + ($ids -join ', '))
    Invoke-PlanApply -Ids $ids -Ver $Ver -MirrorPrefix $MirrorPrefix -ForceReinstall $ForceReinstall

    # 校验一律跑：只读，且能让用户在结果里看到最终状态
    Invoke-Verify
}

# ═══════════════════════════════════════════════════════════════
# 主调度
# ═══════════════════════════════════════════════════════════════

if (-not $Quiet) {
    Write-Host ('PowerShell 7 引导  action=' + $Action + '  version=' + $Version)
    Write-Host ('宿主当前 shell：' + $PSVersionTable.PSVersion + ' (' + $PSVersionTable.PSEdition + ')')
    Write-Host ''
}

switch ($Action) {
    'detect'    { Invoke-Detect }
    'plan'      { Invoke-Plan -Ver $Version }
    'confirm'   { Invoke-Confirm -Ver $Version -MirrorPrefix $Mirror -ForceReinstall $Force.IsPresent }
    'install'   { Invoke-Install -Ver $Version -MirrorPrefix $Mirror -ForceReinstall $Force.IsPresent }
    'integrate' { Invoke-Integrate }
    'lock'      { Invoke-Lock }
    'verify'    { Invoke-Verify }
    'auto'      { Invoke-Auto }
    'all' {
        Invoke-Install -Ver $Version -MirrorPrefix $Mirror -ForceReinstall $Force.IsPresent
        Invoke-Integrate
        Invoke-Lock
        Invoke-Verify
    }
}

# 汇总：任一步骤失败即整体判失败，但已成功的步骤不撤销
$failed = @($script:Steps | Where-Object { -not $_.ok })
$result = [pscustomobject]@{
    action = $Action
    ok     = ($failed.Count -eq 0)
    failed = $failed.Count
    steps  = @($script:Steps)
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host ('汇总：' + $script:Steps.Count + ' 步，失败 ' + $failed.Count + ' 步')
}

# 结构化结果单行输出，宿主按前缀截取后反序列化
$json = $result | ConvertTo-Json -Depth 6 -Compress
Write-Output ('##PS7RESULT##' + $json)
