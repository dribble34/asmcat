@echo off
setlocal enabledelayedexpansion

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"

if not defined VSPATH (
    echo Could not find Visual Studio with the C++ build tools component installed.
    exit /b 1
)

call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul

if not exist build mkdir build

ml64 /nologo /c /Fo build\main.obj src\main.asm
if errorlevel 1 exit /b 1

link /nologo /subsystem:console /entry:main /out:build\asmcat.exe build\main.obj kernel32.lib
if errorlevel 1 exit /b 1

echo Build succeeded: build\asmcat.exe
