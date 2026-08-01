# 更新日志

## 0.9.8 (build 985) — 2026-08-01

### Chromium 下载与 Rex 状态映射

- Chromium 独占下载请求、重定向、传输、落盘和生命周期，并提供 URL、原始 URL、文件名、MIME、大小、进度、最终路径和中断原因；Rex 只把这些权威事实映射到右侧下载模块和资料库。状态、按钮可用性与终态不再由 Rex 乐观推断：未知 Chromium 状态不可操作，重试也等待 Chromium 的新任务回调后才更新界面。
- Chromium 不显示原生保存或下载浮层，默认直接保存到 `~/Downloads/Rex`；新下载开始时自动弹出 Rex 右侧下载模块，同一任务的后续进度与终态更新不会重复弹出。取消和重试由 Rex UI 发出命令，但实际任务仍由 Chromium callback 执行；Rex 不暂停、恢复或重放传输。
- 修复上次运行遗留的未完成下载快照无法删除的问题：重启恢复时将没有当前 Chromium 活动任务的旧快照映射为 `unknown`，并显示删除记录按钮；资料库新增清空所有非活动下载记录的按钮。清理只删除 Rex SQLite 记录，不删除下载文件，当前活动任务保留。
- 侧栏收藏改为读取独立持久书签，不再依赖仍然打开的标签页；关闭已收藏页面后收藏继续保留，点击可在当前工作空间重新打开。收窄侧栏按收藏、固定和普通标签分区显示，固定标签保持置顶。
- 修复 build 982 在自动弹出下载面板或打开站点信息/隐私盾牌时，SwiftUI `NSPopover` 与 CEF `NSRemoteView` 子窗口同时参与 `addChildWindow` 排序而触发 AppKit `EXC_BREAKPOINT` 的问题。三个工具栏浮层现在与扩展入口共用独立无边框 Rex `NSPanel` 路径，不再附着到 Chromium 子窗口；源码回归门禁禁止 `BrowserRootView` 重新引入 `.popover`。
- 修复 Chrome runtime 在隐藏工具栏锚点上显示下载完成气泡、导致窗口左上角出现第二套下载提示的问题；启动时关闭 `download_bubble.partial_view_enabled`，并通过 CEF command handler 隐藏 Chromium 下载按钮，只保留 Rex 下载浮层。
- 修复 Chromium 150 在隐藏下载按钮后仍显示“下载开始”圆形动画的问题；内置固定 ID 的 MV3 控制扩展调用 `chrome.downloads.setUiOptions({enabled: false})`，并保持普通/隐私窗口的 Chromium 下载传输不变。
- 移除会介入 Chromium 生命周期的危险文件和隐私窗口落盘确认链路。当前版本不提供下载信誉、内容扫描、代码签名判断或 Safe Browsing。
- 修复 GitHub release DMG 点击后在 `Chrome_IOThread` 崩溃：CEF 150 与实验性 `ParallelDownloading` 不兼容，正式 profile 已移除该 feature，并加入禁止重新启用的编译期回归门禁。

### PSL 站点归属与隐私语义

- 固定 Mozilla Public Suffix List `2026-07-25_14-20-03_UTC` 官方快照（SHA-256 `084a5674d77c1d14900b16da5fc8afee9765af2f00a638552a8c7aa18f44ae81`），Swift 站点策略与 CEF 请求分类读取同一份资源。
- 站点归属覆盖 ICANN/private suffix、通配、例外、IDN、localhost 和 IP；旧精确主机策略按 eTLD+1 合并，冲突保留最近修改并在 SQLite 事务内原子替换。
- CEF 侧 PSL 的 Chromium URL/IDN 规范化延后到 `CefInitialize` 成功后、首个消息泵轮次前执行，避免启动期调用未初始化 URL parser 触发崩溃。
- 盾牌明确为“当前标签会话累计”，不再在缺少分类资源时按比例伪造广告、追踪与 Cookie 数量；已知指纹服务单独展示。第三方 Cookie 明确为应用级共享 Chromium 设置，不随网站盾牌开关变化。
- 恶意网站检测边界选择为“当前不提供”：Rex 不为不存在的 Safe Browsing 能力上传访问网址，也不在 UI 中暗示已具备下载信誉或恶意内容检测。

### 签名安全资源与供应链门禁

- 隐私目录从 C++ 硬编码迁移到可审计 `privacy_catalog.json`，并与 PSL 由同一个启动选择交给 Swift 与 CEF。
- 新增 Ed25519 签名 manifest、HTTPS 同源/重定向限制、大小/哈希/格式验证、单调 sequence、同卷原子安装、candidate/LKG、启动失败回退、吊销、降级拒绝、bundle kill switch 和暂停更新控制；未映射生产端点与公钥时默认离线。
- CRX、普通下载、安全资源和应用更新建立四个独立验证边界；应用更新要求独立 trust domain、公钥、向前 build 和当前 build 的精确回退包。
- 新增 Developer ID 正式打包模式与分发门禁，逐项检查嵌套代码的 Developer ID/Team ID/Hardened Runtime、公证票据、Gatekeeper、签名更新清单及更新/回退 ZIP。Apple Development、自签与 ad-hoc 均不能通过正式门禁。
- 新增只允许隔离 `/tmp/rex-qa-smoke.*` profile 与 loopback HTTP 的 Chromium GUI 下载矩阵 harness；纯隔离启动、退出和真实数据指纹检查通过，但五个下载样本没有被触发，交互结果仍待实机。

### 验证

- Swift Testing `186/186`、Release Notes Validator（28 个功能 ID）、MV3 verifier 语法与 `--self-test` 通过；其中 13 项覆盖安全资源与供应链故障注入，工具栏结构测试禁止重新使用 SwiftUI popover，下载记录测试覆盖旧快照与批量删除，新增 1 项覆盖收藏关闭后保留与收窄侧栏固定分区。
- CEF bridge arm64 Release 与完整 Xcode Release 构建通过；App 为 `0.9.8 / 985`，本机 Apple Development 深度签名仅用于开发验证。
- build 985 通过隔离启动/正常退出烟测，全部 Helper 正常退出，真实 Rex 数据指纹未变化；隔离 harness 使用 CEF 官方 macOS 测试参数 `--use-mock-keychain`，不会读取用户登录 Keychain。
- 本地 Beta 产物为 `Dist/Rex.app`（`344M` / `352408 KiB`）与 `Dist/Rex-v0.9.8-macos-arm64-chromium.zip`（`143,061,961` bytes，`148172 KiB` / `145M`），ZIP SHA-256 为 `680079eacab39fe2907132cc91e1eb9c1dff8e9c9fed29adb5c437993cb99651`；11 个 Mach-O 均为 arm64，并使用同一 Apple Development 个人团队 Authority 与 Team ID；deep/strict codesign、ZIP 完整性和 SHA 清单通过。上一 build 983 的隔离 `safe.pdf` 下载矩阵确认 Chromium 开始动画与完成气泡均未显示，Rex 浮层显示 `completed`（33/33 bytes），GitHub release DMG（53,879,378 bytes）也已由 Chromium 完整下载并正常关闭 CEF；build 985 尚未重复这两项 GUI 下载证据。
- 下载矩阵第一次 GUI 尝试曾错误启动真实 profile Rex 和直接启动 build 981，导致 `~/Library/Application Support/Rex/Chromium` 元数据在 `22:39:46-22:42:14 +0800` 变化；进程均已正常退出，没有执行删除或回滚，详细证据与后续禁用 GUI 控制的要求见 `Documentation/QAProfileSafety.md`。
- build 983 隔离矩阵通过后的 Computer Use 验收仍因相同 bundle ID 另行启动了未隔离的 `Dist/Rex.app`；`02:19:05-02:21:25 +0800` 可确认真实 Rex profile 中 68 个文件的元数据发生变化。进程与全部 Helper 已通过 Cocoa 正常退出，没有读取数据库内容、删除或回滚用户数据；此后 Rex 运行态 QA 禁止使用 Computer Use 或 Launch Services，只允许隔离脚本直接启动 executable。

### 当前限制

- 生产安全资源端点、公钥、离线私钥发布流程尚未提供；未配置时继续使用随应用发布的内置目录与 PSL 基线。
- 普通下载完全沿用 Chromium 传输链；Rex 当前不增加危险文件确认，也不提供信誉、内容扫描、代码签名或恶意网站检测。
- v0.9.7 遗留门禁已有严格校验脚本，但当前免费个人团队证书不能获得 Developer ID 或公证；正式更新替换与失败回退演练仍未完成。

## 0.9.7 (build 970) — 2026-07-30

### Rex 外壳与 Chromium 权威后端

- 用户可见的浏览器外壳和扩展管理界面统一由 Rex SwiftUI/AppKit 实现；Chromium 继续负责网页渲染、导航生命周期、扩展执行、权限和配置状态，并作为这些状态的唯一事实来源。
- `rex://extensions` 改为 Rex 自有的发现、已安装和扩展详情页面，不再直接显示 Chromium 原生扩展 WebUI。旧 `chrome://extensions` 路由在应用边界迁移为 `rex://extensions`。
- `chrome://extensions` 只保留为不可见、受控的 `chrome.developerPrivate` API 执行上下文；普通可见 browser client 拒绝全部 `chrome:` 导航，用户不会看到 Chrome 标签栏、地址栏或扩展管理页面。
- Chromium 提交的 URL 只作为 Rex 导航栏的可见状态，不再由 SwiftUI browser surface 回写为第二次 `loadURL`；点击链接、重定向和站内导航不会再被同地址 `Reload` 打断或让导航栏重复刷新。
- 已创建但尚未挂载可见 NSView 的 Chromium 标签会保留显式导航命令，页面出现后按顺序执行，不再依赖 SwiftUI 状态回写补发地址。
- 新主框架请求在 `OnBeforeBrowse` 即获得导航代次，不再依赖 Chromium 聚合 loading 状态从 false 切到 true；前一页仍在加载时提交新地址也能接受真实提交、结束 pending 并恢复刷新按钮。

### 扩展权限配置

- 扩展详情提供“点击扩展时”“指定网站”“所有网站”三态网站访问设置，以及“允许运行用户脚本”和“允许访问文件网址”开关。
- “指定网站”不再只是状态展示：全站型扩展可添加或移除具体网站，有限 host 声明扩展可逐站授权或撤销；操作调用 Chromium 原生 `addHostPermission` / `removeHostPermission`。
- 所有设置均提交给 Chromium 原生扩展管理 API；更新完成后立即读回 Chromium 的实际配置，Rex 不用本地目录或目标值假定设置已经生效。
- Chromium API 不可用、返回数据无效或写入失败时保留明确错误和重试入口，并再次读取 Chromium 权威状态，不把失败状态显示为成功。
- 扩展详情的启用开关和状态优先显示 Chromium 读回值；Rex 本地包状态只在尚未取得 Chromium 配置时作为回退。

### 扩展生命周期与冷启动

- 持久扩展从停用切回启用时，先由 Chromium `management.setEnabled` 启用，再执行 `developerPrivate.reload` 重新读取受管目录；禁用期间替换的同版本 JS/CSS 即使跨 Rex 重启也不会继续运行旧副本。
- 扩展事务只有在原生操作成功、最终 Chromium 注册表验证通过且受管包仍匹配本次事务开始时的指纹快照后才提交。事务期间再次换盘会失败并保留下一代 reload 机会，不会把尚未被 Chromium 消费的版本记为已加载。
- 冷启动导航屏障使用的临时 `about:blank` 会按标签持续标记到真实地址提交；即使屏障已释放，延迟到达的占位地址和标题也不会进入 Rex 可见导航状态或覆盖持久化恢复 URL。
- 正常退出改为先关闭全部 Chromium browser 并停止 `NSApplication` 主循环；进程级 `NSApplication.run` hook 在原始 event loop 返回后、SwiftUI 调用 `exit()` 前排空外部消息泵并调用 `CefShutdown()`，不再从 `applicationWillTerminate` 的 `terminate:` 调用栈内关闭 CEF。
- 关闭 Chromium 前先等待全部活动标准窗口的最新会话快照落入 SQLite，跳过隐私窗口；单窗口失败继续处理其他窗口，整体超过 5 秒则记录日志并继续退出，避免修复 CEF 卡死时引入最后 350ms 标签或布局状态丢失。
- 内部扩展控制 DevTools pipe 会在排空关闭任务前断开，固定 fd 3/4 保留到 `CefShutdown()` 返回后才释放，避免关闭过程中的描述符复用。

### Chromium 导航状态

- 主框架每次非重定向导航开始时建立新的导航代次，服务器重定向继续归入同一代次。即使上一页面仍在加载、Chromium 的聚合加载状态没有再次产生 `loading=true`，新提交地址及其最终重定向仍会被接受并正确结束导航栏加载状态。
- pending 地址会先核对 Chromium 的实际地址变化，再拒绝同代次的旧页面回调；这为仍报告旧代次的边界事件保留收敛路径，不再让地址栏永久显示停止按钮。

### 兼容性边界

- 扩展 popup/options 等包内页面仍在 Chromium 的 `chrome-extension://` 安全源中执行，对外显示为 `rex-extension://`；service worker、content script、DNR、消息与 storage 继续由 Chromium 实现。
- 静态 popup 的 current/lastFocused 标签映射只把 Chromium tab ID 交给 renderer，再调用 Chromium `tabs.get` 取得权限裁剪后的 Tab；Rex 不注入来源 URL 或标题，也不会绕过扩展的 `tabs`/host permission。
- 已覆盖的站点访问、用户脚本和扩展运行时子集不等于所有 Chrome Web Store 扩展或全部 Chrome API 均兼容。完整 `activeTab`、无静态 popup 的 `action.onClicked` 和动态 `action.setPopup` 仍不承诺支持。
- iCloud Passwords 的扩展包可以加载，但 Apple native host 仍受 manifest 注册、正式签名身份和 managed entitlement 限制，不能标记为可用。

### 版本与交付状态

- 版本推进到 `v0.9.7` build `970`；这是 ad-hoc 本地 Beta 基线，不是 Developer ID 正式分发候选。
- Developer ID 同团队签名、Hardened Runtime、公证、Gatekeeper、应用更新和失败回退均仍未完成。
- 产物：`Dist/Rex.app`（`343M` / `351344 KiB`）与 `Dist/Rex-v0.9.7-macos-arm64-chromium.zip`（`142,723,427` bytes，`147740 KiB` / `144M`）；ZIP SHA-256：`0940bab0c6541b39b85a26668096dfbd738ae1dc5c62360a8a5a0ab7f45480f3`。ZIP 解压、`0.9.7 / 970`、全部 11 个 Mach-O 的 arm64、deep/strict codesign 和 SHA 清单均通过；本次未生成 DMG。详情见 [v0.9.7 发布说明](Documentation/Releases/v0.9.7.md)。

## 0.9.6 (build 962) — 2026-07-30

### Chromium 导航状态

- 保持现有 Rex 导航栏设计，但加载、进度、前进后退和刷新/停止命令改为直接读取 Chromium 的实时导航状态；`BrowserTab` 中的加载字段只作为旧会话兼容镜像，不再参与 UI 或命令决策。
- CEF 主框架每次开始加载时分配单调递增的导航代次，并把代次附加到地址、加载、进度、标题和失败事件；Swift 入口在主线程按原始顺序同步消费，旧代次回调不会覆盖新导航。
- 待处理地址不再要求 Chromium 的最终 URL 与提交 URL 完全相等。同一导航代次内的 301/302、HSTS、登录跳转和 URL 规范化会接受 Chromium 最终地址与 `isLoading=false`，修复网页已显示但导航栏永久保持停止按钮和加载动画的问题。
- 会话恢复只保留 URL、标题等恢复目标，启动时清除持久化的 loading、进度、前进后退和导航代次，避免上次运行状态冒充当前 Chromium 状态。

### Chromium 原生扩展管理页

- `rex://extensions` 继续映射 Chromium 原生 `chrome://extensions/`，并保留详情路径与查询参数，不引入 Rex 自制替代页面。
- Chrome runtime 按 Rex 宿主的真实初始尺寸创建完整 `CefWindow`，窗口内使用填充布局；不再从 Chromium 窗口拆出并重挂载 browser view。完整 Chromium 窗口改为 Rex 内容窗口的无边框原生子窗口，并随内容区同步位置与大小，消除 macOS 标题栏非客户区造成的绘制位置与鼠标命中坐标偏移。
- Chromium 子窗口保持 key 状态以接收原生键盘事件；Rex 内容窗口恢复 main-window 身份，使应用菜单、sheet 与工具栏扩展面板继续以 Rex 主窗口为层级基准。

### 当前标签身份与扩展消息

- 普通非隐私 HTTP(S) 页面改由 Chrome runtime 承载，使扩展内容脚本、service worker 与消息 sender 获得 Chromium 真实 tab、window、frame 和 document identity。
- 静态扩展 popup 查询 `{active:true,currentWindow:true}` 或 `{active:true,lastFocusedWindow:true}` 时，使用 CEF 明确定义为扩展 `tabId` 的 `CefBrowser::GetIdentifier()` 精确匹配 Chromium 实际标签；相同 URL/标题不再参与猜测，来源已关闭时返回空数组。
- MV3 探针新增 action popup current/lastFocused 同一 identity 校验，并把其 `id/windowId` 与同一文档的内容脚本 sender 直接比较，同时记录 frame 与 document identity。
- service worker 通过 `chrome.tabs.sendMessage(tabId, ..., {frameId})` 回传到来源内容脚本，补齐此前只有 content script 到 worker 的单向消息覆盖。
- popup 通知 background worker 后，再执行 Tampermonkey 同款 `{active:true,lastFocusedWindow:true}` 查询；探针要求 worker、popup 和内容脚本 sender 的 `tab.id/windowId` 完全一致。

### 扩展冷启动恢复

- Browser process 继续移除外部注入的 `--load-extension`，同时停用 CDP `Extensions.loadUnpacked` 临时安装路径。Chromium 会在启动时清理带 `INSTALLED_VIA_CDP` 标记的记录；现在路径真正缺失时改由隐藏的原生扩展 WebUI 调用 `chrome.developerPrivate.loadUnpacked`，写入可跨启动恢复的 unpacked 记录。
- 同 ID 更新改用 `chrome.developerPrivate.reload`，启停使用 `chrome.management.setEnabled`，只有明确移除才卸载，避免更新或停用清空扩展存储、权限和安装状态。
- 修复 Tampermonkey 等扩展在每次 Rex 启动时被重新安装、重复收到 `runtime.onInstalled` 并打开“安装成功”页面的问题。旧 CDP 记录升级后仅迁移一次。
- MV3 回归新增连续两次启用态重启：每次必须收到 `runtime.onStartup` 和 worker 启动证据，同时拒绝任何 `runtime.onInstalled` 与 onboarding 请求，并验证持久 `chrome.storage.local` UUID 不变。

### 已知兼容性边界

- iCloud Passwords 的扩展包和权限可以加载，但 Apple 原生连接在当前 ad-hoc ZIP 中仍不可用。已安装列表显示橙色完整限制说明，工具栏显示“Apple 原生连接受限”，action 面板也给出同一限制，不会把该状态写成扩展运行时失败或误导为完整可用。
- 系统原始 `com.apple.passwordmanager` manifest 只注册在 Chrome 专用目录；Apple helper 的 Parent Launch Constraints 又要求获批的 `com.apple.developer.web-browser.public-key-credential` entitlement，或名单内的 Bundle ID + Team ID。当前 ad-hoc `com.rex.browser` 缺 Developer ID 和该 entitlement，也不在 helper 名单中。仅复制 manifest 无法绕过签名约束，本版本不复制、重签 helper，也不伪装受支持浏览器身份。
- Tampermonkey 5.5.0 已确认授予 `userScripts`、`scripting` 和 `<all_urls>`，`withholding_permissions=false` 且 service worker 已启动；但当前 profile 未安装最小测试用户脚本，因此不能把配置状态外推为用户脚本端到端注入已通过。
- 真实 tab identity 和定向消息通过不等同于完整 `activeTab` 权限授予。无静态 popup 的 `action.onClicked`、动态 `action.setPopup` 以及未列入能力矩阵的 Chrome API 仍不承诺支持。
- `chrome.tabs.create` 可把目标 URL 转交为可见 Rex 标签，但 Chromium 临时 WebContents 随后关闭；回调中的临时 `tab.id` 不保证可继续用于 `tabs.get/update/sendMessage`。可靠接管需要跨 Swift/CEF 的完整 browser 生命周期改造，本版不提供近似兼容。

### 版本、验证与产物

- 应用、结构化发布数据、Xcode 工程与打包版本推进到 `v0.9.6` build `962`。
- 最终源码上的 CEF bridge arm64 Release、完整 Xcode Release、iCloud 限制状态单元测试、JS 语法检查、`git diff --check` 和 Release Notes Validator（v0.9.6 build 962，28 个功能 ID）通过。原生扩展页实机点击返回与 Tampermonkey“详情”均准确命中目标。
- Swift 全量集合 `150/150` 通过，新增旧导航终态隔离、重定向完成和刷新/停止命令回归；MV3 fixture/验证器语法检查与 `--self-test` 通过。隔离 Profile 的首次旧记录迁移及随后连续两次正常重启均确认 `runtime.onStartup` 恰好一次、`runtime.onInstalled` 和新增 onboarding 请求为零，安装/更新时间不变；Tampermonkey 最小用户脚本端到端注入仍需单独实测。
- App：`Dist/Rex.app`（`342M` / `350700 KiB`）；ZIP：`Dist/Rex-v0.9.6-macos-arm64-chromium.zip`（`142,580,072` bytes，`147596 KiB` / `144M`）。
- ZIP SHA-256：`4beebc68785310c9d3def7eb4352dbd14ef07ca6d60bd25100c2cbc4bab89ecc`。ZIP 解压、主 App/CEF/五个 Helper 的 arm64 与 `0.9.6 / 962`、deep/strict codesign 和 SHA 清单均通过；本次未生成 DMG。详情见 [v0.9.6 发布说明](Documentation/Releases/v0.9.6.md)。

## 0.9.5 (build 952) — 2026-07-28

### 网页加载兼容性

- 内部扩展生命周期仍通过不开放监听端口的 DevTools pipe 管理，但不再向网页暴露 `navigator.webdriver=true`；同时恢复 Chromium 标准 User-Agent，避免 `itdog.cn` 等站点的反自动化脚本进入高 CPU 死循环并永久白屏。
- 移除 CEF 启动与子进程中的 `--no-proxy-server` 强制参数，网页重新遵循 macOS 系统代理配置。
- 地址提交若早于站点隐私策略加载完成，会在页面创建和策略应用后按顺序补发导航，不再把首次 `loadURL` 丢给尚不存在的 CEF 页面。
- 扩展启动对账失败会继续报告运行时错误，但在没有补偿事务时释放网页导航屏障，不再让恢复页和新地址永久停在 `about:blank`。

### Rex 扩展入口

- 工具栏扩展列表改为深靛蓝高对比度实体面板，强化标题、扩展状态、行项目、更多菜单与管理入口在浅色网页上方的可读性；扩展自身的 Chromium popup、设置与管理行为保持不变。

### Safari 式网站隐私策略

- 隐私盾牌复用 Safari 分支的站点策略方式：`SitePrivacyPolicy` 以 profile 与小写主机名为唯一作用域写入 SQLite，保护开关、级别与指纹保护设置会立即同步到所有已打开的同站标签，并在重启后复用。
- 从一个网站导航到另一个网站时应用目标网站已保存策略；没有例外时使用该空间原本的默认级别。修改网站策略不再隐式改写空间默认级别，避免一个站点的选择扩散到之后访问的新网站。
- 拦截资源和计数仍按标签会话累计；第三方 Cookie 仍是 CEF profile 级全局限制，不伪装成可按网站独立切换的能力。

### 扩展小型面板

- 静态 `default_popup` 主文档加载时，从受控 surface ID 解析用户点击扩展按钮前的来源 HTTP(S) 标签，并为 `chrome.tabs.query({active:true,currentWindow:true})` 提供该只读上下文。当前可见页是 `rex-extension://` 时仍沿用最近有效来源网页。
- 修复 uBlock Origin Lite 等扩展在小面板中拿不到当前网站、面板显示空站点且修改过滤级别不生效的问题；实现位于通用 Chromium popup 桥，不包含扩展名称或专用业务逻辑。
- `chrome.tabs.getCurrent()` 保持 action popup 的空结果语义。完整 `activeTab` 权限、无静态 popup 的 `action.onClicked` 与动态 `action.setPopup` 仍不支持。

### CEF/AppKit 稳定性

- 工具栏扩展列表与扩展 popup 从 SwiftUI `.popover` 改为独立无边框 AppKit `NSPanel`；浮窗跟随工具栏锚点、父窗口移动和扩展内容尺寸，但不再调用 `NSWindow.addChildWindow`。
- 修复在 `rex-extension` 页面再次点击扩展按钮时，`NSPopover` 尝试把窗口附着到 CEF `NSRemoteView`，进而在 `NSRemoteView containingWindowWillOrderOnScreen` 路径概率性崩溃的问题。
- 面板会话增加 generation/UUID 校验，忽略已经关闭或切换后的旧尺寸与关闭回调。

### 版本与构建

- 应用、Xcode 工程与打包默认值推进到 `v0.9.5` build `952`；网页恢复 Chromium 标准 User-Agent。
- Swift Testing `144/144`、Release Notes Validator（28 个功能 ID）、CEF bridge arm64 Release、完整 Xcode Release、主 App与五个 Helper 的 `0.9.5 / 952` 版本和 arm64 架构、deep/strict codesign、ZIP 解压及 SHA 清单均通过。
- 产物：`Dist/Rex.app`（`342M` / `350588 KiB`）、`Dist/Rex-v0.9.5-macos-arm64-chromium.zip`（`142,539,578` bytes，`147576 KiB` / `144M`）和预发布 DMG（`160,241,220` bytes，`156488 KiB` / `153M`）；ZIP SHA-256：`380442d0413b084df39ccd318c6c4e9e4c64bd6fd18edcd17f29bd1858025b20`，DMG SHA-256：`8ccb78088fadba83a0eabd6e983494e5213ed54bf137bb19aca572c745a13d4b`。详情见 [v0.9.5 发布说明](Documentation/Releases/v0.9.5.md)。

## 0.9.4 (build 940) — 2026-07-28

### 扩展热生命周期

- 扩展安装、启用、停用、手动更新和移除改为运行中即时生效，不再要求重新启动 Rex。桥接层通过 Chromium 的 `--remote-debugging-pipe` 调用 `Extensions.getExtensions`、`Extensions.loadUnpacked` 与 `Extensions.uninstall`，不开放本地调试监听端口。
- 每次扩展集合变更使用串行 generation 对账预期的受管路径与启用状态；Chromium 确认实际集合一致后，活跃普通窗口中的 HTTP(S) 页面立即重载一次，使内容脚本和 DNR 应用或撤销。休眠或冻结页面延迟到恢复时重载一次，隐私窗口不运行扩展且不参与热重载。
- 扩展包文件仍先经过 Rex 的来源、身份、签名和安全解包校验；热同步只改变运行时生命周期，不降低受管包的校验边界。
- 同路径更新在换盘前原子写入运行时 replacement journal；Chromium 确认后才提交并清理旧包。若进程在确认前退出，下次启动会恢复上一版本及目录记录，避免留下孤立备份或把未确认版本当作可运行。
- 重新导入已在 Rex 受管目录内编辑的本地扩展时，会显式强制 Chromium unload/load；只覆写既有 JS/CSS、目录与 manifest stat 均未变化时也不会漏掉热更新。

### 冷启动与页面路由

- 恢复会话时，HTTP(S) 标签先停留在 `about:blank`，等待扩展运行时完成当前 generation 对账后才发出首次导航；即使预期集合为空，也会先清理 Chromium profile 中的陈旧受管注册，内容脚本和 DNR 不再依赖用户手动刷新。
- 修复 `chrome.tabs.create` 转交包内页面时临时 Chrome browser 与 Rex 正式标签分别请求同一目标、产生两次主文档请求的问题。
- 成功的热变更只触发一次受控 HTTP(S) 重载，不重载 `about:`、`rex-extension:` 或其他内部页面。

### 性能与验证

- 扩展目录启动校验由每包两次完整文件树扫描降为一次；启停路径只更新内存运行状态，不再重复扫描包内容。
- 单次 manifest 解析只读取一次对应 `_locales/.../messages.json`，名称与描述共享同一本地化字典。
- Chrome Web Store 下载进度约每 80 毫秒发布一次，完成、取消与失败状态仍立即送达，减少高频主线程状态更新。
- 多个普通窗口共享一次进程级首次扩展对账；窗口关闭时取消会话恢复、导航、休眠和无限事件订阅，等待页面任务退出后销毁该窗口全部 CEF 页面，避免隐藏 renderer、媒体、网络和扩展注入继续运行。
- 会话保存改为串行队列；恢复尚未完成时关窗不会以占位标签覆盖已有快照，手动关闭副窗口会等待待处理保存后删除其记录，应用整体退出仍保留当前全部窗口。
- 通用 MV3 探针改为页面和内容脚本向同源 fixture server 自报告，不再依赖已关闭的 TCP CDP，也不会把隐藏的 `about:blank` 扩展上下文误判为 Rex 网页。它直接检查冷启动首次文档，不通过刷新或重复导航掩盖启动竞态；真实 UI 热生命周期验收需要已解锁桌面。
- Swift Testing `140/140` 与 Release Notes Validator（28 个功能 ID）通过；CEF bridge arm64 Release、完整 Xcode Release、主 App 与五个 Helper 的 `0.9.4 / 940` 版本和 arm64 架构、deep/strict codesign、ZIP 解压及 SHA 清单均通过。隔离 App 即使收到 `--remote-debugging-port=9444` 也不会建立 TCP LISTEN。

### 版本

- 应用、Xcode 工程、打包默认值与 Chromium User-Agent 推进到 `v0.9.4` build `940` / `Rex/0.9.4`。
- 产物：`Dist/Rex.app`（`342M`，`350340 KiB`）与 `Dist/Rex-v0.9.4-macos-arm64-chromium.zip`（`142,468,262` bytes，`148464 KiB` / `145M`）；ZIP SHA-256：`aea9e3fd3e11f46ff9a3934693f05c3f9ac20641c21127ca4f52def5535611c2`。

## 0.9.3 (build 930) — 2026-07-28

### 扩展小型面板

- 扩展面板在 Chromium 返回首个有效内容尺寸后再显示，首次打开不再暴露 CEF 的白色占位首帧；已确认的扩展尺寸会在本次窗口会话中复用，避免再次打开时发生可见跳变。
- 自动尺寸在扩展主文档完成加载时立即应用，移除固定 300 ms 的加载后等待；面板以最终宽高完成定位和阴影呈现，减少打开时的卡顿感。
- 保持通用扩展路径：面板仍直接加载扩展声明的静态 `default_popup`，没有添加 AdGuard 或其他单扩展专用页面与逻辑。

### 扩展内部页面路由

- 扩展通过 `chrome.tabs.create` 等 Chromium 路径创建 `chrome-extension://` 包内页面时，桥接层现在会将其交给 Rex，并在应用边界转换为 `rex-extension://` 后以 Rex 标签页打开。
- Chromium 启动扩展时会建立一个始终隐藏的 Chrome Views 窗口上下文，为后台页补齐 `chrome.tabs` 所需的 current-window 语义；扩展新建的 Chrome 标签在主框架开始导航后再转交 Rex，避免空 URL 抢先关闭。
- 面板调用 `window.close()` 后仍短暂保留最近一次有效来源标签标识，修复设置按钮先关闭 popup、随后创建 options 标签时来源丢失的问题。
- HTTP、HTTPS 与 About 弹窗继续沿用原有 Rex 标签路由；带凭据或应用层无法验证的扩展 URL 仍会被拒绝。

### 版本

- 应用、Xcode 工程、打包默认值与 Chromium User-Agent 更新为 `v0.9.3` build `930` / `Rex/0.9.3`。
- Swift Testing `128/128` 与完整 CEF Objective-C++ bridge 增量构建通过；真实 AdGuard 弹窗点击设置后已确认进入 `rex-extension://…/pages/options.html`，未暴露额外 Chrome 窗口。

## 0.9.2 (build 920) — 2026-07-28

### Chromium 扩展运行时

- Rex 继续提供扩展发现、安装管理、工具栏列表和小型面板；列表行可整行进入扩展交互，小型面板直接加载清单声明的静态 `default_popup` 资源，options 页面使用 `rex-extension://<runtime-id>/<包内路径>` 打开。
- Chrome Web Store CRX2/CRX3 仍需经过来源限制、扩展身份/签名验证和安全解包，本地 Manifest V2/V3 文件夹则复制到受管目录。商店包会在每次启动前重新核对 manifest 公钥推导出的 Chromium 扩展 ID。
- 当前启动时启用的受管包由 Chromium 扩展运行时直接加载。已验证的后台服务、内容脚本、消息、存储、DNR 和 options 页面由包内代码与 Chromium 实现，Rex 不再解析规则后模拟扩展行为，也没有 AdGuard 专用执行路径。
- 最终 `Dist` Release 包的通用 MV3 黑盒探针按 service worker、content script/DNR、options、popup 的顺序等待就绪，连续两次均为 `8/8` 通过。
- 扩展安装、启用、停用和移除均以启动快照为边界，需要重新启动 Rex 才能改变 Chromium 中的实际加载集合；已加载扩展的移除会延后到下次启动清理。
- Rex 的小型面板与扩展管理界面是产品外壳；静态 `default_popup`、options 等内容直接来自已安装扩展包，内部仍在 `chrome-extension://` 安全源中执行，对外统一显示为 `rex-extension://`，而不是针对某个扩展重做前端。
- 小型面板不会触发 Chromium 原生 action popup。stock CEF 150 的 Alloy 嵌入路径不提供 `activeTab` 授权或 `chrome.tabs` 当前窗口语义；未声明静态 popup 而依赖 `action.onClicked` 的按钮，以及运行时 `action.setPopup` 动态变更，当前也不支持。
- 非广告 fixture 从扩展列表整行进入扩展自身 popup，自动尺寸为 `280×113`，显示 `Ready` 并与 service worker 完成消息交互；AdGuard 通过同一路径自动调整为 `320×600`，分段交互有效，没有专用代码。
- 普通 Rex UI 回归确认没有网页裁剪、负偏移或 Chrome 窗口覆盖；未托管的 Chrome extension popup/auxiliary window 会把普通网页目标交给 Rex 后关闭。

### 版本与发布状态

- 应用版本、Xcode 工程、打包默认值与 Chromium User-Agent 更新为 `v0.9.2` build `920` / `Rex/0.9.2`。
- 打包脚本校验主 App 与五个 CEF Helper 的版本、构建号、arm64 架构和 ad-hoc 签名，并拒绝把根目录调试日志带入发布包。
- 修复 CEF 单实例的正常退出处理：重复启动返回 code 24 时第二个进程静默以状态 0 退出，不再显示故障框或留下空壳窗口；真正的初始化失败仍会提示并退出。
- 移除系统密码调用、`SystemPasswordsCoordinator` 和 Rex 主可执行文件的 `AuthenticationServices` 依赖。打包门槛拒绝主 executable 链接该 framework 或 App 包含 `.systemextension`，并写入 `rex_password_integration=absent`；上游 Chromium Embedded Framework 自身仍保留该系统 framework 链接。
- Swift Testing `128/128`、完整 CEF bridge 的 Xcode arm64 Debug/Release 构建、Release Validator、deep codesign、ZIP 解压与校验和验证均通过。隔离 profile 下第二个 Dist Release 实例由首实例接管，并以 exit code 0 正常退出。
- 主 App 与五个 CEF Helper 均为 `0.9.2 / 920`、仅包含 arm64。产物为 `Dist/Rex.app`（`342M`，`349776 KiB`）和 `Dist/Rex-v0.9.2-macos-arm64-chromium.zip`（`142,320,000` bytes，`du` 为 `144M`）；ZIP SHA-256：`c815a492297dac404b0d323eb2b6a628b26d58a352bc02ff9a5760605c2a898c`。

## 0.9.1 (build 910) — 2026-07-27

### 版本与功能 UI

- 重做「版本与功能」导航与内容结构：当前版本、完整功能、已知问题和历史版本使用独立页面，不再把全部信息堆叠在单一滚动页。
- 当前版本页新增发布摘要、版本/构建/通道、Chromium/CEF/架构与功能数据版本，并用分段控件切换新增、改进、修复、变更、移除、问题和开发中内容。
- 完整功能页新增名称/描述/设置路径搜索、分类与状态筛选、状态数量概览，以及可展开的限制详情。
- 已知问题页合并当前发布问题与结构化功能限制；历史版本页提供版本统计、内容数量和单版本详情。
- 浏览器外壳、标签、分屏内容与设置卡片统一采用可感知深浅色和增强对比度的描边层级。

### Chrome Web Store 直接安装

- 精选目录条目新增「直接安装」；也可粘贴任意 `chromewebstore.google.com` 详情链接或 32 位扩展 ID。
- 下载只允许 Google 官方更新与包主机，拒绝非 HTTPS、凭据 URL 和越界重定向，单包下载与解包上限为 256 MB。
- 支持 CRX2/CRX3：验证扩展 ID、公钥身份及 RSA/ECDSA 签名后才进入解包；ZIP 解包拒绝加密、ZIP64、多卷、符号链接、路径穿越、重复路径、校验和错误和超额文件。
- 商店 ID 与安装来源写入扩展目录；使用相同 ID 重新安装会原位更新并保留原安装时间与启用偏好。
- UI 展示下载、验证、解包、导入、成功、失败与重试状态；已安装列表区分商店验签包与本地受管包。
- CEF 150 在 macOS 原生父视图嵌入下仍使用 Alloy runtime，因此本版“直接安装”指可信获取与包管理，不声称已执行扩展脚本、service worker 或 Chrome API。

### CEF 与发布

- CEF 供应链由 `minimal` 切换为同版本官方 `standard` ARM64 发行包：CEF `150.0.14+g7c1aa68+chromium-150.0.7871.129` / Chromium `150.0.7871.129`。
- 锁文件更新为官方 SHA-1 `ae4a49d31fe61d4e0dc55050449cf967b7549ba0` 与 SHA-256 `57f58530234f5b2a24f02479fdbc92b50aa5f94f7a66e32251cb71571284fad1`。
- 应用版本更新为 `v0.9.1` build `910`；User-Agent 产品串更新为 `Rex/0.9.1`。
- 新增签名 CRX 端到端测试，覆盖下载替身、身份与签名验证、安全解包、受管安装及商店身份持久化；并修复 Foundation 不支持同时使用 `atomic` 与 `withoutOverwriting` 导致的安装崩溃。
- Release Validator 通过（28 个功能 ID），Swift Testing `108/108` 通过，完整 CEF bridge、XcodeGen、Xcode arm64 Debug 构建与运行时嵌入通过。
- 真实 Chrome Web Store 烟雾验证完成 uBlock Origin Lite 9,861,135 字节 CRX3 的下载、身份/签名验证与安全解包；最终 UI 验收确认 v0.9.1 版本页、功能筛选、已知问题、历史版本和商店直装入口。
- 产物：`Dist/Rex.app`（约 348M）与 `Dist/Rex-v0.9.1-macos-arm64-chromium.zip`（144,895,454 字节，约 145M）；ZIP SHA-256：`e0f746d0a584c28c854ffd580c19e281ac426c070a0051200c9ac2393d47310c`。主应用与五个 Helper 均为 `0.9.1 / 910` 且仅包含 arm64。

## 0.9.0 (build 900) — 2026-07-27

### 新标签页与收藏网站

- 最近访问与收藏网站使用一致的宽度和高度；窄窗口与左右分屏下会自适应换列，快捷操作不再横向溢出。
- 问候区与搜索框显示当前 Google、Bing、DuckDuckGo、Brave Search 或 Ecosia 的本地品牌图标，不依赖启动时联网获取。
- 收藏网站改为点击「新增」后填写名称和网址；自动补全 HTTPS，只接受 HTTP/HTTPS，并拒绝空字段、凭据 URL 和重复网址。
- 新标签页收藏改为所有普通窗口共享的可观察仓库。新增和移除先原子写盘、成功后再同步各窗口，避免多窗口和启动恢复期间互相覆盖；隐私窗口仍不读取或写入收藏。

### 关于 Rex 与中文菜单

- 设置中的「关于 Rex」补齐应用版本、构建号、Chromium、CEF、arm64 架构、发布通道、功能分组和已知限制。
- 「版本与功能」可查看结构化发布记录；同版本的不同构建使用独立身份，不再发生历史导航冲突。
- 文件、编辑、显示、窗口、帮助与常用系统命令改为中文，同时保留原 action、系统角色、状态和快捷键；动态窗口、工作空间与第三方服务标题不被误翻译。

### Rex 扩展

- 扩展页新增「发现」与「已导入」视图，内置 6 个拥有真实 Chrome Web Store ID 的扩展条目，支持搜索、分类和打开官方详情页。
- Rex 不抓取、镜像或重新分发 CRX；Chrome Web Store 页面在系统默认浏览器打开，网页中的 Chrome 安装不会静默进入 Rex。
- 本地 Manifest V2/V3 文件夹支持清单、本地化名称、图标和权限校验，以及受管副本导入、更新回滚、Finder 定位与安全移除。
- 当前 CEF 150 最小发行包不提供 Chrome Web Store 安装、自动更新或完整扩展运行时，本地扩展的页面脚本、service worker 和 Chrome API 暂不执行。

### 构建与发布

- 应用版本更新为 `v0.9.0` build `900`；User-Agent 产品串更新为 `Rex/0.9.0`。
- `Dist` 只保留当前版本的应用、ZIP、校验清单与包信息；旧版二进制及 `0.8.x` 派生构建缓存已移到可恢复的废纸篓目录，历史发布说明继续保留在源码文档中。
- 打包流程改为先在同级临时发布目录中完整组装应用、ZIP、校验清单与包信息并逐项验证，再整体切换 `Dist`；切换失败或收到中断信号时自动恢复上一份可用目录。
- Release Validator 通过（28 个功能 ID），Swift Testing `103/103` 通过，完整 CEF/Xcode arm64 Debug 构建通过；主应用、CEF 与五个 Helper 均为纯 arm64，应用及 Helper 版本均为 `0.9.0 / 900`。
- 最终 UI 冒烟确认新标签页等尺寸站点卡片、Google 品牌图标、收藏新增入口、关于页、扩展页，以及文件和窗口系统菜单中文化均来自最终 `Dist/Rex.app`。
- 产物：`Dist/Rex-v0.9.0-macos-arm64-chromium.zip`（144,516,033 bytes；`du` 约 144M）/ `Dist/Rex.app`（`du` 约 346M）；ZIP SHA-256：`a4741f0e61f58f5a60d821351705cb0093e66b09fd2281a0888f1bf563697525`，SHA 清单与压缩数据完整性校验通过。

## 0.8.1 (build 810) — 2026-07-27

### 资料库清理、隐私目录与网页性能详情

- 历史记录页新增「删除浏览数据」菜单，可永久删除过去 1 小时、过去 24 小时、过去 7 天或所有时间的浏览历史；执行前显示范围明确的确认提示，收藏和下载记录不受影响。
- 收藏库与下载的空状态改为填满标题栏下方剩余区域，修复内容垂直居中导致顶部间距过大的问题。
- 主窗口启用全尺寸内容标题栏，并恢复为 50 pt 槽内的 44 pt 单导航卡：普通窗口将红黄绿按钮下移 8 pt，与导航卡垂直居中后再根据按钮真实位置动态避让；全屏时使用 8 pt 普通边距。
- 内存/CPU 指标回到导航栏首项，点击仍可打开性能监测详情页；红黄绿按钮周围的无控件区域保留为窗口拖动区。
- 性能详情页显示 Rex 总内存与总 CPU，以及每个标签页的标题、站点、生命周期、CEF 任务内存和 CPU。移除 CPU/内存排序切换、行分隔线和重复的「网页」区标题，放大网页/内存/CPU 列标题，并改为按标签页顺序稳定显示的独立网页卡片。
- 网页指标来自 CEF CefTaskManager，首轮约 2 秒刷新完成前保持加载；无法取得任务的休眠/归档页面保留并显示“—”。CEF 公共 API 不提供 renderer PID，因此共享 renderer 可能出现重复值且不可相加；GPU、Worker 与 Utility 不会被虚构分摊到页面。
- 当前垂直标签菜单不再提供「关闭其他标签页」和「关闭右侧标签页」，保留单页关闭与恢复关闭标签等操作。
- 应用版本更新为 `v0.8.1` build `810`；User-Agent 产品串更新为 `Rex/0.8.1`。

### 隐私盾牌实现说明

- Swift 顶层导航策略清理已知追踪参数，并对非本地 HTTP 地址尝试 HTTPS；它不处理 CEF 子资源请求。
- CEF 请求层使用内置 45 个广告、41 个追踪、10 个指纹和 8 个社交目录条目分类子资源，命中后在 `OnBeforeResourceLoad` 返回取消，并把分类与域名统计回传到标签页。
- 新增[隐私盾牌内置请求目录](Documentation/PrivacyDomainCatalog.md)，逐条公开全部 104 条规则、3 条主机加路径规则、跨类别重复项和实际分类优先级。
- 标准模式拦截第三方广告/追踪目录；由于指纹保护默认开启，标准模式也会拦截第三方已知指纹服务。严格模式再追加社交目录。自定义模式映射为 aggressive：广告/追踪目录允许匹配第一方请求，并对第三方请求启用路径启发式。
- 第三方 Cookie 由 CEF profile 的全局 Cookie 设置限制，不是逐标签请求拦截；关闭单个标签页盾牌不会关闭该全局限制。
- 当前不包含恶意网站检测、Safe Browsing、自定义规则、EasyList、通用 Canvas/WebGL 指纹随机化或完整 PSL/eTLD+1 分类。

### 验证与产物

- Release Notes 版本与结构校验通过（v0.8.1，27 个功能 ID）；Swift Testing `77/77` 通过；完整 CEF bridge、XcodeGen 与 Xcode arm64 Debug 构建通过。
- 产物：`Dist/Rex-v0.8.1-macos-arm64-chromium.zip`（143,459,208 bytes；`du` 约 144M）/ `Dist/Rex.app`（约 344M）。
- ZIP SHA-256：`faea8f13e5239d5c09b15c360bad6fd8dc9488929e278643fe0af91ef6c33af1`；压缩数据完整性校验通过。
- 主程序、CEF 与五个 Helper 均为纯 arm64，App/Helper 版本均为 `0.8.1 / 810`。真实 App 冒烟确认红黄绿按钮下移后与紧凑单导航卡对齐，窗口缩放和全屏往返无累计偏移；性能详情页成功读取真实网页任务指标并正确保留无数据标签。四档历史删除菜单、收藏/下载空状态的上一轮验证继续有效，运行中 CEF 子进程使用 `Rex/0.8.1`。
- 包内没有 EasyList 规则文件或 Rex 运行时引用；CEF 上游 `Chromium-CREDITS.html` 仍依法保留 EasyList 许可证归属文字。
- Developer ID 签名、公证与自动更新仍不在本地 Debug 包范围内。

## 0.8.0-beta.1 (build 801) — 2026-07-26

### 移除 EasyList + 域名目录盾牌 + 左右分屏菜单

- **移除 EasyList**（任务 1）：删除 `RexEasyListEngine` 引擎、`Resources/FilterLists` 三个规则快照（约 4.2 MB）、列表装载 API 与相关测试——快照引擎实际拦截效果不佳。
- **隐私盾牌改用精选域名目录**（任务 2）
  - 标准级别仅拦截第三方已知广告/追踪域名（精确匹配，无路径启发式，不影响网站自身资源）
  - 严格级别追加指纹与社交组件目录；激进级别才启用路径启发式与第一方匹配
  - 设置开关更名为「拦截广告与追踪器」（`Rex.contentBlockingEnabled`），运行时即时生效
- **仅保留左右分屏**（任务 3）：删除上下分屏布局、「切换分屏方向」按钮与 ⌘⌥O 命令；旧的上下分屏会话与组合恢复时自动转为左右。
- **标签页右键菜单分屏**（任务 4）：右键标签可创建分屏、选择左右位置、替换对应页面、将现有分屏标签换侧，或退出分屏并保留该标签。
- 移除标签拖放分屏协议、网页投放区高亮和分屏页面蓝色焦点描边；分隔条拖动调节比例保持不变。
- 应用版本 `v0.8.0-beta.1` build `801`；User-Agent 产品串 `Rex/0.8.0`。

### 验证

- Release Notes 校验通过；Swift Testing `71/71` 通过。
- `Scripts/package-chromium-app.sh` 默认参数已更新为 `0.8.0-beta.1 / 801 / Debug`，完整 CEF bridge、XcodeGen、Xcode arm64 Debug 构建与运行时嵌入通过。
- 产物：`Dist/Rex-v0.8.0-beta.1-macos-arm64-chromium.zip`（143,302,873 bytes；`du` 约 144M）/ `Dist/Rex.app`（约 343M）。
- ZIP SHA-256：`57adc206be5410cf2e339f4c0c2c4c9c90494112b4025a6c049cb7da22928395`；SHA 清单与压缩数据完整性校验通过。
- 主程序、CEF 和五个 Helper 均为纯 arm64；App/Helper 版本均为 `0.8.0 / 801`；包内无 EasyList 规则、资源或构建引用。
- 使用隔离临时 profile 启动最终 `Dist/Rex.app` 冒烟通过：GPU、Network、Storage 与 Renderer 进程正常拉起，实际 User-Agent 产品串为 `Rex/0.8.0`，域名目录内容拦截已启用。
- 内容拦截：`rex-curated-domain-catalog` · 性能层：`rex-thorium-hybrid-v1.3` · DevTools：`cef-chromium-devtools`。
- 当前产物为 `CODE_SIGNING_ALLOWED=NO` 的本地 Debug 包；Developer ID 签名与公证不在本次验证范围内。

## 0.7.0-beta.1 (build 701) — 2026-07-26

### EasyList 拦截回归 + 性能层 v1.3 + 站点信息钻取

- **EasyList 网络规则引擎**（任务 4）
  - 新增 `RexEasyListEngine`：真实 EasyList 语法子集（`||`/`|`/`*`/`^`、`@@` 例外、`$domain=`、资源类型、`$third-party`、`$important`、`$document` 整页豁免）
  - 内置 EasyList / EasyPrivacy / EasyList China 快照（2026-07-26）；无法忠实执行的规则整条丢弃，避免 build 607 式误伤
  - 设置 › 隐私与安全新增「启用 EasyList 规则」开关（默认开启），运行时即时生效；每标签页盾牌开关与级别继续独立生效
  - 拦截统计按类别回流隐私盾牌（EasyList/China → 广告，EasyPrivacy → 追踪器）
- **性能层 `rex-thorium-hybrid-v1.3`**（任务 1）
  - raster 线程按核数自适应（4/6/8）；显式 `--use-angle=metal`；≤8 GiB 机型禁用备用渲染进程
  - 性能指标监视器失焦降频采样（1.5s → 6s）并去抖发布
  - 继续强制关闭 zero-copy / RawDraw 等 CEF reparent 白块风险开关
- **站点信息弹窗钻取**（任务 3）
  - 证书与网站权限行改为弹窗内推入详情页（返回、证书链切换、复制 PEM、权限修改/删除）
  - 完整证书查看器与权限中心保留为详情页内次级入口
- **SwiftUI 打磨**（任务 2）
  - 新增 `RexChromeColor` 自适应描边/填充，修复浅色模式白色描边不可见
  - 液态玻璃按钮悬停高亮；favicon 后备色改稳定哈希；弹窗宽度统一 350pt
- 应用版本 `v0.7.0-beta.1` build `701`；User-Agent 产品串 `Rex/0.7.0`

### 验证

- 完整 Chromium 包：`Scripts/package-chromium-app.sh 0.7.0-beta.1 701 Debug` 通过（CEF 桥 + xcodegen + Xcode arm64 Debug + 嵌入校验）。
- 产物：`Dist/Rex-v0.7.0-beta.1-macos-arm64-chromium.zip`（约 144M）/ `Dist/Rex.app`（约 347M）。
- ZIP SHA-256：`a86c06fdbdd10b512635b4eae3025f9626cd155184070e9539311a281c2a140c`。
- 性能层：`rex-thorium-hybrid-v1.3` · 内容拦截：`easylist (toggleable)` · DevTools：`cef-chromium-devtools`。

## 0.6.0-beta.1 (build 612) — 2026-07-26

### CEF 网页圆角与应用图标

- 为保持 Chromium 非 layer-backed 合成路径，使用窗口坐标对齐的补角层覆盖 CEF 方形视口四角，避免直接裁剪导致网页空白或停止绘制。
- 将内容区背景与标题栏安全区背景拆分绘制，修复暗色模式下圆角外侧出现半透明方块的问题。
- 关闭主浏览区与侧栏互相叠入间隙的面板阴影，修复浅色模式下圆角补片与周围背景的亮度色差。
- 新增完整 macOS `AppIcon` 资产目录，包含 16–1024 px 全部规格、透明外角和正式 `AppIcon.icns`。
- 应用启动时主动加载包内 `AppIcon.icns`，并提升构建号使 LaunchServices/Dock 的通用占位图标缓存失效。

### 验证

- Swift Testing：68/68 通过。
- CEF arm64 Debug Xcode 构建通过，`Dist/Rex.app` 已更新并启动验证。
- 从运行中的 `NSRunningApplication` 读取图标，确认使用正式人物图标而非系统占位图。

## 0.6.0-beta.1 (build 611) — 2026-07-26

### 只保留 Chromium 原版 DevTools

- 删除 Swift 自制 DevTools 面板、控制器、状态模型和通知。
- 删除专用于旧面板的 C++/ObjC CDP 会话桥。
- 开发者工具仅通过 CEF 150 的 `CefBrowserHost::ShowDevTools` 创建并嵌入。
- 保留 Chromium 原版 Console/Inspect 快捷键、popup 重挂载和尺寸同步。

## 0.6.0-beta.1 (build 610) — 2026-07-25

### DevTools DOM 树 Chrome 1:1 收口

- **关闭标签行**
  - 展开元素后补齐独立的 `</tag>` 行（与 Chrome Elements 一致）
  - 空非 void 元素内联为 `<div></div>`；void 标签不再生成闭合行
- **可见性与密度**
  - 过滤纯空白 `#text` 噪声节点
  - 折叠摘要仍为 `<tag …>…</tag>`
  - 行高约 18pt，缩进 10pt × depth，disclosure 改为小三角
- **交互**
  - List 负责选中；开/闭行共享同一 node 选中态
  - 仅 chevron / 双击切换展开，避免单击手势抢选中
  - `#comment` / `#document` / `<!DOCTYPE>` 着色与 Chrome 更接近
- Package build **610** SHA-256 `d8884c2850d0e65643a23eaeb6ff6a574a474921ce592b2b19b53b6e7e30f4e8`
- 产物：`Dist/Rex-v0.6.0-beta.1-macos-arm64-chromium.zip`（约 144M）/ `Dist/Rex.app`（约 342M）
- 功能层：`none`；性能层：`rex-thorium-hybrid-v1.2`；DevTools：`swift-native-chrome-parity+cdp-cpp`


## 0.6.0-beta.1 (build 609) — 2026-07-25

### DevTools Elements DOM 树 Chrome 对齐

- **DOM Tree 重做**
  - 可折叠展开三角形（仅显示 expanded 祖先下的可见节点）
  - Chrome 风格语法着色：标签 / 属性名 / 属性值 / 文本 / 注释 / 标点
  - 折叠节点显示 `…</tag>` 摘要；双击或三角切换展开
  - 选中行蓝色高亮，隐藏 List 分隔线
  - 默认展开 document/html/head/body 与浅层节点，避免全量平铺
- **Styles 面板**
  - DOM 就绪后自动选中 `body`/`html` 并拉取 computed styles
  - CSS 文本按属性名/值/注释着色
- **数据**
  - 保留最多 1200 DOM 节点；选中时自动 expand 祖先路径
- Package build **609** SHA-256 `15a46252e1112c8f462d514b1a7bf6c3fc682f503b9cbdbb620cb6b21db3c94f`
- 产物：`Dist/Rex-v0.6.0-beta.1-macos-arm64-chromium.zip`（约 144M）/ `Dist/Rex.app`（约 342M）
- 功能层：`none`；性能层：`rex-thorium-hybrid-v1.2`；DevTools：`swift-native-chrome-parity+cdp-cpp`


## 0.6.0-beta.1 (build 608) — 2026-07-25

### 删除功能层残留 + Chrome 风格 DevTools

- **删除功能层残留源码**
  - 移除 `Vendor/FeatureLayer/`、`rex-adblock-ffi`、FilterLists 资源与 adblock 构建脚本
  - `RexPrivacyEngine` 仅保留 stub API（分类恒放行，无广告拦截）
  - 运行时日志改为 `performance layer=... (feature layer removed)`
- **仅保留 Thorium 性能层** `rex-thorium-hybrid-v1.2`
- **DevTools Chrome 1:1 视觉与快捷键完善**
  - 暗色 Chrome DevTools 主题（tab strip / toolbar / console / network）
  - 面板：Elements、Console、Sources、Network、Performance、Memory、Application、Security
  - 快捷键：`⌘⌥I` 开关、`⌘⌥J` 控制台、`⌘⇧C` 检查、`⌘⇧R` 硬刷新、面板内 `⌘[` / `⌘]` 切换、`Esc` 取消检查、`⌘K` 清空控制台
  - Console 级别过滤 / Network 类型过滤与详情抽屉 / Sources 脚本树
  - 宿主侧栏去掉液态玻璃标题条，改为 Chrome 风格暗色面板
- Package build **608** SHA-256 `4c7b1e5adabafd125974c2d9fe0c2995764ed7788bfcfee3fe5b6cefd6e9bbfa`
- 产物：`Dist/Rex-v0.6.0-beta.1-macos-arm64-chromium.zip`（约 144M）/ `Dist/Rex.app`（约 342M）
- 功能层：`none`；性能层：`rex-thorium-hybrid-v1.2`；DevTools：`swift-native-chrome-parity+cdp-cpp`

## 0.6.0-beta.1 (build 607) — 2026-07-25

### 移除广告拦截，仅保留 Thorium 性能层

- **删除 adblock 路径**
  - 请求层不再调用 adblock-rust / 主机目录拦截
  - 关闭 cosmetic hide 注入
  - 关闭第三方 Cookie 拦截
  - 构建不再链接 `librex_adblock.a`
- **保留** `rex-thorium-hybrid-v1.2` 性能参数
- **说明**：此前规则过宽导致站点图片/资源被误伤（如 itdog.cn 广告位空白），本构建恢复默认放行
- Package build **607** SHA-256 `9d630113ecb979b98dd4f16093cc19c9fa74ea6117d8987846da20f785e17b48`
- 产物：`Dist/Rex-v0.6.0-beta.1-macos-arm64-chromium.zip`（约 144M）/ `Dist/Rex.app`（约 341M）
- 功能层：`none`；性能层：`rex-thorium-hybrid-v1.2`

## 0.6.0-beta.1 (build 606) — 2026-07-25

### Brave adblock-rust cosmetic + DevTools 深化

- **cosmetic filtering**
  - `rex-adblock-ffi` 新增 `rex_adblock_cosmetic_for_url`
  - 页面 `OnLoadEnd` 注入 hide CSS（`#rex-adblock-cosmetic`）
  - 内置列表扩展网络规则 + 通用/站点 cosmetic hide
- **功能层版本** `v2.1-adblock-cosmetic`
- **DevTools**
  - Elements DOM depth=5
  - Sources 收集 `Debugger.scriptParsed`
  - Application 读取 localStorage/sessionStorage/cookie
  - Memory 读取 `performance.memory`
- Package build **606** SHA-256 `db33b42bb108b3026bd9cb7e17b1f3cb8e3bb2c27e4c9b9f334ee70649e6d574`

## 0.6.0-beta.1 (build 605) — 2026-07-25

### Brave adblock-rust + DevTools

- **集成 brave/adblock-rust**
  - 新增 `Vendor/FeatureLayer/adblock-rust` 与 C ABI 包装 `rex-adblock-ffi`
  - CEF 请求路径优先走 EasyList 语法引擎，主机目录作为兜底
  - 内置 `FilterLists/rex-bundled.txt`，支持追加 easylist/easyprivacy
- **Thorium 性能层保持** `rex-thorium-hybrid-v1.2`
- **DevTools 优化**
  - Elements：DOM 树深度解析、节点高亮、计算样式
  - Network：状态/方法/类型/耗时/大小列
  - Console：级别着色；底部状态栏显示 CDP 连接态
  - 去掉 DevTools 宿主 `.clipped()` 以避免额外裁剪问题
- Package build **605** SHA-256 `4a151b13fb4cf6925d979b3128e4550762aa37d9bd1b68e0d62562c83d2c802f`


## 0.6.0-beta.1 (build 604) — 2026-07-25

### Brave + Thorium hybrid deepening

- **Brave-style privacy engine v1.2**
  - Expanded advertising / tracking / fingerprinting host catalogs
  - Added social-widget third-party blocking (strict+)
  - Protection modes: `off` / `standard` / `strict` / `aggressive`
  - Per-tab shield policy pushed from Swift UI into CEF request hooks
  - Third-party cookie blocking now respects shield enabled/mode
- **Thorium-style performance profile `rex-thorium-hybrid-v1.2`**
  - GPU raster + Canvas OOP + QUIC + process-per-site + raster threads
  - Continues force-disabling zero-copy / RawDraw paint-risk switches
- **Privacy shield UI**
  - Toggle and protection level now bind to real tab state
  - Recent blocked hosts list
  - Suspicious-script and fingerprint counts included in report aggregation
- Docs / lock: `Chromium/feature-layer.lock.json`, `Documentation/FeatureLayer.md`, `Vendor/FeatureLayer/README.md`

### Notes

- Still a **hybrid runtime layer** on official CEF 150, not a full brave-core + Thorium source rebuild.
- Full source fusion remains planned under `futureSourceBuild`.
- Package: `Dist/Rex-v0.6.0-beta.1-macos-arm64-chromium.zip` build **604**, SHA-256 `cf21df787579ef90b95b27117a37cbfabca4a3b6aade6274f77134d0a3019964`.


本项目遵循语义化版本。发布日期均使用本地项目时区。

## Unreleased

（无）

## v0.6.0-beta.1 — 2026-07-25

### 版本摘要

落地 Brave 风格隐私功能层 + Thorium 风格性能参数，并用 Swift 原生 UI 与 C++ CDP 协议层重做开发者工具。

### 新增

- `RexPrivacyEngine`：扩展广告/追踪/指纹/可疑脚本拦截目录与路径启发式。
- `RexThoriumFlags`：GPU raster、Canvas OOP、QUIC、process-per-site 等运行时优化（默认关闭 zero-copy/RawDraw）。
- Swift 原生 DevTools：Elements、Console、Network、Sources、Performance、Memory、Application、Security。
- C++/ObjC `RexDevToolsProtocolSession`：通过 Chromium DevTools Protocol 驱动原生面板。
- `Chromium/feature-layer.lock.json` 与 `Documentation/FeatureLayer.md` 记录混合架构与后续源码融合路径。

### 修复

- 默认关闭 zero-copy / RawDraw / native GPU memory buffers，缓解 CEF reparent 宿主路径下多站点大面积白块/未绘制区域。

### 行为变化

- 开发者工具默认使用原生 SwiftUI 面板，不再以 CEF 内嵌 Chrome DevTools 前端为主 UI。
- 用户代理产品串更新为 `Rex/0.6.0`。
- 应用版本：`v0.6.0-beta.1` build `601`。

### 已知问题

- 完整 brave-core + Thorium 源码编译与自建 CEF 包仍在规划。
- 原生 DevTools 的 Sources/Memory 深度可视化尚未达到 Chrome 前端完整 parity。
- Developer ID 签名、公证与自动更新尚未完成。

### 验证与打包

- CEF Objective-C++ 桥与隐私/CDP 新源文件编译通过。
- 修复 Swift 6 并发：`DeveloperToolsController` 将 CDP 通知快照为 `Sendable` 值后再切回 MainActor。
- 完整 Xcode arm64 Debug 构建通过。
- 完整 Chromium 包：`Scripts/package-chromium-app.sh 0.6.0-beta.1 601 Debug`
- 应用版本：`v0.6.0-beta.1` build `601`
- 产物：`Dist/Rex-v0.6.0-beta.1-macos-arm64-chromium.zip`（约 135M）/ `Dist/Rex.app`（约 341M）
- ZIP SHA-256：`8ef55b743df88ae81cfcd2b4dd51bd2a6f645aca87504a3be75e12166101727f`
- 能力层：`feature_layer=rex-brave-privacy` · `performance_layer=rex-thorium-hybrid-v1.1` · `devtools=swift-native+cdp-cpp`

## v0.5.3-beta.2 — 2026-07-24

### 修复

- 新标签页将「收藏网站」移动到「最近访问」右侧，书签区独立放到下一行。
- DevTools 重挂载前临时移除 CEF popup 的 32pt macOS 标题栏，并归零原生视图 bounds，修复 Console、Elements 等标签的可见位置与点击命中区域不一致。
- 重挂载完成后恢复并隐藏临时窗口，避免它干扰窗口焦点和 macOS ScreenCaptureKit。
- 修正 XcodeGen 资源阶段配置，确保版本功能与发布说明 JSON 包含在完整 App 中。

### 验证与打包

- Release Notes 校验、CEF Objective-C++ 桥和完整 Xcode arm64 Debug 构建通过；Swift 测试 42/46 通过，剩余 4 个断言来自 3 个既有地址栏异步初始化竞态用例。
- 完整 Chromium 包：`Scripts/package-chromium-app.sh 0.5.3-beta.2 525 Debug`
- 应用版本：`v0.5.3-beta.2` build `525`
- ZIP SHA-256：`a9e8486fe7381b732cafa0946ba3a88c567d657058693eebd80acc3cd47cf4f9`

## v0.5.3-beta.1 — 2026-07-24

### 版本摘要

性能监测精简、开发者工具拖拽更平滑、新标签页收藏网站、菜单栏按实际数量显示，并移除右键「显示网页源代码」。

### 修复

- 工具栏性能监测仅保留内存与 CPU，去掉加载进度芯片及其预留空位。
- 拖动开发者工具宽度改为本地拖拽状态 + 拖动期间挂起 CEF `WasResized`，松手后一次性 flush，减轻闪烁与重绘抽搐。
- 菜单栏「标签页」仅列出实际可见标签（1…min(8,N) + 最后一个），「工作空间」按真实空间名称与数量显示，不再固定 9 项。
- 右键菜单删除「显示网页源代码」，保留「检查」。

### 新增

- 新标签页「收藏网站」卡片栏：仅对 NTP 生效，与网页收藏（书签）独立，持久化到 `~/Library/Application Support/Rex/newtab-favorites.json`；支持添加当前页/剪贴板网址与右键移除。

### 打包

- 完整 Chromium 包：`Scripts/package-chromium-app.sh 0.5.3-beta.1 524`
- 应用版本：`v0.5.3-beta.1` build `524`

### 已知问题

- 扩展管理器仍为本地包管理；CEF 150 最小发行版未提供完整扩展执行 API。
- Developer ID 签名、公证与自动更新尚未完成。

## v0.5.2-beta.1 — 2026-07-23

### 版本摘要

完成 Chrome 风格动态右键菜单、分组主菜单、设置中心和可持久化的默认搜索引擎。

### 新增功能

- 新增页面、链接、媒体、选中文本和可编辑区域的动态 CEF 原生右键菜单。
- 新增右上角分组主菜单，覆盖窗口、资料库、缩放、打印、查找、工具和设置。
- 新增 Chrome 风格侧栏设置中心及设置搜索。
- 新增 Google、Bing、DuckDuckGo、Brave Search 和 Ecosia 默认搜索引擎。
- 新增标签页重载、关闭其他标签页和关闭右侧标签页。

### 行为变化

- 地址栏关键词和右键“搜索所选文本”统一使用持久化的默认搜索引擎。
- 资料库菜单可直接打开历史、下载或书签分类。
- `⌘,` 打开设置中心；Rex 网页渲染内核继续固定为 CEF/Chromium。

### 测试情况

- 实现前完成 v0.5.1 真实 UI 基线测试。
- Swift Testing 回归扩展到 44 项，覆盖搜索 URL、偏好持久化、地址栏搜索、右键事件与标签批量关闭。
- CEF Objective-C++ 桥、完整 Xcode arm64 Debug 构建和真实 UI 回归通过。

### 已知问题

- “保存页面”是 CEF 下载当前页面 URL 的回退，不是包含页面资源目录的完整网页存档。
- 系统会给原生菜单追加“服务”或“自动填充”；自定义项目没有 Chrome 品牌图标。
- 设置中心是 Rex 当前功能子集，不包含投放、跨设备、二维码、阅读模式、整页翻译或密码管理器。
- Gemini 和其他 AI 项按 Rex 产品边界明确不加入。
- Developer ID 签名、公证与自动更新尚未完成。

## v0.5.1-beta.1 — 2026-07-23

### 版本摘要

完成下载管理闭环：下载可取消、重试、打开和定位，并可按工作空间设置目标目录。

### 新增功能

- 新增下载取消，以及失败或取消任务沿用原记录 ID 重试。
- 新增打开下载文件、在 Finder 中显示和删除下载记录。
- 新增工作空间级下载目录书签；未配置时继续显示 CEF 系统保存对话框。
- 下载记录新增本地目标路径和 CEF 中断原因，并支持未知总大小状态。

### 行为变化

- 自定义目录中的同名文件自动追加序号，不覆盖已有文件。
- 隐私窗口显示本次运行的下载状态，但继续禁止写入普通下载资料库。
- 启动阶段 SQLite 历史、收藏、下载与权限记录改为和实时状态合并，实时状态优先。

### 测试情况

- Swift Testing 回归扩展到 39 项，覆盖旧记录解码、取消/重试命令、工作空间目录及下载记录删除。
- CEF Objective-C++ 桥和完整 Xcode arm64 Debug 构建通过。

### 已知问题

- v0.5.0 及更早的下载记录没有本地路径，升级后不能直接打开或在 Finder 中显示。
- 原生文件选择、JavaScript 对话框、全屏、页面安全详情、崩溃恢复界面和设置中心仍在 v0.5.x。
- CEF 只规划受控扩展子集；Developer ID 签名、公证与自动更新仍属于正式发布阶段。

## v0.5.0-beta.1 — 2026-07-23

### 版本摘要

完成 Rex MVP 的隐私网络层、站点权限、隔离隐私窗口，并补齐高频 Chrome 标签、快捷键和网页操作。

### 新增功能

- 新增 HTTPS 升级、追踪参数清理、广告/追踪资源拦截和第三方 Cookie 阻止。
- 新增按 profile、顶层来源、请求来源和权限类型保存决定的权限中心。
- 新增独立内存 `CefRequestContext` 隐私窗口，不恢复或写入普通会话资料。
- 新增恢复关闭标签、复制标签、静音、favicon、音频状态、打印和网页弹窗转 Rex 标签。
- 新增 `⌘1…9` 标签直达、`⌃1…9` 工作空间直达及分屏焦点、交换、方向快捷键。

### 测试情况

- 完整 Xcode arm64 Debug 构建与隐私/权限相关回归通过。


## v0.4.0-alpha.1 — 2026-07-23

### 版本摘要

完成四向拖放分屏、分屏组合保存/恢复，以及稳定的双页面 CEF 宿主布局。

### 新增功能

- 标签拖放到网页四边创建左右/上下分屏。
- 分屏比例拖动、交换、方向切换与组合保存。
- 分屏会话随窗口/工作空间持久化并恢复。

### 测试情况

- 完整 Xcode arm64 Debug 构建与分屏 UI 冒烟通过。

## v0.3.0-alpha.1 — 2026-07-23

### 版本摘要

完成工作空间、标签分组、收藏/固定/归档与 SQLite 会话持久化。

### 新增功能

- 多工作空间切换与标签组织。
- SQLite 会话、历史与基础资料库持久化。
- 标签搜索与侧栏信息架构收敛。

## v0.2.0-alpha.1 — 2026-07-23

### 版本摘要

完成 CEF/Chromium ARM64 最小集成：下载锁文件、Helper、framework 嵌入与真实页面导航。

### 新增功能

- CEF 150 / Chromium 150 arm64 runtime 固定与校验。
- Objective-C++ 桥、外部消息泵与多进程 Helper。
- 多标签页面事件与会话保存。

### 产物

- `Dist/Rex-v0.2.0-alpha.1-macos-arm64.zip`

## v0.1.0-alpha.1 — 2026-07-23

### 版本摘要

完成 Rex 原生产品外壳、领域模型与版本体系的可运行原型。
