# 介绍

这是个`1panel`1.x版本商店的本地应用转换为2.0版本商店配置的脚本。主要使用`python`，`bat`脚本仅仅是用于调用而已。

感谢`ChatGPT`。

# 使用方法

- 1.注意按顺序使用，脚本前带有顺序1>2>3；
- 2.如果使用`bat`来运行，注意`py`文件名要和`bat`文件里的相对应，默认已一致；
- 3.最终保留了原始`json`文件，方便与生成的`yaml`文件做校对，校对完成可以自行删除；
- 4.需要把原旧版本应用放到一个`"appstore"`文件夹下，脚本与`"appstore"`文件夹是同一级别；

> 文件夹结构如下
>> "./appstore/旧版本应用"
>> 
>> `bat`与`py`脚本
