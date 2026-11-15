@echo off
setlocal
rem Add local host names for this DNF90 server to the Windows hosts file.
rem Run again is safe: the line is appended only once.
rem   --check : print the planned change without touching hosts or asking for UAC

set "HOSTS=%SystemRoot%\System32\drivers\etc\hosts"
set "LINE=192.168.200.130 players.purplemagic.test gm.purplemagic.test"

net session >nul 2>&1
if errorlevel 1 (
  if /I "%~1"=="--check" (
    echo [CHECK] Not elevated. Would request UAC, then append to %HOSTS%:
    echo         %LINE%
    exit /b 0
  )
  echo Administrator rights are required. Requesting elevation...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

findstr /C:"players.purplemagic.test" "%HOSTS%" >nul 2>&1
if not errorlevel 1 goto verify

copy "%HOSTS%" "%HOSTS%.bak" >nul 2>&1
>>"%HOSTS%" echo.
>>"%HOSTS%" echo 192.168.200.130 players.purplemagic.test gm.purplemagic.test
echo [OK] hosts updated: 192.168.200.130 players.purplemagic.test gm.purplemagic.test
:verify

ipconfig /flushdns >nul 2>&1
echo.
echo Resolving players.purplemagic.test ...
ping -n 2 players.purplemagic.test
echo.
echo If the address above is 192.168.200.130, the local host name works.
pause
