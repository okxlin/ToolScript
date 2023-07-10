import openpyxl
import yaml

# 打开Excel文件
workbook = openpyxl.load_workbook('app-version.xlsx')

# 获取第一个工作表
sheet = workbook.active

# 读取表格数据
data = []
for row in sheet.iter_rows(min_row=2, values_only=True):
    data.append(row)

# 构建YAML数据结构
yml_data = {
    'additionalProperties': {
        'formFields': []
    }
}

# 根据Excel数据生成YAML配置
for row in data:
    field = {
        'default': str(row[0]),
        'envKey': row[1],
        'labelEn': row[2],
        'labelZh': row[3],
        'required': bool(row[4]),
        'type': row[5]
    }

    if row[6]:
        field['random'] = bool(row[6])

    if row[7]:
        field['rule'] = row[7]

    if row[8]:
        field['edit'] = bool(row[8])

    yml_data['additionalProperties']['formFields'].append(field)

# 生成YAML文件
with open('data.yml', 'w', encoding='utf-8') as f:
    yaml.dump(yml_data, f, allow_unicode=True)

