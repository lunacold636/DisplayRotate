@echo off
setlocal
cd /d "%~dp0.."
rem Build SensorProbe demo (needs no dev env, uses system csc.exe)
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"

"%CSC%" /nologo /target:exe /optimize+ /codepage:65001 /out:tools\SensorProbe.exe ^
  /r:System.dll /r:System.Core.dll ^
  tools\SensorProbe.cs Gy25t.cs Log.cs

if %errorlevel%==0 (echo Build OK - tools\SensorProbe.exe) else (echo Build FAILED)
endlocal