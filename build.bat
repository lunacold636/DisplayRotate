@echo off
setlocal
cd /d "%~dp0"
rem ??????? .NET Framework 4.8 ??????????????
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"

"%CSC%" /nologo /target:winexe /optimize+ /codepage:65001 /out:DisplayRotate.exe ^
  /r:System.dll /r:System.Core.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Management.dll ^
  /resource:pic\logo-green.png,DisplayRotate.logoGreen.png ^
  /resource:pic\logo-red.png,DisplayRotate.logoRed.png ^
  Program.cs SettingsStore.cs RoundedPanel.cs DisplayRotator.cs Gy25t.cs IconFactory.cs MainForm.cs

if %errorlevel%==0 (echo Build OK - DisplayRotate.exe) else (echo Build FAILED)
endlocal
