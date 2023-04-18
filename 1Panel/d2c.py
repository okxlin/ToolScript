import json
import re
import sys

# 读取输入文件和输出文件名
input_file = sys.argv[1]
output_file = "config.json"

# 读取输入文件
with open(input_file, "r") as f:
    content = f.read()

# 从输入文件中提取所有环境变量
env_vars = re.findall(r'\$\{([^}]+)\}', content)

# 初始化表单字段数组
formFields = []

# 遍历环境变量，并将它们添加到表单字段数组中
for env_var in env_vars:
    formFields.append({
        "type": "text",
        "labelZh": "",
        "labelEn": "",
        "required": True,
        "default": "",
        "rule": "paramCommon",
        "envKey": env_var
    })

# 创建最终的 JSON 对象
json_data = {
    "formFields": formFields
}

# 格式化 JSON 数据
json_string = json.dumps(json_data, indent=2)

# 将格式化后的 JSON 字符串写入输出文件
with open(output_file, "w") as f:
    f.write(json_string)

print(f"已将格式化的 JSON 对象写入 {output_file}")
