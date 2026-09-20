@echo off
setlocal
set "PROJECT=%~dp0game"
set "GODOT="
for %%P in ("C:\Godot\Godot_v4.5-stable_win64.exe\Godot_v4.5-stable_win64.exe" "%LOCALAPPDATA%\Temp\cellwar-godot-4.5\Godot_v4.5-stable_win64.exe" "%USERPROFILE%\Downloads\Godot_v4.5-stable_win64.exe") do if exist "%%~P" set "GODOT=%%~P"
if not defined GODOT (
  echo Godot 4.5 stable was not found.
  echo Expected: C:\Godot\Godot_v4.5-stable_win64.exe\Godot_v4.5-stable_win64.exe
  pause
  exit /b 1
)
start "Cell War" "%GODOT%" --path "%PROJECT%"
endlocal
