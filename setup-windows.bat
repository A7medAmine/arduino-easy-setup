@echo off
rem Arduino Easy Setup - double-click this file to start.
rem Runs setup-windows.ps1 without changing the system PowerShell execution policy.
title Arduino Easy Setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1" %*
echo.
pause
