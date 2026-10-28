@echo off
rem Raid Loot Controller installer and updater for WoW: Forever. Double-click it.
rem The release copy has Install-RaidLootController.ps1 pasted below the
rem marker line, so it is one file. This repo copy has no payload and runs
rem the .ps1 that sits next to it.
setlocal
set "RLC_SELF=%~f0"
set "RLC_PS1=%~dp0Install-RaidLootController.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:RLC_SELF); $m='#RLC'+'PAYLOAD#'; $i=$t.IndexOf($m); if ($i -ge 0) { & ([ScriptBlock]::Create($t.Substring($i + $m.Length))) } elseif (Test-Path -LiteralPath $env:RLC_PS1) { & $env:RLC_PS1 } else { Write-Host 'Install-RaidLootController.ps1 is missing. Download the installer again.'; [void](Read-Host 'Press Enter to close'); exit 1 }"
exit /b %errorlevel%
