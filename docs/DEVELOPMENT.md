# 开发说明

## 结构

- `Sources/CMacSearch`：C 目录读取、向量化匹配和评分。
- `Sources/MacSearchCore`：扫描、连续内存索引、查询解析、拼音、FSEvents 增量更新和持久化。
- `Sources/MacSearchApp`：AppKit 搜索界面、SwiftUI 设置、中文与英文文案。
- `Sources/MacSearch`：应用入口。
- `Sources/macsearch-cli`：离线索引与搜索验证工具。
- `Tests`：核心和界面测试。
- `Resources`：应用元数据、选定图标和图标源图。
- `scripts`：构建、安装、图标打包与基本检索验证。
- `build`：忽略的本地构建与验证产物，不提交 Git。

## 扩展入口

界面文案集中在 `L10n.swift`；快捷键与首次启动策略见 `LocalEdition.swift`。
修改查询规则从 `Query.swift` 和 `Searcher.swift` 入手；修改索引范围从 `IndexConfig.swift`、`SettingsPreferences.swift` 入手。
`ApplicationExtension` 与 `SupplementarySearchProvider` 可接入额外来源和补充检索。

搜索热路径使用连续内存与按列存储，避免在逐文件循环里创建 Swift 字符串或堆对象。变更索引格式时需同时考虑加载校验与重建策略。

当前发布不检查、下载或安装远程更新。旧的通用更新组件暂时保留为内部代码，入口由 `LocalEdition.enabled` 禁用，网络清单使用不可解析的保留域名。启用更新前必须单独设计可信签名与发布链路。

## 验证

1. `scripts/build-app.sh` 验证正式构建及签名。
2. `python3 scripts/smoke-test.py` 用临时文件验证中文、拼音、扩展名检索。
3. `swift test` 需要完整 Xcode。仅有 Command Line Tools 的机器可能报 `no such module XCTest`，这不能算测试通过。
4. `scripts/build-app.sh --debug` 后，可用 `build/debug/Mac Search.app/Contents/MacOS/MacSearch --snapshot <输出.png> --state settings` 验证界面。搜索快照使用样例索引，避免提交个人文件路径。

安装脚本不删除任何旧应用、索引、偏好或钥匙串内容。卸载时删除应用即可；索引和偏好可按需单独保留或清理。
