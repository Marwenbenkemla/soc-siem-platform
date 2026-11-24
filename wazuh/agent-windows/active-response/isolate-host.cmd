@echo off
rem Wrapper Wazuh Active Response : stdin (JSON envoye par l'agent) est herite par PowerShell
set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0isolate-host.ps1"
exit /b %ERRORLEVEL%
