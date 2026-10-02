@echo off
setlocal
title Setup GitHub - Windows v3

cd /d "%~dp0"

echo.
echo ============================================================
echo               SETUP GITHUB v3 - WINDOWS 10/11
echo ============================================================
echo.
echo Dica: arraste uma PASTA sobre este arquivo para publica-la direto.
echo Este programa NAO usa C:\Windows\System32.
echo.

set "SCRIPT=%~dp0Setup-GitHub-v3.ps1"
if not exist "%SCRIPT%" goto :nofile

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

set "SETUPGH_PATH="
if not "%~1"=="" set "SETUPGH_PATH=%~1"

"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "EXITCODE=%ERRORLEVEL%"
goto :fim

:nofile
echo [X] Arquivo nao encontrado: Setup-GitHub-v3.ps1
echo     Coloque o .ps1 na mesma pasta deste .bat.
set "EXITCODE=2"

:fim
echo.
echo ============================================================
if "%EXITCODE%"=="0" (
    echo                  PROCESSO CONCLUIDO
) else (
    echo                    ERRO
    echo Codigo de saida: %EXITCODE%
)
echo ============================================================
echo.
pause
exit /b %EXITCODE%
