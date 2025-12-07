@echo off
REM Build script for IntervalShadingTetrahedron
REM Ensures shaders are recompiled by touching them before build

cd /d "%~dp0"

REM Touch all shader files to force recompilation using PowerShell
powershell -Command "Get-ChildItem *.hlsl | ForEach-Object { $_.LastWriteTime = Get-Date }"

REM Run MSBuild
"C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe" IntervalShadingTetrahedron.vcxproj -p:Configuration=Debug -p:Platform=x64 -v:m

if %ERRORLEVEL% EQU 0 (
    echo Build succeeded: bin\runnable.exe
) else (
    echo Build FAILED
    exit /b 1
)
