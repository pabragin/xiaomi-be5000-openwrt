@echo off
rem OpenWrt for Xiaomi BE5000: run install.sh on Windows.
rem Uses Git Bash (comes with Git for Windows) or, without it, WSL.
rem   install.bat [root@192.168.31.1] [plain|full]
setlocal
cd /d "%~dp0"
set "BASH_EXE="
for %%P in ("%ProgramFiles%\Git\bin\bash.exe" "%ProgramFiles(x86)%\Git\bin\bash.exe" "%LocalAppData%\Programs\Git\bin\bash.exe") do if not defined BASH_EXE if exist %%P set "BASH_EXE=%%~P"
if defined BASH_EXE goto gitbash
where wsl >nul 2>nul && goto wsl
echo STOP: install Git for Windows from https://git-scm.com/download/win (or WSL), then run install.bat again
pause
exit /b 1

:gitbash
"%BASH_EXE%" install.sh %*
goto done

:wsl
wsl sh install.sh %*

:done
set RC=%ERRORLEVEL%
pause
exit /b %RC%
