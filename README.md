# Rex

Rex 是一款面向 macOS 的原生桌面浏览器设计与工程原型，围绕垂直标签页、工作空间、双页面分屏和默认隐私保护展开。

当前版本为 **v0.9.5**。它在原生 SwiftUI/AppKit 产品外壳和 CEF/Chromium ARM64 后端之上提供 SQLite 会话、垂直标签与工作空间、仅左右双页面分屏、Safari 式按网站隐私盾牌、权限、隐私窗口和下载管理。扩展小型面板获得来源网页的当前标签上下文，工具栏扩展面板改由独立 AppKit 浮窗承载，避免在 CEF 远程视图上叠加 SwiftUI Popover。Rex 负责 Chrome Web Store 包的下载、身份/签名校验、安全解包与管理界面，并通过无监听端口的 `--remote-debugging-pipe` 将扩展安装、启停、更新和移除即时同步到 Chromium。Swift Package 保留 WebKit 预览构建，真实 Chromium 构建使用生成的 Xcode 工程。

隐私盾牌分为三层：Swift 只在顶层导航时清理已知追踪参数并尝试把 HTTP 升级为 HTTPS；CEF 请求层使用内置的 45 个广告、41 个追踪、10 个指纹和 8 个社交目录条目取消命中的子资源请求；第三方 Cookie 则由 CEF profile 的全局 Cookie 设置限制。标准模式拦截第三方广告与追踪目录，并在默认开启的指纹保护下拦截第三方已知指纹服务；严格模式再加入社交目录；自定义模式映射为 CEF aggressive 策略，允许广告/追踪目录匹配第一方请求，并对第三方请求使用路径启发式。扩展声明的 DNR 由 Chromium 扩展运行时独立执行，不并入 Rex 隐私引擎。内置 104 条规则见[隐私盾牌内置请求目录](Documentation/PrivacyDomainCatalog.md)。开发者工具使用 CEF 150 自带的同版本 Chromium DevTools 前端。

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
Scripts/package-chromium-app.sh 0.9.5 950 Release
# 产物：Dist/Rex.app 与 Dist/Rex-v0.9.5-macos-arm64-chromium.zip
```

Release 产物的尺寸、SHA-256、签名和包清单以构建完成后生成的 `Dist/PACKAGE-INFO.txt` 与 `Dist/SHA256SUMS` 为准；打包门槛会核对主 App 与五个 CEF Helper 的版本、构建号和 arm64 架构。

CEF 固定为 `150.0.14` 官方标准发行包，对应 Chromium `150.0.7871.129`。`Vendor/CEF` 和下载归档不进入版本控制，可随时根据锁文件重建。

## 文档入口

- [产品需求基线](Documentation/ProductRequirements.md)
- [交互与信息架构](Documentation/InteractionDesign.md)
- [技术架构](Documentation/Architecture.md)
- [安全、隐私与性能](Documentation/SecurityPrivacyPerformance.md)
- [测试与交付计划](Documentation/DeliveryPlan.md)
- [功能状态](FEATURES.md)
- [路线图](ROADMAP.md)

## 当前边界

- v0.9.5 将隐私盾牌开关与级别保存为 profile 内按网站策略并同步同站标签；扩展小型面板可读取来源网页上下文，修复面板设置无效；工具栏扩展界面不再使用会触发 CEF/AppKit 远程视图崩溃的 SwiftUI Popover。最终 `Dist` 包验证记录见[发布说明](Documentation/Releases/v0.9.5.md)。
- 同路径扩展更新以磁盘 journal 保护未确认换盘；强制终止后会在下次启动恢复上一版本。Chromium profile 中已持久化的旧 worker 仍可能在启动清理 generation 前短暂初始化，但恢复的 HTTP(S) 首次导航会一直被屏障拦住。
- 本地构建目前使用 ad-hoc 深度签名并关闭 Hardened Runtime，以兼容没有 Team ID 的本地 CEF framework。正式分发仍需使用同一 Developer ID 团队签名全部嵌套代码、重新开启 Hardened Runtime 并公证；自动更新尚未完成。
- 精选域名目录随应用内置，在线更新、自定义规则、通用指纹随机化和恶意网站检测尚未接入。
- 第三方 Cookie 限制是 profile 级全局设置，不随单个标签页的盾牌开关独立切换。
- 分屏一次最多显示两个页面，仅支持左右布局；通过工具栏、应用菜单或标签页右键菜单操作，不支持标签拖放分屏。
- v0.5.0 及更早的下载记录没有本地路径，因此升级后不能直接执行“打开文件”或“在 Finder 中显示”。
- Rex 提供浏览器外壳、扩展列表、小型面板与扩展管理界面，不显示 Chrome 自己的标签栏、地址栏或扩展管理页。小型面板直接加载清单声明的静态 `default_popup`，options 等资源也来自安装包；它们内部仍在 `chrome-extension://` 安全源中执行，对外统一显示为 `rex-extension://`。
- Rex 小型面板不是 Chromium 原生 action popup。v0.9.5 为静态 `default_popup` 提供来源网页的 `chrome.tabs.query({active:true,currentWindow:true})` 语义；`activeTab` 权限授予、依赖 `action.onClicked` 的无 popup 按钮和运行时 `action.setPopup` 动态变更仍不支持。
- 扩展安装、启用、停用、手动更新和移除通过内部 `--remote-debugging-pipe` 即时对账，不开放远程调试 TCP 端口；成功变更后，活跃普通 HTTP(S) 页面立即重载一次，休眠页恢复时重载一次，隐私窗口排除。Chrome Web Store 尚不自动检查更新，仍需使用相同链接或 ID 手动重新安装新版包。
- 通用 MV3 发布探针要求在不刷新、不重复导航的首次文档上验证 service worker、content script、runtime messaging、`chrome.storage.local`、Chromium DNR、options 页面、静态 `default_popup`、来源标签上下文与热生命周期。兼容性仍取决于扩展使用的 API、当前 Chromium 版本和 Alloy 宿主能力，不承诺任意 Chrome Web Store 扩展或全部 Chrome API 均兼容。
- 普通 Rex UI 回归确认没有网页裁剪、负偏移或 Chrome 窗口覆盖。未托管的 Chrome extension popup/auxiliary window 会把普通网页目标交给 Rex 后关闭。
- Rex 源码和主可执行文件不包含 `SystemPasswordsCoordinator` 或 `AuthenticationServices` 依赖，不提供系统密码调用。打包门槛拒绝主 executable 链接该 framework 或 App 包含 `.systemextension`，`PACKAGE-INFO.txt` 记录 `rex_password_integration=absent`；上游 Chromium Embedded Framework 自身仍链接该系统 framework。
- 不规划任何 AI 聊天、总结、搜索、推荐或自动操作能力。
