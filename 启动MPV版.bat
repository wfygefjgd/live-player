@echo off
chcp 65001 >nul
echo ========================================
echo    TV Player MPV 版本
echo ========================================
echo.

python --version >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到Python
    pause
    exit /b 1
)

echo 正在检查依赖...
pip show PySide6 >nul 2>&1
if errorlevel 1 (
    pip install PySide6
)

pip show requests >nul 2>&1
if errorlevel 1 (
    pip install requests
)

echo.
echo 检查mpv播放器...
mpv --version >nul 2>&1
if errorlevel 1 (
    echo [提示] 未找到mpv，请下载安装:
    echo https://sourceforge.net/projects/mpv-player-windows/
    echo 或将mpv.exe放在C:\mpv\目录下
    echo.
)

echo 启动播放器...
python tv_player_mpv.py

pause
