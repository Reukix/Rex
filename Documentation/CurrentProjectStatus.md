# Rex 当前项目状态与问题清单

最后更新：2026-07-30
当前基线：v0.9.7（build 970）
发布通道：本地 Beta

本文用于集中说明 Rex 当前能做什么、工程处于什么阶段、哪些问题仍未解决，以及最近哪些高风险问题已经修复。具体需求、实现细节和历史变化仍分别以 `ProductRequirements.md`、`Architecture.md`、`FEATURES.md`、`ROADMAP.md` 和版本发布说明为准。

## 1. 项目定位与阶段

Rex 是一款面向 macOS 的原生桌面浏览器工程原型，核心方向是垂直标签、工作空间、双页面分屏、默认隐私保护和受管 Chromium 扩展。

当前项目已经具备可运行、可恢复会话、可打包的完整 Beta 主链路，但仍不是正式分发版本。主要原因是 Developer ID 签名、公证、Hardened Runtime、正式自动更新和部分兼容性收敛尚未完成。

当前运行基线：

| 项目 | 当前状态 |
|---|---|
| 系统 | macOS 14 或更高版本 |
| 架构 | 仅 Apple Silicon（arm64） |
| 应用版本 | v0.9.7（build 970） |
| Chromium | 150.0.7871.129 |
| CEF | 150.0.14，官方 standard ARM64 发行包 |
| 产品外壳 | SwiftUI + AppKit |
| 浏览器桥 | Swift `BrowserEngine` + Objective-C++ CEF facade |
| 数据存储 | SQLite，会话、历史、收藏、下载、权限和网站策略 |
| 当前签名 | ad-hoc 深度签名，Hardened Runtime 关闭 |
| 当前产物 | `Dist/Rex.app`（`343M` / `351344 KiB`）、`Dist/Rex-v0.9.7-macos-arm64-chromium.zip`（`142,723,427` bytes，`147740 KiB` / `144M`）；不生成 DMG |
| ZIP SHA-256 | `0940bab0c6541b39b85a26668096dfbd738ae1dc5c62360a8a5a0ab7f45480f3` |

## 2. 技术架构概览

- SwiftUI 负责主要界面和状态呈现，AppKit 负责原生窗口、稳定的 Chromium `NSView` 宿主和扩展浮窗。
- `BrowserStore` 在主线程维护窗口、标签、工作空间、分屏和可见状态。
- `BrowserEngine` 使用类型安全命令和事件连接 Swift 与 Objective-C++；网页不能获得任意原生调用入口。
- CEF/Chromium 负责 Browser、Renderer、GPU、Utility 和扩展运行时等多进程能力，并启用 Chromium sandbox 与 site isolation。
- SQLite 保存普通窗口的会话、历史、收藏、下载、权限和网站策略；隐私窗口使用独立的内存 RequestContext。
- 完整 Chromium 包包含主 App，以及 Main、Alerts、GPU、Plugin、Renderer 五类 Helper。
- Chrome Web Store 包由 Rex 下载、验签、安全解包和管理；扩展的 service worker、content script、消息、存储、DNR 和 options 页面由 Chromium 执行。
- 用户可见的扩展列表、详情、操作和 `rex://extensions` 全部由 Rex SwiftUI/AppKit 呈现；该内部页不会向 Chromium 发起可见导航。
- 扩展安装、同 ID 更新、启停与配置通过不可见、受控的 Chromium 原生扩展 API 上下文执行，集合查询和明确移除通过无 TCP 监听端口的 `--remote-debugging-pipe` 热对账。`chrome://extensions` 不作为用户可见页面。

## 3. 当前功能

### 3.1 浏览器外壳与基础浏览

- CEF 150 多进程 Chromium 页面渲染、基础导航、前进、后退、刷新和停止。
- Rex 保留现有导航栏设计；加载、进度、前进后退和刷新/停止直接读取 Chromium 导航代次与实时状态，重定向后的最终 URL 和完成状态不再由 Rex 猜测。
- 地址栏输入、URL 规范化和 Google、Bing、DuckDuckGo、Brave Search、Ecosia 搜索引擎选择。
- Chrome 风格键盘快捷键、动态网页右键菜单、应用主菜单、页面查找、缩放和打印。
- 网页弹窗转 Rex 标签页、关闭标签恢复、页面标题、favicon、音频状态和静音。
- 原生新标签页，包含搜索、快捷操作、最近访问和收藏网站。
- 深浅色、高对比度和降低透明度的基础适配。

### 3.2 标签、工作空间与会话

- 垂直标签页的新建、选择、关闭、复制、恢复、固定、搜索、静音和数字快捷键直达。
- 工作空间切换、标签分组折叠、跨工作空间移动。
- 自动休眠、后台页面挂起、归档与恢复，并保护当前、固定、播放音频和分屏标签。
- SQLite 会话保存与旧 JSON 数据一次性迁移。
- 多窗口使用独立 UUID 会话，支持标签、分组、选择状态和分屏状态恢复。

### 3.3 双页面分屏

- 同时显示两个页面，当前只支持左右布局。
- 支持 25% 至 75% 比例调整、左右页面交换和焦点同步。
- 可从工具栏、应用菜单或标签右键菜单创建、替换、换侧和退出分屏。
- 支持保存和恢复分屏 URL、导航状态、比例、焦点、静音状态和工作空间组合。

### 3.4 资料库与下载

- 历史记录查询、搜索、单条删除，以及按 1 小时、24 小时、7 天或全部时间清理。
- 收藏添加、搜索和删除。
- 下载进度、失败原因、取消、原任务重试、打开文件、Finder 定位和删除记录。
- 可按工作空间保存下载目录；未配置时使用 CEF 系统保存流程。

### 3.5 隐私、安全与权限

- 隐私盾牌开关和级别按 profile + 精确 hostname 保存，并同步到已打开的同站标签。
- 顶层导航清理已知追踪参数，并在合适条件下尝试从 HTTP 升级到 HTTPS。
- CEF 请求层内置 104 条目录规则：45 条广告、41 条追踪、10 条指纹和 8 条社交规则。
- 标准、严格和自定义保护级别；扩展自己的 DNR 由 Chromium 独立执行。
- 第三方 Cookie 通过 Chromium RequestContext 设置限制；Rex 当前只提供一个应用级共享开关。
- 站点权限支持临时、标签关闭撤销、始终允许、始终阻止和每次询问。
- 站点信息面板可查看证书链、复制 PEM 和管理网站权限。
- 隐私窗口使用独立内存 RequestContext，不恢复或写入普通会话资料。

### 3.6 扩展

- Chrome Web Store 精选目录、官方详情链接或扩展 ID 安装，以及本地 Manifest V2/V3 文件夹导入。
- CRX2/CRX3 来源限制、扩展 ID/签名验证、manifest 公钥身份复核和安全 ZIP 解包。
- 扩展安装、启用、停用、手动更新和移除可在当前进程热生效。
- `rex://extensions` 使用 Rex 自有列表与详情界面；网站访问显示“点击扩展时”“指定网站”“所有网站”三态，并提供 Chromium 报告可用的用户脚本与文件网址开关。
- 配置变更写入 Chromium 后立即读回 `getExtensionInfo`；Rex UI 以返回状态为准，不以本地目标值乐观显示成功。
- 同路径更新使用持久 replacement journal；未确认更新在下次启动恢复旧版本。
- 冷启动即使没有启用扩展也会先对账并清理旧的受管注册，再放行恢复页面的首次导航；已经存在于 Chromium profile 的扩展不得按首次安装重复加载。
- 静态 `default_popup` 在独立 AppKit 浮窗中运行；options 等包内页面以 `rex-extension://` 对外显示。
- 普通非隐私 HTTP(S) 页面使用 Chrome runtime，内容脚本与 service worker 因而获得 Chromium 真实 tab/window/frame/document identity。
- 静态 popup 使用 `CefBrowser::GetIdentifier()` 精确定位来源标签并保留真实 `tab.id/windowId`；这仍不等于授予完整 `activeTab`。
- 已验证 MV3 service worker、静态声明的 content script/host permission、runtime messaging、`chrome.storage.local`、静态 Chromium DNR、options、静态 popup 和热生命周期主链路；未覆盖能力不能由该结果外推。

### 3.7 扩展兼容性事实矩阵（2026-07-30）

状态定义：**已验证**表示当前固定夹具或既有发布记录有可重复证据；**部分支持**表示仅子集成立；**未通过**表示当前用户场景已复现失败；**未验证**表示没有足够证据；**受限**表示产品或平台边界明确不提供。API 探针通过不代表某个商店扩展的全部功能通过。

| 能力 | 当前状态 | 证据与准确边界 | build 970 门禁 |
|---|---|---|---|
| CRX2/CRX3、本地包、身份与安全解包 | 已验证 | Swift 测试覆盖来源、签名/ID、路径和事务；商店在线下载仍需单独网络集成测试 | 保持现有回归全绿 |
| Manifest V2 执行 | 未验证 | 管理器可以校验/导入 MV2 manifest，但当前黑盒运行时夹具只有 MV3 | 增加 MV2 代表样本，或在 UI 中明确只保证已测 MV3 子集 |
| 安装、启停、更新、移除与冷启动 generation | 已验证 | 既有单元测试和 MV3 热生命周期探针覆盖主链路 | 增加失败、超时、多窗口和损坏包矩阵 |
| MV3 service worker | 已验证 | `mv3-runtime-probe` 覆盖 worker 启动、消息应答和版本切换 | 固定 CEF/夹具版本并保存结果 |
| 静态 content script + manifest host permission | 部分支持 | 仅在固定 loopback HTTP 测试页验证静态声明注入；未证明可选 host permission、运行时切换或任意网站均可用 | 增加授权、撤销、重载和跨来源测试 |
| runtime messaging | 已验证 | 内容脚本、popup/options 与 service worker 的夹具消息链路通过 | 增加真实 tab 定向消息失败/成功语义 |
| `chrome.storage.local` | 已验证 | worker、content script 和扩展页面读写通过 | 增加升级与禁用/启用持久化回归 |
| 静态 `declarativeNetRequest` | 已验证 | 固定规则集在首次文档和热生命周期中由 Chromium 执行 | 不外推到动态/会话规则或全部 DNR API |
| options 与包内页面 | 已验证 | options 与 `rex-extension://` 路由已有夹具；`tabs.create` 可转交 URL，但临时返回 ID 不保证后续可用 | 继续验证恢复、关闭和来源路由 |
| Rex `rex://extensions` 管理界面 | 测试中 | 可见列表与详情由 SwiftUI/AppKit 呈现；`chrome://extensions` 只保留为不可见 API 上下文 | 列表、详情、返回、安装、启停、移除和选项入口通过，且不触发引擎可见导航 |
| 网站访问三态、用户脚本与文件网址 | 测试中 | 模型和桥接支持 Chromium 配置写入后立即读回；UI 必须显示读回状态 | 三态及两个开关覆盖成功、失败、陈旧返回与重试；Tampermonkey 最小脚本通过 |
| 静态 `default_popup` | 部分支持 | Rex 在 AppKit 浮窗直接加载声明资源；不是 Chromium 原生 action popup | 坐标、焦点、关闭和多窗口实机回归 |
| `tabs.query(active/currentWindow)` | 部分支持 | 静态 popup 以 CEF 真实 `tabId` 精确匹配，并通过 Chromium `tabs.get` 取得权限裁剪后的 Tab；Rex 不注入 URL/标题，也不授予 `activeTab` | 最终 GUI 复验 callback/Promise、无 host permission、关闭来源和多窗口 |
| `activeTab`、`tabs.sendMessage`、`webNavigation` frame、`scripting`、`userScripts` 与运行时站点访问 | 部分支持 | 真实 sender tab/frame 与定向 `tabs.sendMessage` 已加入探针；Tampermonkey 权限和 worker 已确认，但最小用户脚本注入/撤销/重启尚未实测 | 作为当前最高优先级，真实网页授权/撤销、frame 和注入必须通过 |
| `chrome.tabs.create` 返回身份 | 受限 | URL 可转交并创建 Rex 标签；原临时 WebContents 被关闭，返回 `tab.id` 不承诺可继续用于 `get/update/sendMessage` | 后续仅以完整原 WebContents 接管方案重新评估，不模拟 ID |
| 无静态 popup 的 `action.onClicked`、动态 `action.setPopup` | 受限 | Rex 小型面板不触发 Chromium 原生 action 分发 | 有时限验证；不可可靠实现时在 UI/发布说明中固定限制 |
| native messaging | 未通过 | Rex 源码和现有探针没有可声明为通过的 native host 链路 | 建通用测试 host；未通过前不得标记兼容 |
| 其他 Chrome API/表面 | 未验证 | `bookmarks`、`history`、`downloads`、`cookies`、`webRequest`、`contextMenus`、`commands`、`notifications`、`identity`、DevTools、side panel、offscreen document、theme 等没有系统探针 | 按用户价值选代表样本逐项加入，不做默认兼容假设 |
| 隐私窗口扩展 | 受限 | 产品当前明确不在隐私 RequestContext 中运行扩展 | 保持用户可见说明与排除回归 |

真实扩展样本不能替代 API 级证据：MV3 自测夹具的已覆盖项为**已验证**；uBlock Origin Lite 仅有静态 DNR/popup 子集记录，视为**部分支持**；Tampermonkey 的权限配置和 worker 已确认，但用户脚本端到端仍是**部分支持、待实测**；iCloud Passwords 的包、`nativeMessaging` 权限和全站 host permission 已加载，但系统 `com.apple.passwordmanager` manifest 只注册在 Chrome 专用目录，Apple helper 的 Parent Launch Constraints 又要求获批的 `com.apple.developer.web-browser.public-key-credential` managed entitlement，或名单内的 Bundle ID + Team ID，当前 ad-hoc Rex 均不满足，因此整体视为**受限**。其他内容增强、生产力、开发工具、主题或界面类扩展在完成带版本和包哈希的实测前均为**未验证**。

### 3.8 性能与开发工具

- 标题栏显示 Rex 进程树总内存和 CPU，详情页展示标签关联的 CEF 任务快照。
- 后台标签休眠、挂起和归档策略，以及最多 128 项的有界 favicon 缓存。
- Thorium 风格 GPU、网络、raster 和进程参数层。
- 使用 CEF 150 内置的同版本 Chromium DevTools，提供 Elements、Console、Sources、Network、Performance、Memory、Application、Security 和 Settings。

## 4. 当前验证状态

v0.9.7 build 970 已完成本地 Beta 的构建、管理界面与产物门禁：

- Swift Testing `157/157`、Release Notes Validator（28 个功能 ID）、CEF bridge arm64 Release、完整 Xcode Release、MV3 verifier 语法与自测均通过。
- 打包后的 Rex 已实机打开 `rex://extensions` 发现页、已安装页、Tampermonkey 详情和 options；详情准确显示 Chromium 已启用、所有网站、允许运行用户脚本和允许访问文件网址，options 通过 `rex-extension://` 正常加载。
- 网站访问三态、用户脚本与文件网址配置均走 Chromium 写入后读回；成功读取、成功写入和权威返回值不同于请求值已有回归。失败、超时、跨窗口刷新与真实脚本注入仍需补齐，不从现有配置状态外推。
- 持久扩展安装记录与连续冷启动回归拒绝重复 `runtime.onInstalled`、onboarding 和安装成功页，并保持 storage identity。
- 停用扩展重新启用时由 Chromium 显式 reload，原生操作、最终注册状态和事务指纹快照必须同时有效；启动屏障释放后仍按标签屏蔽临时 `about:blank`，直到真实恢复地址提交。
- 主网页 surface 不再把 Chromium 地址事件回写为 `loadURL`，链接、重定向与站内导航不会触发同地址二次 reload；尚未挂载 NSView 的已配置标签会保留显式导航命令，新主框架请求也不再依赖 loading 边沿分配代次。
- 最终 App/ZIP 的 `0.9.7 / 970`、全部 11 个 Mach-O 的 arm64、ad-hoc deep/strict codesign、ZIP 解压、载荷一致性和 SHA-256 均通过；Dist 与 ZIP 内 DMG 数量均为零。

Tampermonkey 的 Chromium 权限配置和 worker 已确认，但真实用户脚本在普通站点的最小注入、撤销和重启仍需作为独立兼容性用例继续实测，不能由配置状态外推。

v0.9.6 build 962 的历史产物与验收数据保留在 [v0.9.6 发布说明](Releases/v0.9.6.md)，不得复制为 build 970 的结果。当前 ad-hoc 基线仍不是 Developer ID 正式分发候选，`spctl --assess`、公证、更新与回退尚未完成。

## 5. 当前问题与限制

优先级含义：P0 阻断正式发布或可能拖死主浏览流程；P1 是重要安全、兼容性或高频体验缺口；P2 是范围限制、可观测性或后续增强。

### 5.1 P0：扩展兼容性与发布主链路

1. **Tampermonkey 最小用户脚本仍待端到端实测。** 普通非隐私 HTTP(S) 页已使用 Chrome runtime，管理页也已确认 Chromium 返回“所有网站 + 允许用户脚本”；仍需用最小脚本分别验证注入、撤销和重启，不能由配置状态外推页面执行结果。
2. **扩展兼容矩阵仍不完整。** `rex://extensions` 路由、三态网站访问、用户脚本和文件网址已有成功写入与权威返回差异回归；失败、重试、完整 `activeTab`、action、native messaging 与大量 Chrome API 仍需按版本化真实样本逐项验证。
3. **iCloud Passwords 受 Apple 签名能力阻塞。** 系统 native host manifest 只注册在 Chrome 专用目录；即使把原始 manifest 安装到 Rex profile，Apple helper 的 Parent Launch Constraints 仍要求获批的 `com.apple.developer.web-browser.public-key-credential` managed entitlement，或明确列入的 Bundle ID + Team ID，`com.rex.browser` 不在名单中。通用探针已覆盖真实 `sender.tab`、frame 和 `tabs.sendMessage`，但这不能替代 iCloud 原始 helper 的端到端结果。本地 ZIP 只能准确报告受限，不能宣称已生效；“扩展包已加载”也必须与“native host 可用”分开显示。
4. **扩展启动仍是高风险回归面。** build 970 已复用 Chromium profile 的持久安装记录，连续重启回归会拒绝 `runtime.onInstalled`、onboarding 和重复安装成功页，并核对 storage UUID 不变；临时 `about:blank` 不再覆盖恢复 URL。冷启动屏障、补偿 generation、窗口恢复和扩展损坏仍需持续纳入故障注入与实机回归。
5. **正式签名和公证未完成。** 当前包只做 ad-hoc 深度签名，并为本地 CEF 包关闭 Hardened Runtime，`spctl` 会拒绝它。正式外部分发需要用同一 Developer ID 团队签名主 App、CEF 和所有嵌套 Helper，重新启用 Hardened Runtime，并通过 Apple 公证与 Gatekeeper 验证。
6. **正式自动更新链路未完成。** 尚未完成更新签名、差分/完整包下载、失败回退、跨版本迁移和更新演练。
7. **发布覆盖范围有限。** 完整 CEF/Xcode、多窗口、签名和 UI 实机验证依赖 Apple Silicon macOS；Intel 不支持，也不进入测试矩阵。
8. **Mac App Store 分发路径未验证。** 当前启用的是 Chromium 进程沙箱，并未启用 Mac App Store App Sandbox；可执行扩展代码、CEF 打包和商店政策兼容性仍需单独评估，现阶段以 Developer ID 分发为主计划。

### 5.2 P1：扩展兼容性与生命周期

1. **不是完整 Chrome 扩展宿主。** Rex 小型面板不是 Chromium 原生 action popup；完整 `activeTab` 权限授予、没有静态 popup 时的 `action.onClicked` 和运行时 `action.setPopup` 尚不可用。`tabs.create` 仅保证 URL 转交，临时返回 ID 不保证后续可用。
2. **不承诺全商店兼容。** 核心 MV3 探针通过只证明已覆盖的 service worker、content script、消息、存储、DNR、options 和静态 popup 链路可用，不代表所有 Chrome Web Store 扩展或全部 Chrome API 可用。
3. **商店扩展不会自动检查更新。** 当前需使用相同官方链接或扩展 ID 手动重新安装新版。
4. **旧 worker 有短暂初始化窗口。** Chromium profile 中已经持久化的旧 extension worker 可能在 Rex 清理当前 generation 前短暂启动；恢复的 HTTP(S) 首次导航会等待对账结果，但仍需缩小旧 worker 的启动窗口。
5. **同路径更新不是完整两阶段切换。** 目前有 replacement journal 和崩溃恢复，但尚未做到等待旧扩展明确 unload ack 后再替换目录。
6. **失败放行以扩展一致性换取浏览可用性。** 启动对账失败且没有后续补偿 generation 时，Rex 会报告扩展错误并放行 pending URL；这避免浏览器永久停在 `about:blank`，但该首次文档不能保证 content script 或 DNR 已经生效。
7. **隐私窗口不运行扩展。** 热变更只重载活跃普通 HTTP(S) 页面；休眠页在恢复时重载，隐私窗口被排除。这是当前产品边界。
8. **native messaging 未形成通用兼容链路。** 现有源码和探针不能证明 `connectNative`/`sendNativeMessage` 可用；通用能力当前记为未通过。iCloud Passwords 还要求 Apple managed entitlement 或被 helper 明确列入的正式签名身份，当前记为受限；不得复制/重签 Apple helper 或伪装浏览器身份绕过。

### 5.3 P1：隐私与安全

1. **隐私目录是内置快照。** 没有签名在线更新、自定义规则或订阅，也不执行 EasyList 语法和元素隐藏。
2. **没有恶意网站和下载信誉检测。** Safe Browsing、危险文件提示、通用下载内容扫描、签名和 MIME 一致性校验尚未实现。
3. **指纹保护覆盖有限。** 当前只拦截目录中已知指纹服务的网络请求，不随机化 Canvas、WebGL、Audio 等浏览器指纹。
4. **站点归属判断不完整。** 网站策略按精确 hostname 保存；第一方判断只使用有限 registrable-domain 启发式和少量二级后缀，不是完整 PSL/eTLD+1，因此子域不会自动归并。
5. **第三方 Cookie 是应用级共享设置。** Chromium 在各 RequestContext 内应用该设置，但 Rex 的同一个开关会同步写入普通及隐私 contexts；它不能按网站、标签、工作空间或某个隐私窗口独立配置，盾牌统计也通常不会反映 Cookie 阻止数量。
6. **隐私统计不是单次页面统计。** 拦截计数随标签会话累计，主导航后不会自动清零。
7. **隐私窗口不是匿名网络。** 独立 RequestContext 只隔离本地会话数据，不能向 ISP、组织网络管理员或访问的网站隐藏活动。
8. **普通工作空间不是独立 Cookie 容器。** 工作空间用于组织标签和会话，但共享普通 profile 的 Cookie；只有隐私窗口使用独立内存 RequestContext。
9. **隐私窗口下载仍会留下本地文件。** 下载记录不写入普通 SQLite 资料库，但用户选择保存的文件仍会落到磁盘。

### 5.4 P1：基础浏览与下载体验

1. **原生文件选择、JavaScript 对话框和全屏体验仍需完善。** 这些能力尚未达到稳定版验收标准。
2. **页面安全状态和 Renderer 崩溃恢复界面未收敛。** 底层已有事件和恢复能力，但面向用户的完整错误与恢复流程仍在计划中。
3. **下载安全和整理能力不足。** 缺少危险文件提示、校验策略和批量清理；v0.5.0 及更早记录没有本地路径，升级后不能直接打开文件或在 Finder 中显示。
4. **新标签页收藏与资料库收藏相互独立。** 两套数据目前不会自动同步。
5. **不能设置为系统默认浏览器。** 当前设置中心只管理 Rex 内部偏好，不会修改 macOS 默认浏览器。

### 5.5 P2：窗口、标签与分屏

1. **窗口几何和显示器位置不持久化。** 多窗口会话可以恢复内容，但不能精确回到原大小和原显示器位置。
2. **分屏只支持两个页面和左右方向。** 不支持上下布局、多页平铺或标签拖放创建分屏。
3. **分屏标签操作受限。** 分屏中的标签不能直接移动、归档或休眠，需要先退出分屏。
4. **保存组合有失效条件。** 组合引用的页面被关闭、归档或移动后，原组合可能无法恢复。

### 5.6 P2：性能、开发工具与可观测性

1. **网页性能快照不能直接求和。** 多个网页任务共享 renderer 时，任务快照整体不具备可加性，尤其可能重复显示同一进程的 CPU；GPU、Utility、service worker 和其他 worker 只计入 Rex 总量，不分摊到网页。
2. **性能历史不持久化。** 当前只提供实时快照，缺少启动耗时、崩溃率、恢复成功率和长期资源趋势诊断。
3. **DevTools 只提供右侧停靠。** 左侧、底部和独立窗口模式仍未实现。
4. **完整 Thorium/brave-core 融合未进行。** 当前是基于固定 CEF 的可审计参数和隐私功能层，不是自建 Chromium/CEF 发行版。
5. **CEF 分发风险待评估。** 二进制体积、编解码器专利、Widevine 以及 Mac App Store App Sandbox/可执行代码政策都需要单独验证。

### 5.7 文档一致性问题

- **最终产物数据已经回填。** build 970 的 App/ZIP 尺寸、SHA-256 和包清单来自本轮最终打包；完整数据见本文第 1 节与 [v0.9.7 发布说明](Releases/v0.9.7.md)，旧版数字仍只作为历史记录保留。
- **扩展兼容范围必须持续逐项记账。** Rex 管理 UI 和 Chromium 配置读回通过不代表完整 `activeTab`、action、native messaging、全部 Chrome API 或任意商店扩展兼容。
- **安全性能文档领先于实现。** `Documentation/SecurityPrivacyPerformance.md` 写有内存压力分级释放、favicon/快照有界缓存和低电量模式；当前源码只确认定时自动休眠、页面挂起和 128 项 favicon 缓存，未确认内存压力监听、网页快照缓存或低电量状态监听。

## 6. 当前基线已修复、需要防回归的问题

以下问题已经修复，不应继续列为当前缺陷，但必须保留回归测试：

1. **扩展启动对账失败永久卡 `about:blank`。** 现在仍报告并保留扩展错误，但当没有后续补偿事务时会释放等待中的网页导航，扩展故障不再拖死整个浏览器。
2. **网页暴露自动化指纹导致反自动化白屏。** 内部 DevTools pipe 不再使页面暴露 `navigator.webdriver=true`，User-Agent 恢复标准 Chrome 版本段。
3. **强制绕过系统代理。** CEF 不再追加 `--no-proxy-server`，恢复遵循 macOS 系统代理。
4. **首次 `loadURL` 导航竞态。** 地址提交会等待页面创建和站点隐私策略准备完成，首次导航不再被静默丢弃。
5. **CEF RemoteView 上的 SwiftUI Popover 崩溃。** 扩展列表和 popup 改为独立 AppKit 浮窗，移除了 `.popover` / `NSWindow.addChildWindow` 的高风险路径。
6. **静态 popup 缺失真实来源身份。** `chrome.tabs.query` 的 currentWindow/lastFocusedWindow 现在按 CEF 真实 `tabId` 精确选择来源 HTTP(S) 标签，并由 Chromium `tabs.get` 返回权限裁剪后的字段；重复 URL/标题不再误选，Rex 也不注入敏感字段。
7. **原生扩展页坐标耦合。** `rex://extensions` 现由 Rex SwiftUI/AppKit 呈现，不再把用户交互绑定到 Chromium 子窗口坐标；`chrome://extensions` 只保留为不可见 API 上下文。
8. **扩展热生命周期与更新回滚竞态（v0.9.4）。** generation 串行、状态按命令 completion 提交，同路径更新由磁盘 journal 保护并可在启动时回滚。

## 7. 建议后续顺序

详细里程碑、依赖和 v1.0 发布门禁见 [v1.0 未来实施计划](FuturePlan.md)；从当前 v0.9.7 本地 Beta 到 v1.0.0 的逐版工作包和退出条件见 [逐版本工作计划](VersionPlan.md)。

### P0：当前扩展兼容性与发布门槛

- 先完成 Rex `rex://extensions` 列表/详情路由与 Chromium 配置权威读回回归，覆盖网站访问三态、用户脚本、文件网址、失败和重试；同时确认 `chrome://extensions` 始终不可见。
- 以 Tampermonkey 为真实样本，补齐 host permission、`activeTab`、`tabs.sendMessage`、`webNavigation.getAllFrames`、`scripting`/`userScripts` 的授权、撤销和注入探针；不能用 URL/标题合成上下文代替真实权限。
- 对 native messaging 建立通用测试 host；仅在 Rex 获得 Apple entitlement 或被 helper 的签名名单接纳后安装经签名校验的系统 manifest，不复制 helper。iCloud Passwords 只有原始 helper 与正式签名 Rex 端到端通过时才能标记支持，否则维持平台受限结论。
- 完成 Developer ID 全嵌套签名、Hardened Runtime、公证和 Gatekeeper 实机验证。
- 完成正式更新链路、更新签名、迁移与失败回退演练。
- 固化扩展同步失败、连续 generation 失败、多窗口恢复和损坏扩展的导航屏障回归套件。

### P1：安全与兼容性

- 在已建立的扩展能力矩阵上扩大扩展类别样本，并加入商店自动更新。
- 接入签名隐私目录更新、完整 PSL/eTLD+1、危险下载提示和恶意网站检测。
- 收敛原生文件选择、JavaScript 对话框、全屏、页面崩溃和安全状态体验。

### P2：体验与诊断

- 持久化窗口尺寸和显示器位置。
- 评估拖放分屏和保存组合的失效恢复。
- 改进共享 renderer、GPU 和 worker 的性能归因，并提供用户主动触发、可预览的诊断导出。

## 8. 明确不在当前规划中的能力

- Intel Mac 支持。
- Google 账号同步。
- Rex 自有的系统密码/Keychain 集成；第三方扩展的 native messaging 兼容性仍按上面的矩阵单独验证。
- AI 聊天、总结、搜索、推荐或自动操作。

Rex 主程序不实现系统密码调用；上游 CEF 自身仍可能链接 `AuthenticationServices`，不能把 bundle 级依赖误解为 Rex 密码功能。iCloud Passwords 扩展也不会因此自动可用，它还依赖 Rex profile 中的系统 native host manifest，以及满足 Apple helper Parent Launch Constraints 的 entitlement 或正式签名身份。

## 9. 相关文档

- [v0.9.7 至 v1.0.0 逐版本工作计划](VersionPlan.md)
- [v1.0 未来实施计划](FuturePlan.md)
- [产品需求基线](ProductRequirements.md)
- [技术架构](Architecture.md)
- [安全、隐私与性能](SecurityPrivacyPerformance.md)
- [测试与交付计划](DeliveryPlan.md)
- [v0.9.7 发布说明](Releases/v0.9.7.md)
- [v0.9.6 历史发布说明](Releases/v0.9.6.md)
- [功能状态](../FEATURES.md)
- [路线图](../ROADMAP.md)
