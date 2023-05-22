import os
import yaml
import json

def convert_json_to_yaml(json_file_path, output_file_path, encoding='utf-8'):
    with open(json_file_path, 'r', encoding=encoding) as json_file:
        json_data = json.load(json_file)

    yaml_data = {
        "additionalProperties": {
            "formFields": []
        }
    }

    for field in json_data["formFields"]:
        if "envKey" not in field:
            continue

        yaml_field = {
            "default": field.get("default", None),
            "envKey": field["envKey"],
            "labelEn": field.get("labelEn", ""),
            "labelZh": field.get("labelZh", ""),
            "required": field.get("required", False),
            "type": field.get("type", "")
        }

        if "random" in field:
            yaml_field["random"] = field["random"]
        if "rule" in field:
            yaml_field["rule"] = field["rule"]
        if "edit" in field:
            yaml_field["edit"] = field["edit"]

        yaml_data["additionalProperties"]["formFields"].append(yaml_field)

    with open(output_file_path, 'w', encoding=encoding) as output_file:
        yaml.dump(yaml_data, output_file, indent=4, allow_unicode=True)

    # 读取生成的YAML文件内容并替换字符串
    with open(output_file_path, 'r', encoding='utf-8') as f:
        yaml_content = f.readlines()

    # 对每行进行缩进处理
    indented_yaml_content = []
    for line in yaml_content:
        if line.startswith("        ") and ":" in line:
            indented_line = "          " + line[8:]
            indented_yaml_content.append(indented_line)
        else:
            indented_yaml_content.append(line)

    # 替换字符串 "    -   default" 为 "        - default"
    for i in range(len(indented_yaml_content)):
        if indented_yaml_content[i].startswith("    -   default"):
            indented_yaml_content[i] = indented_yaml_content[i].replace("    -   default", "        - default")

    # 将处理后的内容写回文件
    with open(output_file_path, 'w', encoding='utf-8') as f:
        f.writelines(indented_yaml_content)

def convert_versions_to_yaml(directory_path):
    for root, dirs, files in os.walk(directory_path):
        if "versions" in root:
            for file in files:
                if file == "config.json":
                    json_file_path = os.path.join(root, file)
                    output_file_path = os.path.join(root, "data.yml")
                    convert_json_to_yaml(json_file_path, output_file_path)
                    print("Converted:", json_file_path, "to", output_file_path)

# 输入源目录
source_directory = "./appstore"

# 遍历目录并转换versions目录下的config.json文件为YAML文件
convert_versions_to_yaml(source_directory)
