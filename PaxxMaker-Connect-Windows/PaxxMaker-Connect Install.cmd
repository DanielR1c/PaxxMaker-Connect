@echo off
title PaxxMaker-Connect Install
set "PS=%~dp0scripts\install.ps1"
if not exist "%PS%" set "PS=%~dp0src\scripts\install.ps1"
rem %~dp0 ends with a backslash, and "...\" would make PowerShell read the
rem closing quote as escaped - the path then carries a stray quote character.
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS%" -Root "%ROOT%"
