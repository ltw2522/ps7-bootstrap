@echo off
rem 发布 ps7-bootstrap 0.2.3（补 engines.dsh，供市场审核读取「适用 DSH」）
rem 沙箱内 npm publish 只会得到 202 + 暂存版本，2FA 必须在你自己终端里完成。
rem 逻辑：先看有没有 0.2.3 的暂存版本 -> 有就 approve（会提示输入 6 位验证码）；没有就 publish。
cd /d "%~dp0"
set CACHE=D:/dsh_workspace/.npm-cache-tmp

echo === npm whoami ===
call npm whoami
if errorlevel 1 goto login
goto staged

:login
echo === 未登录，先 npm login（浏览器授权 + 2FA）===
call npm login
if errorlevel 1 goto fail

:staged
echo.
echo === 当前暂存状态 ===
call npm stage list
echo.
echo 若列出 ps7-bootstrap 0.2.3 就按任意键 approve，否则按任意键 publish
pause >nul
call npm stage approve ps7-bootstrap@0.2.3 --cache %CACHE%
if not errorlevel 1 goto verify

echo === approve 未成功，改为直接 publish ===
call npm publish --cache %CACHE%
if errorlevel 1 goto fail

:verify
echo.
echo === 核对远端版本（应出现 0.2.3 且 engines.dsh 已写入）===
call npm view ps7-bootstrap dist-tags version --json
call npm view ps7-bootstrap@0.2.3 engines --json
goto end

:fail
echo === 失败：把上面最后 10 行发我 ===

:end
pause
