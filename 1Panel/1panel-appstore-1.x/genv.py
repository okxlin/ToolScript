import json

# 读取 JSON 文件
with open("config.json", "r") as f:
    data = json.load(f)

# 从 JSON 数据中提取表单字段列表
form_fields = data.get("formFields", [])

# 构造 .env.sample 文件内容
env_sample_content = ""
for item in form_fields:
    env_key = item.get("envKey", "")
    default_value = item.get("default", "")
    env_sample_content += f"{env_key}='{default_value}'\n"

# 将 .env.sample 内容写入文件
with open(".env.sample", "w") as f:
    f.write(env_sample_content)

print(".env.sample 文件已生成。")
