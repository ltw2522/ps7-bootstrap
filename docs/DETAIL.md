# PowerShell 7 bootstrap

Installs PowerShell 7 alongside the built-in Windows PowerShell, wires it into the places you actually launch a shell from, and switches the harness's own command executor over to it.

## Why this exists

The 5.1 build that ships with Windows is an OS component: it can be run side by side with 7, not replaced by it. And installing 7 is only half the job. After `pwsh.exe` lands on disk, typing `powershell` in the Run box still starts 5.1, double-clicking a `.ps1` still hands it to 5.1, and the harness's `pwsh` tool resolved its interpreter once at process start and will not switch on its own. This plugin finishes those steps in one pass.

## Actions

| action | effect | touches the system |
| --- | --- | --- |
| `plan` | List the seven candidate changes with their state (ready / pending / blocked) and destination | read-only |
| `confirm` | Show that list in a confirmation window — one row per change, naming the file or registry key it writes — and apply only what is ticked | whatever the user ticks |
| `detect` | Report install state, execution alias, terminal delegation, App Paths | read-only |
| `install` | Download the MSIX and deploy it for the current user | installs a package |
| `integrate` | Terminal default profile, terminal delegation, Explorer context menu, `Win+R` resolution, `.ps1` association | writes HKCU and Terminal settings.json |
| `lock` | Pin `pwshPath` in the DSH profile patch layer | writes `~/.dsh/profiles/<profile>/cordis.patch.yml` |
| `verify` | Run pwsh for its real version and re-check every gate above | read-only |
| `all` / `auto` | Non-interactive batch paths (`auto` runs the cheap check first) | everything / depends on the gap |

Every action is idempotent: re-running fills in what is missing instead of duplicating entries.

## Loading the plugin shows a confirmation card first

About two seconds after load the plugin works out one list: what is installed, what is missing, and where each change would land. If anything is pending it opens a window with that list — two columns, the change on the left and its destination (file path or registry key) on the right, with the current state as a hover hint. Pending rows are ticked, already-satisfied rows are greyed out (ticking them changes nothing), rows missing a dependency are orange.

"Apply selected" runs only the ticked rows and then re-runs `verify`; "Cancel" writes nothing at all — not even a backup file. Machines that are already configured never see the window: two filesystem probes settle it.

The behaviour is controlled by the `autoRun` config key:

| value | behaviour |
| --- | --- |
| `ask` (default) | Show the confirmation window; apply what the user ticks |
| `off` | Do nothing on load; drive everything through `ps7_bootstrap` manually |
| `lock-only` | Only pin `pwshPath`; no downloads, no terminal or registry changes |
| `full` | Legacy: fill every gap without asking (unattended machines only) |

To adjust it, add one line to this plugin's entry in the profile's `cordis.patch.yml`:

```yaml
- id: ps7-bootstrap-tool
  name: ps7-bootstrap
  config:
    autoRun: off
```

The automatic run never blocks startup and its failure never affects the host: the outcome is kept in the module's `lastAutoRun`, and `ps7_bootstrap(action:"verify")` always tells you the real state.

## Install path and privileges

Per-user MSIX deployment through `Add-AppxPackage`; no administrator rights needed. 5.1 stays untouched and both coexist.

Downloads try `ghproxy.net` → `gh-proxy.com` → `ghfast.top` → direct GitHub in order, because large GitHub assets frequently time out from mainland networks. Pass `mirror` to use your own prefix. 7.7.0 is verified against a built-in SHA-256; other versions are accepted on package size alone (>100 MB counts as complete).

## What gets written

- `HKCU\Console\%%Startup` — `DelegationConsole` and `DelegationTerminal`. The two CLSIDs must differ; writing the same one activates the COM server but fails the handoff and silently falls back to conhost. Both are read at runtime from Windows Terminal's `AppxManifest.xml`, never hardcoded.
- Windows Terminal `settings.json` — rewrites `defaultProfile` and adds a `PowerShell 7` profile. The file is JSONC, so it is patched with a regex rather than a JSON parser, and a `.ps7bak` copy is left behind.
- `HKCU\SOFTWARE\Classes\Directory\shell\PowerShell7Here`, `Directory\Background\shell\PowerShell7Here`, `Microsoft\Windows\CurrentVersion\App Paths\powershell.exe`, `Microsoft.PowerShellScript.1\Shell\0\Command` — all HKCU, current user only.

## Where it still lands on 5.1

Typing `powershell` inside `cmd` or Git Bash still starts 5.1. PATH decides that: `System32\WindowsPowerShell\v1.0` comes first, and `WindowsApps` contains only `pwsh.exe`, no `powershell.exe` alias. Fixing it means editing the machine PATH, which needs administrator rights; this plugin does not go there.

Entry points that go through `ShellExecute` — the Run box, Explorer's address bar, shortcuts, `Start-Process` — are covered. Do not verify with `Start-Process powershell` though: that path uses `CreateProcess` PATH search and never consulted App Paths in the first place. Check `$PSVersionTable.PSEdition` instead.

## Rollback

```powershell
# Remove 7, keep 5.1
Get-AppxPackage Microsoft.PowerShell | Remove-AppxPackage

# Undo the integrations: delete the HKCU keys listed above and restore settings.json from the .ps7bak copy
```
