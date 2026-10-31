@echo off
setlocal
cd /d "%~dp0"
set "examguard_python=%~dp0.venv\Scripts\python.exe"
if not exist "%examguard_python%" set "examguard_python=python"
"%examguard_python%" "%~dp0src\pc\start_examguard.py" %*
if errorlevel 1 pause
endlocal
