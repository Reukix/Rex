# Rex

Rex 是一款面向 macOS 的原生桌面浏览器设计与工程原型，围绕垂直标签页、工作空间、双页面分屏和默认隐私保护展开。

当前版本为 **v0.9.7 build 970 Beta**。Rex 的 SwiftUI/AppKit 层拥有用户能看到的浏览器外壳、导航、标签和 `rex://extensions` 扩展管理界面；CEF/Chromium 是网页、导航状态、扩展执行、权限和配置的权威后端。Rex 负责 Chrome Web Store 包的下载、身份/签名校验、安全解包及管理操作，隐藏的 `chrome://extensions` 仅作为受控 `chrome.developerPrivate` API 上下文，不向用户显示。Swift Package 保留 WebKit 预览构建，真实 Chromium 构建使用生成的 Xcode 工程。

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
Scripts/package-chromium-app.sh 0.9.7 970 Release
# 产物：Dist/Rex.app 与 Dist/Rex-v0.9.7-macos-arm64-chromium.zip
```

build 970 只交付本地 Beta ZIP，不生成 DMG。最终产物为 `Dist/Rex.app`（`343M` / `351344 KiB`）与 `Dist/Rex-v0.9.7-macos-arm64-chromium.zip`（`142,723,427` bytes，`147740 KiB` / `144M`），ZIP SHA-256 为 `0940bab0c6541b39b85a26668096dfbd738ae1dc5c62360a8a5a0ab7f45480f3`；详细清单见 `Dist/PACKAGE-INFO.txt` 与 `Dist/SHA256SUMS`。当前包仍使用 ad-hoc 签名、未启用 Hardened Runtime 且未公证，不是正式分发候选。

CEF 固定为 `150.0.14` 官方标准发行包，对应 Chromium `150.0.7871.129`。`Vendor/CEF` 和下载归档不进入版本控制，可随时根据锁文件重建。

## 文档入口

- [当前项目状态与问题清单](Documentation/CurrentProjectStatus.md)
- [v1.0 未来实施计划](Documentation/FuturePlan.md)
- [v0.9.7 发布说明](Documentation/Releases/v0.9.7.md)
- [v0.9.7 至 v1.0.0 逐版本工作计划](Documentation/VersionPlan.md)
- [产品需求基线](Documentation/ProductRequirements.md)
- [交互与信息架构](Documentation/InteractionDesign.md)
- [技术架构](Documentation/Architecture.md)
- [安全、隐私与性能](Documentation/SecurityPrivacyPerformance.md)
- [测试与交付计划](Documentation/DeliveryPlan.md)
- [功能状态](FEATURES.md)
- [路线图](ROADMAP.md)

## 当前边界

- v0.9.7 的 `rex://extensions` 完全由 Rex SwiftUI/AppKit 呈现，不向 Chromium 发起可见页面导航；旧 `chrome://extensions` 地址会迁移到该 Rex 页面。Chromium 继续拥有网页、扩展运行时以及权限和配置的真实状态。当前发布边界见[发布说明](Documentation/Releases/v0.9.7.md)。
- 网站访问使用 Chromium 的“点击扩展时”“指定网站”“所有网站”三态；“指定网站”可在 Rex 中增删全站型扩展的授权网站，也可逐项切换扩展已请求的网站。“允许运行用户脚本”和“允许访问文件网址”同样直接写入 Chromium。每次写入后立即调用 Chromium 读回；失败时再读取一次权威状态并保留错误，UI 不以 Rex 本地目标值假定成功。
- 同路径扩展更新以磁盘 journal 保护未确认换盘；强制终止后会在下次启动恢复上一版本。冷启动恢复必须复用 Chromium profile 的持久安装记录，不得把已安装扩展重新提交为首次安装，也不得重复触发 `runtime.onInstalled` 或 onboarding 页面。
- 本地构建目前使用 ad-hoc 深度签名并关闭 Hardened Runtime，以兼容没有 Team ID 的本地 CEF framework。正式分发仍需使用同一 Developer ID 团队签名全部嵌套代码、重新开启 Hardened Runtime 并公证；自动更新尚未完成。
- 精选域名目录随应用内置，在线更新、自定义规则、通用指纹随机化和恶意网站检测尚未接入。
- 第三方 Cookie 限制是 profile 级全局设置，不随单个标签页的盾牌开关独立切换。
- 分屏一次最多显示两个页面，仅支持左右布局；通过工具栏、应用菜单或标签页右键菜单操作，不支持标签拖放分屏。
- v0.5.0 及更早的下载记录没有本地路径，因此升级后不能直接执行“打开文件”或“在 Finder 中显示”。
- Rex 提供全部可见浏览器外壳、扩展列表、详情和小型面板，不显示 Chrome 自己的标签栏、地址栏或扩展管理页。小型面板直接加载清单声明的静态 `default_popup`，options 等资源也来自安装包；它们内部仍在 `chrome-extension://` 安全源中执行，对外统一显示为 `rex-extension://`。
- Rex 小型面板不是 Chromium 原生 action popup。v0.9.6 在能匹配 Chromium 来源标签时为静态 `default_popup` 保留真实 `tab.id` 与 `windowId`；这不等同于完整 `activeTab` 权限授予，依赖 `action.onClicked` 的无 popup 按钮和运行时 `action.setPopup` 动态变更仍不支持。
- 扩展安装、同 ID 更新和配置变更通过隐藏、受控的 Chromium 管理 API 上下文执行，启停使用原生 management API，集合查询与真正移除通过内部 `--remote-debugging-pipe` 完成；`chrome://extensions` 永不作为用户可见页面。成功变更后，活跃普通 HTTP(S) 页面立即重载一次，休眠页恢复时重载一次，隐私窗口排除。正常退出会先等待全部活动标准窗口的最新会话快照写入 SQLite，再关闭 Chromium browser 并让 `NSApplication.run` 返回，最后排空外部消息泵并调用 `CefShutdown()`；单窗口保存失败或 5 秒超时不会永久阻塞退出。Chrome Web Store 尚不自动检查更新，仍需使用相同链接或 ID 手动重新安装新版包。
- 通用 MV3 发布探针要求在不刷新、不重复导航的首次文档上验证 service worker、content script、双向 runtime/tab messaging、真实 tab/frame identity、`chrome.storage.local`、Chromium DNR、options 页面、静态 `default_popup`、来源标签上下文与热生命周期。兼容性仍取决于扩展使用的 API 和当前 Chromium 版本，不承诺任意 Chrome Web Store 扩展或全部 Chrome API 均兼容。
- 普通 Rex UI 回归确认没有网页裁剪、负偏移或 Chrome 窗口覆盖。未托管的 Chrome extension popup/auxiliary window 会把普通网页目标交给 Rex 后关闭。
- Rex 源码和主可执行文件不包含 `SystemPasswordsCoordinator` 或 `AuthenticationServices` 依赖，不提供系统密码调用。打包门槛拒绝主 executable 链接该 framework 或 App 包含 `.systemextension`，`PACKAGE-INFO.txt` 记录 `rex_password_integration=absent`；上游 Chromium Embedded Framework 自身仍链接该系统 framework。
- 不规划任何 AI 聊天、总结、搜索、推荐或自动操作能力。
