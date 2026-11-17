@echo off
rem Desinstala o Rekognitor do Windows (duplo clique). Detalhes: docs\MANUAL.md
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows\uninstall.ps1" %*
if errorlevel 1 pause
