@echo off
rem Instala o Rekognitor no Windows (duplo clique). Detalhes: docs\MANUAL.md
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows\install.ps1" %*
if errorlevel 1 pause
