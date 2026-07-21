@echo off
cd /d "%~dp0"
python tv_player_desktop.py
if errorlevel 1 pause
