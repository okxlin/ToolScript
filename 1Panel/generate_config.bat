@echo off

set "input_file=%~1"
set "py_script=d2c.py"

rem Run the Python script to generate the config.json file
python %py_script% %input_file%

echo Done