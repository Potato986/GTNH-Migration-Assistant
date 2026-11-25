[下载 Windows 单文件 EXE](https://github.com/Potato986/GTNH-Migration-Assistant/releases/download/v0.2/GTNH-Migration-Assistant-v0.2-Windows.exe)

双击运行，选择旧实例与新实例，勾选项目并预览后即可迁移。

- 新增汉化版本选择，可浏览 Kiwi233/Translation-of-GTNH 的发布版本和每日构建，选择具体压缩包。
- 确认迁移时下载汉化并覆盖到目标游戏目录，覆盖前备份原文件并校验安装结果。
- 查询和下载支持取消与超时。网络异常时跳过汉化、提供手动下载页，其他迁移项可以完成。
- 自动发现常见启动器目录里的 GTNH 实例，也可搜索所有本地磁盘或手动选择。
- 目标尚未生成 options.txt 时，第一次就能选择迁移快捷键和游戏设置。

汉化来自 [Translation-of-GTNH](https://github.com/Kiwi233/Translation-of-GTNH/releases)。请选择与目标整合包相符的版本，旧版完整包会覆盖 scripts。特定老版本的清理和任务书重载要求，请参阅汉化包内的使用说明。

汉化备份位于目标目录的 `.gtnh-translation-backup-*` 文件夹，其中 `original` 保存覆盖前的文件，`files.json` 记录本次安装清单。安装中途失败会尝试恢复本次改动。

自动化验收覆盖复制校验、配置备份恢复、首次设置迁移、GTNH 识别、汉化文件安装与备份、非法路径拦截和网络取消。另使用上游每日构建 7z 在临时实例验证了 923 个文件的安装。本版本延续现有 WinForms 界面。
