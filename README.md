<p align="center"><img src="Resources/AppIcon.png" width="144" alt="Mac Search icon"></p>
<h1 align="center">Mac Search</h1>
<p align="center">中文优先、在本机运行、可以按自己的习惯改造的 macOS 文件搜索工具。</p>

我是 Stephen，一名 AI 产品实践者。Mac Search 是我维护的个人开源项目：把日常文件搜索做得顺手，并持续围绕自己的知识整理与工作流程扩展功能。

## 当前可以做什么

- 按 **⌥⇧⌘F** 唤起搜索面板，输入文件名即时筛选。
- 默认中文界面，可切换英文或跟随系统。
- 默认隐藏菜单栏图标，通过快捷键唤起；可在设置中重新显示。
- 支持中文、拼音全拼和首字母搜索。
- 按文件类型、扩展名、路径、大小、修改时间过滤。
- 打开文件、在访达中显示、快速预览、复制路径及拖放。
- 自建本机索引，通过文件系统事件更新；文件名搜索不依赖 Spotlight。
- 调整索引范围和排除目录，设置与索引留在本机。

当前侧重文件名和路径检索，尚未提供文档全文搜索、图片 OCR 或外置磁盘离线管理。后续会按实际使用需求逐步扩展。

## 从源码构建

要求：macOS 14 或更新，Swift 5.10 或更新。Apple Silicon 已在本机验证。运行完整单元测试需要含 XCTest 的完整 Xcode。

```sh
git clone https://github.com/Stephen-creater/mac-search.git
cd mac-search
scripts/build-app.sh
open 'build/Mac Search.app'
```

安装到应用程序目录：先退出已运行的 Mac Search，再运行 `scripts/install.sh`。
调试构建：`scripts/build-app.sh --debug`。

构建包采用本机临时签名，未进行 Apple 公证。完全磁盘访问为可选权限；未授权时，无法读取的目录会被跳过。

## 常用搜索

| 输入 | 含义 |
| --- | --- |
| `wd` / `wendang` | 查找名称包含「文档」的文件 |
| `foo bar` | 同时匹配两个词 |
| `readme !node_modules` | 排除指定路径片段 |
| `ext:pdf;docx` | 按扩展名筛选 |
| `kind:image` | 查找图片文件 |
| `size:>10mb` | 筛选大文件 |
| `dm:today` | 今天修改的文件 |

按 ⌘/ 打开搜索语法速查。

## 开发与验证

```sh
swift test
python3 scripts/smoke-test.py
```

GitHub Actions 使用完整 Xcode 执行编译和测试。代码结构、扩展入口与维护方式见 [开发说明](docs/DEVELOPMENT.md)。

- 应用标识：`local.stephen.macsearch`
- 索引目录：`~/Library/Application Support/Mac Search/`
- 自动更新：当前关闭；更新通过本仓库重新构建和安装。

本项目以 MIT 许可证发布，包含 MIT 授权的现有代码与本项目改动；版权和许可声明见 [LICENSE](LICENSE)。
