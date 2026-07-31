# Rex

Rex 是一款面向 macOS 的原生桌面浏览器设计与工程原型，围绕垂直标签页、工作空间、双页面分屏和默认隐私保护展开。

当前版本为 **v0.9.8 build 983 Beta**。Rex 的 SwiftUI/AppKit 层拥有用户能看到的浏览器外壳、导航、标签、右侧下载模块和 `rex://extensions` 扩展管理界面；CEF/Chromium 是网页、导航、下载、扩展执行、权限和配置的权威后端。下载请求、重定向、传输、落盘与生命周期全部由 Chromium 处理，Rex 只映射其 URL、原始 URL、文件名、MIME、字节数、进度百分比、路径、状态和终态；Rex 不预先推断生命周期。Chromium 原生保存/下载浮层和开始动画保持关闭，文件默认保存到 `~/Downloads/Rex`，新下载开始时自动弹出独立的 Rex 下载浮层。下载、隐私、站点信息和扩展工具栏浮层均使用独立 AppKit `NSPanel`，不附着到 CEF 子窗口。Swift Package 保留预览构建，真实 Chromium 构建使用生成的 Xcode 工程。

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
REX_PACKAGE_SIGNING_MODE=apple-development \
REX_APPLE_DEVELOPMENT_IDENTITY='Apple Development: name@example.com (XXXXXXXXXX)' \
REX_APPLE_DEVELOPMENT_TEAM_ID=XXXXXXXXXX \
Scripts/package-chromium-app.sh 0.9.8 983 Release
# 产物：Dist/Rex.app 与 Dist/Rex-v0.9.8-macos-arm64-chromium.zip
```

build 983 的本地 Beta 包已经生成：`Dist/Rex.app`（344M）与
`Dist/Rex-v0.9.8-macos-arm64-chromium.zip`（143,035,796 bytes / 144M），ZIP
SHA-256 为 `d1c58812160421f80a4b35c24d81b128550afb4211866b9817e5df4dfeecff78`。
该包的主程序、CEF、Helper 和 CEF 动态库全部使用同一台机器的个人团队 Apple
Development 证书签名，Hardened Runtime 关闭。它仍只用于本地测试，不能替代
Developer ID、公证、Gatekeeper、应用自动替换和失败回退门禁。

自动化 QA 不得直接运行上述 App，也不得使用 `open`。唯一支持的烟测入口会为
Rex 创建隔离的临时用户目录，以 CEF 的 `--use-mock-keychain` 测试参数避免访问登录
Keychain，并验证真实配置未被修改：

```bash
Scripts/run-isolated-rex-smoke.sh
```

事件记录与恢复边界见 [QA 配置隔离说明](Documentation/QAProfileSafety.md)。Chromium 下载 GUI
矩阵使用 `Scripts/run-isolated-download-matrix.sh /absolute/path/to/Rex.app`，执行与证据要求见
[Chromium GUI 下载实机矩阵](Documentation/DownloadMatrix.md)。

CEF 固定为 `150.0.14` 官方标准发行包，对应 Chromium `150.0.7871.129`。`Vendor/CEF` 和下载归档不进入版本控制，可随时根据锁文件重建。

## 文档入口

- [当前项目状态与问题清单](Documentation/CurrentProjectStatus.md)
- [v1.0 未来实施计划](Documentation/FuturePlan.md)
- [v0.9.7 发布说明](Documentation/Releases/v0.9.7.md)
- [v0.9.8 发布说明](Documentation/Releases/v0.9.8.md)
- [v0.9.7 至 v1.0.0 逐版本工作计划](Documentation/VersionPlan.md)
- [产品需求基线](Documentation/ProductRequirements.md)
- [交互与信息架构](Documentation/InteractionDesign.md)
- [技术架构](Documentation/Architecture.md)
- [安全、隐私与性能](Documentation/SecurityPrivacyPerformance.md)
- [测试与交付计划](Documentation/DeliveryPlan.md)
- [QA 配置隔离与真实配置保护](Documentation/QAProfileSafety.md)
- [功能状态](FEATURES.md)
- [路线图](ROADMAP.md)

## 当前边界

- v0.9.7 的 `rex://extensions` 完全由 Rex SwiftUI/AppKit 呈现，不向 Chromium 发起可见页面导航；旧 `chrome://extensions` 地址会迁移到该 Rex 页面。Chromium 继续拥有网页、扩展运行时以及权限和配置的真实状态。当前发布边界见[发布说明](Documentation/Releases/v0.9.7.md)。
- 网站访问使用 Chromium 的“点击扩展时”“指定网站”“所有网站”三态；“指定网站”可在 Rex 中增删全站型扩展的授权网站，也可逐项切换扩展已请求的网站。“允许运行用户脚本”和“允许访问文件网址”同样直接写入 Chromium。每次写入后立即调用 Chromium 读回；失败时再读取一次权威状态并保留错误，UI 不以 Rex 本地目标值假定成功。
- 同路径扩展更新以磁盘 journal 保护未确认换盘；强制终止后会在下次启动恢复上一版本。冷启动恢复必须复用 Chromium profile 的持久安装记录，不得把已安装扩展重新提交为首次安装，也不得重复触发 `runtime.onInstalled` 或 onboarding 页面。
- 仓库默认使用 ad-hoc 深度签名；开发者可在 Git 忽略的 `Configuration/RexSigning.local.xcconfig` 中映射稳定的本地代码签名身份和 Team ID。个人团队或自签身份仍只属于本地开发。正式分发模式和 `verify-distribution-gates.sh` 会拒绝这些身份，只接受同一 Developer ID 团队、Hardened Runtime、公证票据、Gatekeeper、独立签名更新清单和精确回退包。
- 精选域名目录与 Mozilla PSL `2026-07-25` 都保留可审计 bundle 基线，并可由同一个 Ed25519 签名安全资源包在线更新。更新实施了 HTTPS 同源限制、大小/哈希/格式校验、原子安装、单调序列、候选启动验证、last-known-good、失败回退、吊销和 kill switch；没有映射生产端点与公钥时默认禁用联网并继续使用 bundle。
- 安全资源端点/公钥与应用更新端点/公钥使用不同 build setting 和 trust domain；配置、状态机与外部输入见[安全资源在线更新](Documentation/SecurityAssetUpdates.md)。自定义规则、通用指纹随机化和恶意网站检测仍未接入。
- 第三方 Cookie 限制是应用级共享 Chromium 设置，不随单个标签页或网站的盾牌开关独立切换。
- Rex 当前明确不提供恶意网站检测、Safe Browsing 或自建危险下载判定，也不会为这些能力把访问网址发送给第三方。
- 分屏一次最多显示两个页面，仅支持左右布局；通过工具栏、应用菜单或标签页右键菜单操作，不支持标签拖放分屏。
- v0.5.0 及更早的下载记录没有本地路径，因此升级后不能直接执行“打开文件”或“在 Finder 中显示”。
- Rex 提供全部可见浏览器外壳、扩展列表、详情和小型面板，不显示 Chrome 自己的标签栏、地址栏或扩展管理页。小型面板直接加载清单声明的静态 `default_popup`，options 等资源也来自安装包；它们内部仍在 `chrome-extension://` 安全源中执行，对外统一显示为 `rex-extension://`。
- Rex 小型面板不是 Chromium 原生 action popup。v0.9.6 在能匹配 Chromium 来源标签时为静态 `default_popup` 保留真实 `tab.id` 与 `windowId`；这不等同于完整 `activeTab` 权限授予，依赖 `action.onClicked` 的无 popup 按钮和运行时 `action.setPopup` 动态变更仍不支持。
- 扩展安装、同 ID 更新和配置变更通过隐藏、受控的 Chromium 管理 API 上下文执行，启停使用原生 management API，集合查询与真正移除通过内部 `--remote-debugging-pipe` 完成；`chrome://extensions` 永不作为用户可见页面。成功变更后，活跃普通 HTTP(S) 页面立即重载一次，休眠页恢复时重载一次，隐私窗口排除。正常退出会先等待全部活动标准窗口的最新会话快照写入 SQLite，再关闭 Chromium browser 并停止主循环；进程级 `NSApplication.run` hook 在原始 event loop 返回后排空外部消息泵并调用 `CefShutdown()`。单窗口保存失败或 5 秒超时不会永久阻塞退出。Chrome Web Store 尚不自动检查更新，仍需使用相同链接或 ID 手动重新安装新版包。
- 通用 MV3 发布探针要求在不刷新、不重复导航的首次文档上验证 service worker、content script、双向 runtime/tab messaging、真实 tab/frame identity、`chrome.storage.local`、Chromium DNR、options 页面、静态 `default_popup`、来源标签上下文与热生命周期。兼容性仍取决于扩展使用的 API 和当前 Chromium 版本，不承诺任意 Chrome Web Store 扩展或全部 Chrome API 均兼容。
- 普通 Rex UI 回归确认没有网页裁剪、负偏移或 Chrome 窗口覆盖。未托管的 Chrome extension popup/auxiliary window 会把普通网页目标交给 Rex 后关闭。
- Rex 源码和主可执行文件不包含 `SystemPasswordsCoordinator` 或 `AuthenticationServices` 依赖，不提供系统密码调用。打包门槛拒绝主 executable 链接该 framework 或 App 包含 `.systemextension`，`PACKAGE-INFO.txt` 记录 `rex_password_integration=absent`；上游 Chromium Embedded Framework 自身仍链接该系统 framework。
- 不规划任何 AI 聊天、总结、搜索、推荐或自动操作能力。
