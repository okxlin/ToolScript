@echo off

rem 设置输入参数为脚本拖动到的文件路径
set "input_file=%~1"

rem 设置Python脚本的名称
set "py_script=d2c.py"

rem 运行Python脚本生成配置文件
echo 正在生成配置文件，请稍候...
python %py_script% %input_file%

rem 提示用户完成
echo 配置文件已生成。
done
