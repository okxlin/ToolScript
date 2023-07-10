@echo off

set VENV_NAME=venv

if not exist %VENV_NAME% (
    echo 正在创建 Python 虚拟环境（%VENV_NAME%）...
    python -m venv %VENV_NAME%
    echo 虚拟环境创建完成。
) else (
    echo Python 虚拟环境（%VENV_NAME%）已存在，跳过创建步骤。
)

pip install openpyxl pyyaml
python app-version_xlsx2yml.py
