import os
import json
import yaml

class IndentDumper(yaml.Dumper):
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)

def convert_json_to_yml(json_file):
    with open(json_file, 'r', encoding='utf-8') as f:
        data = json.load(f)

    tag_mapping = {
        'Tool': '工具',
    }

    yml_template = {
        'name': data['name'],
        'tags': [
            tag_mapping.get(tag, tag) for tag in data['tags']
        ],
        'title': data['shortDescZh'],
        'type': '工具' if data['type'] == 'tool' else '建站',
        'description': data['shortDescZh'],
        'additionalProperties': {
            'key': data['key'],
            'name': data['name'],
            'tags': [
                'Tool'
            ],
            'shortDescZh': data['shortDescZh'],
            'shortDescEn': data['shortDescEn'],
            'type': 'tool',
            'crossVersionUpdate': data['crossVersionUpdate'],
            'limit': data['limit'],
            'recommend': 0,
            'website': data['website'],
            'github': data['github'],
            'document': data['document']
        }
    }

    yml_file = os.path.join(os.path.dirname(json_file), 'data.yml')
    with open(yml_file, 'w', encoding='utf-8') as f:
        yaml.dump(yml_template, f, Dumper=IndentDumper, default_flow_style=False, sort_keys=False, allow_unicode=True, indent=4)

    print(f'Successfully converted {json_file} to {yml_file}')

# 遍历appstore文件夹下的所有文件夹
appstore_dir = './appstore'
for folder_name in os.listdir(appstore_dir):
    folder_path = os.path.join(appstore_dir, folder_name)

    # 检查是否是文件夹
    if os.path.isdir(folder_path):
        json_file = os.path.join(folder_path, 'app.json')

        # 检查app.json文件是否存在
        if os.path.isfile(json_file):
            convert_json_to_yml(json_file)
