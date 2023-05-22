import os
import shutil

def move_files(src_directory, dest_directory):
    for file in os.listdir(src_directory):
        src_path = os.path.join(src_directory, file)
        dest_path = os.path.join(dest_directory, file)
        shutil.move(src_path, dest_path)

def delete_directory(directory):
    shutil.rmtree(directory)

def process_readme(directory):
    readme_files = []
    for root, dirs, files in os.walk(directory):
        if "README.md" in files:
            readme_path = os.path.join(root, "README.md")
            readme_files.append(readme_path)
    
    if len(readme_files) > 0:
        # 按修改时间对README.md文件进行排序，保留最新版本
        readme_files.sort(key=lambda x: os.path.getmtime(x), reverse=True)
        newest_readme = readme_files[0]
        
        # 移动最新版本的README.md文件到./appstore/$A/目录下
        dest_path = os.path.join(directory, "README.md")
        shutil.move(newest_readme, dest_path)
        
        # 删除其他版本的README.md文件
        for readme_file in readme_files[1:]:
            os.remove(readme_file)

appstore_directory = "./appstore"

# 遍历所有$A文件夹
for a_dir in os.listdir(appstore_directory):
    a_path = os.path.join(appstore_directory, a_dir)
    if os.path.isdir(a_path):
        # 处理metadata文件夹
        metadata_directory = os.path.join(a_path, "metadata")
        if os.path.exists(metadata_directory):
            move_files(metadata_directory, a_path)
            delete_directory(metadata_directory)

        # 处理versions文件夹
        versions_directory = os.path.join(a_path, "versions")
        if os.path.exists(versions_directory):
            for b_dir in os.listdir(versions_directory):
                b_path = os.path.join(versions_directory, b_dir)
                if os.path.isdir(b_path):
                    dest_directory = os.path.join(a_path, b_dir)
                    move_files(b_path, dest_directory)
                    delete_directory(b_path)
            
            delete_directory(versions_directory)

        # 处理README.md文件
        process_readme(a_path)
