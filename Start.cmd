@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0GTNH-Migrate.ps1"
if errorlevel 1 pause
