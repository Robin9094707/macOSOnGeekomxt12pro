@echo off
rem GEEKOM XT12 Pro - macOS 26 Tahoe + macOS 27 Golden Gate Builder (Doppelklick genuegt)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0builder\Start.ps1"
if errorlevel 1 pause
