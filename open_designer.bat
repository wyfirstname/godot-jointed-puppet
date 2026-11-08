@echo off
rem Open the character designer in a modern browser.
rem The page is one self-contained HTML file (all art inlined), so file:// works
rem with no server. Old IE cannot run it -- prefer Chrome / Edge explicitly.
setlocal
set "PAGE=%~dp0tools\character_designer.html"
if not exist "%PAGE%" (
  echo Missing "%PAGE%"
  echo Run: python tools\gen_character_designer.py
  pause
  exit /b 1
)
for %%B in (
  "%ProgramFiles%\Google\Chrome\Application\chrome.exe"
  "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
  "%LocalAppData%\Google\Chrome\Application\chrome.exe"
  "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
  "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
) do (
  if exist %%B (
    start "" %%B "%PAGE%"
    goto :done
  )
)
start "" "%PAGE%"
:done
endlocal
