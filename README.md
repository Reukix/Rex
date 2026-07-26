# Rex

Rex 是一款面向 macOS 的原生桌面浏览器设计与工程原型，围绕垂直标签页、工作空间、双页面分屏和默认隐私保护展开。

当前版本为 **v0.8.1**。它在原生 SwiftUI 产品外壳和 CEF/Chromium ARM64 运行时之上提供 SQLite 会话、垂直标签与工作空间、仅左右双页面分屏、精选域名目录隐私盾牌、权限、隐私窗口和下载管理。v0.8.1 为历史记录加入按过去 1 小时、24 小时、7 天或所有时间永久删除的入口，收紧收藏与下载空状态的顶部间距，并把导航栏放入 macOS 红黄绿窗口按钮右侧。Swift Package 保留 WebKit 预览构建，真实 Chromium 构建使用生成的 Xcode 工程。

隐私盾牌分为三层：Swift 只在顶层导航时清理已知追踪参数并尝试把 HTTP 升级为 HTTPS；CEF 请求层使用内置的 45 个广告、41 个追踪、10 个指纹和 8 个社交目录条目取消命中的子资源请求；第三方 Cookie 则由 CEF profile 的全局 Cookie 设置限制。标准模式拦截第三方广告与追踪目录，并在默认开启的指纹保护下拦截第三方已知指纹服务；严格模式再加入社交目录；自定义模式映射为 CEF aggressive 策略，允许广告/追踪目录匹配第一方请求，并对第三方请求使用路径启发式。开发者工具只使用 CEF 150 自带的同版本 Chromium DevTools 前端。

## 运行

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run Rex
```

最低部署目标为 macOS 14，仅支持 Apple Silicon（arm64）。Intel Mac 不在支持范围内，构建脚本、Swift 编译条件和 CEF 锁文件都会拒绝其他架构。

真实 Chromium 构建：

```bash
Scripts/fetch-cef.sh
Scripts/build-cef-runtime.sh
xcodegen generate --spec project.yml
open Rex.xcodeproj
```

一键构建并打包含 Chromium 的完整应用包：

```bash
Scripts/package-chromium-app.sh 0.8.1 810 Debug
# 产物：Dist/Rex.app 与 Dist/Rex-v0.8.1-macos-arm64-chromium.zip
```

CEF 固定为 `150.0.14`，对应 Chromium `150.0.7871.129`。`Vendor/CEF` 和下载归档不进入版本控制，可随时根据锁文件重建。

## 文档入口

- [产品需求基线](Documentation/ProductRequirements.md)
- [交互与信息架构](Documentation/InteractionDesign.md)
- [技术架构](Documentation/Architecture.md)
- [安全、隐私与性能](Documentation/SecurityPrivacyPerformance.md)
- [测试与交付计划](Documentation/DeliveryPlan.md)
- [功能状态](FEATURES.md)
- [路线图](ROADMAP.md)

## 当前边界

- CEF 页面、GPU/网络/存储/Renderer 多进程和运行时嵌入已通过完整 Xcode arm64 Debug 构建验证。
- 本地 Debug 包使用 `CODE_SIGNING_ALLOWED=NO`；Developer ID 签名、公证与自动更新仍属于正式发布阶段。
- 精选域名目录随应用内置，在线更新、自定义规则、通用指纹随机化和恶意网站检测尚未接入。
- 第三方 Cookie 限制是 profile 级全局设置，不随单个标签页的盾牌开关独立切换。
- 分屏一次最多显示两个页面，仅支持左右布局；通过工具栏、应用菜单或标签页右键菜单操作，不支持标签拖放分屏。
- v0.5.0 及更早的下载记录没有本地路径，因此升级后不能直接执行“打开文件”或“在 Finder 中显示”。
- 不规划任何 AI 聊天、总结、搜索、推荐或自动操作能力。
