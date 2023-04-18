import json
import re
import sys

input_file = sys.argv[1]
output_file = "config.json"

# Read the input file
with open(input_file, "r") as f:
    content = f.read()

# Extract all the environment variables from the input file
env_vars = re.findall(r'\$\{([^}]+)\}', content)

# Initialize the formFields array
formFields = []

# Iterate over the environment variables and add them to the formFields array
for env_var in env_vars:
    formFields.append({
        "type": "text",
        "labelZh": "",
        "labelEn": "",
        "required": True,
        "default": "",
        "envKey": env_var
    })

# Create the final JSON object
json_data = {
    "formFields": formFields
}

# Format the JSON data
json_string = json.dumps(json_data, indent=2)

# Write the formatted JSON string to the output file
with open(output_file, "w") as f:
    f.write(json_string)

print(f"Formatted JSON object written to {output_file}")
