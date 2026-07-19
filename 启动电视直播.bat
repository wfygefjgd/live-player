@echo off
chcp 65001 >nul
echo ========================================
echo    Python TV Player Pro
echo    电视直播软件
echo ========================================
echo.

python --version >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到Python
    echo 下载: https://www.python.org/downloads/
    pause
    exit /b 1
)

echo 正在检查依赖...
pip show PySide6 >nul 2>&1
if errorlevel 1 (
    echo 安装 PySide6...
    pip install PySide6
)

pip show python-vlc >nul 2>&1
if errorlevel 1 (
    echo 安装 python-vlc...
    pip install python-vlc
)

pip show requests >nul 2>&1
if errorlevel 1 (
    echo 安装 requests...
    pip install requests
)

echo.
echo 启动电视直播...
python tv_player_pro.py

pause
