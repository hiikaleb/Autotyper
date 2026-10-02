@echo off
setlocal enabledelayedexpansion
title AutoTyper - Build (Melhorado)
color 0A

echo.
echo ==========================================
echo          AutoTyper - BUILD v2
echo ==========================================
echo.

REM Verifica Python
echo [1/7] Verificando Python...
python --version >nul 2>&1
if errorlevel 1 (
    echo.
    echo ERRO: Python nao encontrado!
    echo.
    echo Baixe em: https://www.python.org/downloads/
    echo Certifique-se de marcar "Add Python to PATH" na instalacao.
    echo.
    pause
    exit /b 1
)
python --version

echo.
echo [2/7] Atualizando pip...
python -m pip install --upgrade pip -q

echo.
echo [3/7] Instalando dependencias...
python -m pip install -r requirements.txt -q
if errorlevel 1 (
    echo.
    echo ERRO: falha ao instalar dependencias.
    pause
    exit /b 1
)

echo.
echo [4/7] Instalando PyInstaller...
python -m pip install pyinstaller -q
if errorlevel 1 (
    echo.
    echo ERRO: falha ao instalar PyInstaller.
    pause
    exit /b 1
)

echo.
echo [5/7] Limpando builds anteriores...
if exist build (
    echo   Deletando build\
    rmdir /s /q build >nul 2>&1
)
if exist dist (
    echo   Deletando dist\
    rmdir /s /q dist >nul 2>&1
)
if exist build rmdir /s /q build >nul 2>&1
if exist dist rmdir /s /q dist >nul 2>&1

echo.
echo [6/7] Gerando AutoTyper.exe...
python -m PyInstaller ^
    --noconfirm ^
    --clean ^
    --windowed ^
    --onedir ^
    --name AutoTyper ^
    --icon AutoTyper.ico ^
    --add-data "index.html;." ^
    --add-data "style.css;." ^
    --add-data "script.js;." ^
    --add-data "config.json;." ^
    --add-data "AutoTyper.ico;." ^
    --add-data "AutoTyper_logo.png;." ^
    --add-data "engine;engine" ^
    --hidden-import=pyautogui ^
    --hidden-import=keyboard ^
    --hidden-import=pyperclip ^
    --hidden-import=PIL ^
    --hidden-import=pystray._win32 ^
    --hidden-import=PIL._tkinter_finder ^
    --hidden-import=psutil ^
    main.py

if errorlevel 1 (
    echo.
    echo ERRO: PyInstaller falhou.
    echo.
    echo Tente:
    echo   1. Deletar build\ e dist\ manualmente
    echo   2. Rodar este script novamente
    echo.
    pause
    exit /b 1
)

echo.
echo [7/7] Criando pasta screenshots...
if not exist "dist\AutoTyper\screenshots" mkdir "dist\AutoTyper\screenshots"

echo.
echo ==========================================
echo          CONCLUIDO COM SUCESSO!
echo ==========================================
echo.
echo Arquivo: dist\AutoTyper\AutoTyper.exe
echo.
echo PROXIMO PASSO: De dois cliques em AutoTyper.exe
echo.
echo AVISO SOBRE ANTIVIRUS:
echo Este app usa hooks de teclado e injeta digitacao (como um keylogger
echo tecnicamente funciona), entao alguns antivirus podem sinalizar o
echo .exe por heuristica, mesmo sem ser malicioso. Se isso acontecer:
echo   1. Adicione a pasta dist\AutoTyper as exclusoes do Windows Defender.
echo   2. Nao va compactar o .exe com UPX/protetores extras (ja esta
echo      desativado neste build).
echo   3. Se for distribuir para outras pessoas, considere assinar o
echo      executavel com um certificado de codigo (code signing).
echo.
pause
