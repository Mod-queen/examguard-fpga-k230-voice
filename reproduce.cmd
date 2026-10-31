@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
if defined EXAMGUARD_PYTHON (
  "%EXAMGUARD_PYTHON%" -X utf8 "%~dp0tools\reproduce.py" %*
) else if exist "%~dp0.venv\Scripts\python.exe" (
  "%~dp0.venv\Scripts\python.exe" -X utf8 "%~dp0tools\reproduce.py" %*
) else (
  python -X utf8 "%~dp0tools\reproduce.py" %*
)
exit /b %errorlevel%
