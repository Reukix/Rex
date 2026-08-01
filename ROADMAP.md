# Rex 路线图

最后更新：2026-07-30

## 已完成 — v0.1.0-alpha.1

- ✅ 产品、交互、技术、安全和交付基线。
- ✅ 可运行 SwiftUI 主窗口与液态玻璃组件。
- ✅ 垂直标签、空间、分屏与隐私盾牌交互原型。
- ✅ 版本功能数据和构建门禁。

## 已完成 — v0.2.0-alpha.1

- ✅ 固定并校验 CEF 150 / Chromium 150 Apple Silicon 运行时。
- ✅ 编译 CEF wrapper、Objective-C++ facade 和五类 Chromium sandbox Helper。
- ✅ 接入页面加载、导航、标题、进度和 renderer 崩溃事件。
- ✅ 加入空间、标签和分屏会话 JSON 持久化。
- ✅ 完整 Xcode arm64 Debug/Release 构建、CEF 页面启动、多进程与优雅退出测试。
- 🚧 Developer ID 签名、公证与自动更新留待正式发布阶段。

## 已完成 — v0.3.0-alpha.1

- ✅ 标签/空间 SQLite 持久化、分组、固定、搜索、休眠和归档。
- ✅ 历史、收藏、下载基础能力和多窗口会话恢复。
- ✅ Swift 单元测试在完整 Xcode 工具链中运行通过（10 个测试，0 个失败）。

## 已完成 — v0.4.0-alpha.1

- ✅ 生产级左右/上下分屏、四向拖放和边缘热区预览。
- ✅ 页面交换、焦点管理、比例调整和分屏方向切换。
- ✅ 跨空间拖放、分屏标签保护及命名组合保存/恢复。
- ✅ 分屏导航、缩放、媒体保护和浏览器页面实例复用测试（20 个 Swift 测试，0 个失败）。

## 已完成 — v0.5.0-beta.1

- ✅ 地址导航的 HTTPS 升级和已知追踪参数清理，统计接入隐私盾牌。
- ✅ 基础广告/追踪资源拦截、第三方 Cookie 阻止和站点资源隐私报告。
- ✅ Chromium 原生右键菜单、Cocoa 事件作用域和 Chrome 风格浏览快捷键。
- ✅ 权限中心：按 profile、顶层来源、请求来源和权限类型保存决定。
- ✅ 隔离隐私窗口：独立内存 RequestContext，不恢复或写入普通会话资料。
- ✅ Chrome 基础标签能力：恢复关闭、复制、静音、favicon、音频状态和 `⌘1…9`。
- ✅ Chrome 基础网页能力：打印、页面弹窗转 Rex 标签页和原生下载回调。

## 已完成 — v0.5.1-beta.1

- ✅ 下载任务取消与失败/取消任务原 ID 重试。
- ✅ 保存 CEF 下载本地路径与中断原因，支持打开文件和在 Finder 中显示。
- ✅ 按工作空间保存安全作用域下载目录；未配置时继续使用 CEF 系统保存对话框。
- ✅ 下载记录删除、未知总大小进度状态和旧记录兼容。
- ✅ 修复启动阶段实时资料库与权限状态被 SQLite 历史记录覆盖的竞态。
- ✅ Swift 回归扩展到 39 项，完整 CEF/Xcode arm64 Debug 构建通过。

## 已完成 — v0.5.2-beta.1

- ✅ 先完成旧版 UI 基线测试，并建立主菜单、页面右键菜单和标签页菜单回归基线。
- ✅ Chrome 风格动态页面右键菜单：页面、链接、媒体、选中文本和可编辑区域使用不同命令组。
- ✅ 标签页右键菜单新增新建、重载、关闭其他标签页和关闭右侧标签页。
- ✅ Chrome 风格右上角主菜单：窗口、资料库、缩放、打印、查找、更多工具和设置。
- ✅ 原生设置中心：常规、搜索引擎、隐私与安全、下载内容、外观和关于 Rex。
- ✅ 默认搜索引擎可在 Google、Bing、DuckDuckGo、Brave Search 和 Ecosia 之间选择并持久化。
- ✅ Swift 回归扩展到 44 项，完整 CEF/Xcode arm64 Debug 构建与真实 UI 回归通过。

## 已完成 — v0.6.0-beta.1

- ✅ Brave 风格隐私功能层 v1.2：保护级别、广告/追踪/指纹/社交组件与可疑脚本拦截，盾牌策略下发。
- ✅ Thorium 风格性能参数 v1.2：GPU raster、Canvas OOP、QUIC、raster threads、进程策略（默认关闭 zero-copy/RawDraw）。
- ✅ 仅保留 CEF 150 同版本 Chromium DevTools 前端与 Swift 液态玻璃停靠宿主。
- ✅ 功能层已移除；仅保留 Thorium 性能层与 Chrome 风格 DevTools。
- ✅ 完整 Chromium 包 v0.6.0-beta.1 build 601（arm64 Debug ZIP）。


## 已完成 — v0.7.0-beta.1

- ✅ EasyList 网络规则引擎：内置 EasyList / EasyPrivacy / EasyList China，支持例外规则、domain/类型/第三方约束与 $document 整页豁免。
- ✅ 设置「启用 EasyList 规则」开关，运行时即时生效；拦截统计回流隐私盾牌。
- ✅ 性能层 rex-thorium-hybrid-v1.3：自适应 raster 线程、Metal ANGLE、低内存备用渲染进程策略、指标监视器降频采样。
- ✅ 站点信息弹窗内证书 / 网站权限钻取详情页（证书链、PEM、权限修改）。
- ✅ SwiftUI 打磨：悬停态、浅色模式自适应描边、稳定 favicon 后备色、统一弹窗宽度。

## 已完成 — v0.8.0-beta.1

- ✅ 移除 EasyList 引擎与规则快照；隐私盾牌改用精选域名目录（标准模式默认包含第三方已知指纹服务，严格追加社交，自定义扩大第一方目录匹配并对第三方使用路径启发式）。
- ✅ 内容拦截开关更名「拦截广告与追踪器」，运行时即时生效。
- ✅ 仅保留左右分屏；旧上下分屏数据恢复时自动转为左右。
- ✅ 标签页右键菜单支持创建分屏、选择左右位置、替换页面、换侧和退出分屏；移除标签拖放投放区与网页蓝色选择框。

## 已完成 — v0.8.1（build 810）

- ✅ 历史记录支持按过去 1 小时、24 小时、7 天或所有时间永久删除，并保留确认步骤。
- ✅ 收藏库与下载空状态从资料库标题栏下方开始布局，消除过大的顶部留白。
- ✅ macOS 标题栏恢复为 50/44 pt 紧凑单卡：普通窗口从红黄绿按钮右侧开始，全屏时使用 8 pt 普通边距。
- ✅ 性能指标作为导航栏首项并保留点击详情入口；无控件区域保留给窗口拖动，不再增加装饰性内容。
- ✅ 点击性能指标可打开每标签页 CPU/内存详情；Rex 总量由 Darwin 进程树采样，网页指标来自 `CefTaskManager`；共享 renderer 可能产生不可相加的重复值，GPU/worker 不分摊到网页。
- ✅ 当前隐私盾牌文档与实际三层实现对齐：Swift 顶层 URL 策略、CEF 域名目录请求取消、profile 级第三方 Cookie 设置。

## 已完成 — v0.9.0（build 900）

- ✅ 新标签页的最近访问与收藏网站统一为等宽等高区域，问候区跟随当前搜索引擎图标。
- ✅ 收藏网站改为名称+网址表单录入，支持 HTTPS 默认规范化、重复检查、输入校验和键盘提交。
- ✅ 关于 Rex 从结构化发布数据展示版本、构建、Chromium/CEF、arm64、功能分组与已知限制；应用菜单中文化。
- ✅ Rex 扩展商店提供 6 个 Chrome Web Store 精选扩展、本地搜索/分类和官方页面入口。
- ✅ 本地扩展管理器完成 MV2/MV3 清单校验、本地化文本、图标、权限、安全复制/更新/回滚、缺失状态和安全移除；运行时不可用时不显示无效启用开关。
- ✅ `Dist` 改为只保留当前发布产物，历史构建信息继续保存在 CHANGELOG 和版本文档。

## 已完成 — v0.9.1（build 910）

- ✅ 重做版本与功能 UI：发布概览、运行环境、功能状态/分类筛选、已知限制和历史版本使用独立信息层级。
- ✅ CEF 供应链切换为 150.0.14 官方 standard ARM64 发行包，重新锁定官方 SHA-1 与本地 SHA-256。
- ✅ Chrome Web Store 精选条目支持一键直接安装，也可粘贴任意官方详情链接或扩展 ID。
- ✅ 商店 CRX2/CRX3 执行来源限制、下载大小限制、扩展 ID/签名验证、安全 ZIP 解包和受管更新。
- ✅ 扩展安装来源与商店 ID 持久化，界面展示下载、验证、解包、安装、失败和重试状态。
- ✅ 深浅色模式下浏览器面板、标签和分屏内容边界统一使用自适应描边层级。

## 已完成 — v0.9.2（build 920）

- ✅ Rex 提供通用扩展列表、小型面板与管理界面；扩展行支持整行点击，小型面板直接加载清单声明的静态 `default_popup`，真实包内页面对外使用 `rex-extension://`。
- ✅ Chrome Web Store CRX2/CRX3 下载、身份/签名验证、安全解包与 manifest 公钥身份复核已接入；本地 Manifest V2/V3 包继续使用受管副本。
- ✅ 当前启用包在启动时交给 Chromium 扩展运行时。最终 `Dist` 包的通用 MV3 黑盒探针连续两次 `8/8`，覆盖 service worker、content script、runtime messaging、`chrome.storage.local`、Chromium DNR、options 页面与静态 `default_popup`。
- ✅ 删除 Rex 自制扩展 DNR 与 AdGuard 专用执行路径；已验证的后台、内容脚本、消息、存储、DNR 和 options 页面均来自真实安装包。
- ✅ 安装、启用、停用和移除使用启动快照并明确要求重启；已加载包的移除延后到下次启动清理。
- ✅ 非广告 fixture 与已安装拦截扩展均从列表整行进入自身 popup，自动尺寸、service worker 消息和面板交互通过，无扩展专用代码；普通 Rex UI 无裁剪、负偏移或 Chrome 窗口覆盖。
- ✅ 未托管 Chrome extension popup/auxiliary window 的普通网页目标会转交 Rex，辅助窗口随后关闭。
- ✅ Swift Testing `128/128`、完整 CEF bridge 的 Xcode arm64 Debug/Release 构建、Release Validator、deep codesign、ZIP 解压、校验和与隔离 profile 重复启动通过。
- ✅ 主 App 与五个 Helper 均为 `0.9.2 / 920`、arm64 only；App 为 `342M`（`349776 KiB`），ZIP 为 `142,320,000` bytes（`du` 为 `144M`），SHA-256 为 `c815a492297dac404b0d323eb2b6a628b26d58a352bc02ff9a5760605c2a898c`。
- ✅ 删除 Rex 系统密码调用、`SystemPasswordsCoordinator` 与主可执行文件的 `AuthenticationServices` 依赖；打包门槛拒绝该主 executable 依赖或任何 `.systemextension`，并记录 `rex_password_integration=absent`。上游 CEF framework 仍保留自身链接。
- ⚠️ Rex 小型面板不触发 Chromium 原生 action popup；v0.9.5 已为静态 popup 补充来源网页的 active/currentWindow 查询上下文，完整 `activeTab` 权限、无 popup 的 `action.onClicked` 与动态 `action.setPopup` 仍不支持。
- 🚧 Developer ID 同团队签名、Hardened Runtime、公证与自动更新留待正式分发阶段。

## 已完成 — v0.9.3（build 930）

- ✅ 扩展小型面板等待 Chromium 首个有效内容尺寸后再显示，消除白色占位首帧和可见的二次尺寸跳变。
- ✅ 加载期间的自动尺寸在主文档完成时立即应用，移除固定 300 ms 延迟；同一窗口会话复用扩展上次确认尺寸。
- ✅ `chrome.tabs.create(chrome-extension://…)` 创建的包内设置页经应用边界转换为 `rex-extension://` 并进入 Rex 标签页。
- ✅ popup 先关闭时保留最近有效来源标签，保证后续扩展页面仍能正确路由。
- ✅ 应用与打包版本推进到 `0.9.3 / 930`。

## 已完成 — v0.9.4（build 940）

- ✅ 使用无监听端口的 `--remote-debugging-pipe` 对账 Chromium 扩展集合，安装、启用、停用、手动更新和移除无需重启。
- ✅ 冷启动恢复的 HTTP(S) 页面等待 extension-ready generation 后才首次导航，空集合也先清理陈旧注册；热变更只立即重载活跃普通页面，休眠页恢复时重载一次，隐私窗口排除。
- ✅ 同路径更新使用持久 replacement journal，Chromium ack 前退出会在下次启动恢复上一版本；扩展事务跨 `await` 全局串行。
- ✅ 修复 `chrome.tabs.create` 转交目标时临时 Chrome browser 与 Rex 标签重复发出主文档请求。
- ✅ 扩展包启动校验降为每包一次完整扫描，单次 manifest 解析只读取一次 locale 字典，下载进度约每 80 ms 发布一次。
- ✅ MV3 探针忽略隐藏 `about:blank` 扩展上下文，并以不刷新、不重复导航的首次文档作为冷启动验收对象。
- ✅ 应用与打包版本推进到 `0.9.4 / 940`。

## 已完成 — v0.9.5（build 952）

- ✅ 隐私盾牌复用 Safari 分支的按网站策略方式：profile/host 唯一保存，保护开关与级别同步所有同站标签，切换网站不污染空间默认值。
- ✅ 静态扩展 popup 获得最近来源 HTTP(S) 页面的 URL/标题查询上下文；这是 Rex 提供的受控 `active/currentWindow` 元数据，不等同于 Chromium 真实 tab ID、`activeTab` 授权或站点脚本访问。
- ✅ 工具栏扩展列表与 popup 改为独立 AppKit 浮窗，移除 CEF 远程视图上 SwiftUI `.popover` / `addChildWindow` 的崩溃路径。
- ✅ 版本推进到 `0.9.5 / 952`；Swift、CEF、Xcode Release 与安装包验证记录见发布说明。

## 历史基线 — v0.9.6（build 962）

- ✅ 普通 HTTP(S) 页面进入 Chromium 扩展运行时主链，扩展获得真实 tab/frame/document identity；扩展能力仍按 API 和样本分别记账。
- ✅ 扩展持久安装、generation 对账、导航屏障和失败放行形成 build 962 历史基线；产物数据只保留在 v0.9.6 发布说明中。
- ✅ iCloud Passwords 明确为平台受限：本地 ad-hoc Rex 不具备 Apple native host 所需的正式签名身份和 managed entitlement。

## 当前基线 — v0.9.7（build 970，本地 Beta）

- ✅ `rex://extensions` 改为 Rex SwiftUI/AppKit 自有管理界面；`chrome://extensions` 仅作为不可见、受控的 `chrome.developerPrivate` API 上下文。
- ✅ 网站访问使用“点击扩展时”“指定网站”“所有网站”三态；用户脚本与文件网址设置写入 Chromium 后立即读回，UI 只显示权威返回值。
- ✅ 冷启动复用 Chromium profile 的持久安装记录；回归拒绝重复 `runtime.onInstalled`、Tampermonkey onboarding 和安装成功页，并保持 storage identity。
- ✅ 停用扩展重新启用时由 Chromium 显式 reload，覆盖禁用期间及跨 Rex 重启的同版本 JS/CSS 更新；原生操作、最终注册状态与事务指纹快照必须同时有效才提交。
- ✅ 启动屏障释放后仍按标签隐藏临时 `about:blank`，直到真实恢复地址提交；Chromium 地址事件也不再被 SwiftUI surface 回写为同地址二次 reload。
- ✅ build 970 最终产物为 `Dist/Rex.app`（`343M` / `351160 KiB`）与 `Dist/Rex-v0.9.7-macos-arm64-chromium.zip`（`142,675,732` bytes，`148092 KiB` / `145M`），ZIP SHA-256 为 `a9882360ebe8850bf0bdeb6dc7c586ab80eccde96e26a4fa1f8deee94e3d8280`；未生成 DMG。
- ⚠️ 当前为个人团队 Apple Development 签名的本地 Beta。Developer ID、Hardened Runtime、公证、Gatekeeper、应用更新和回退全部未完成。

## 进行中 — v0.9.x

- ⏳ **当前最高优先级：扩展兼容矩阵继续收敛。** Rex 管理页路由、Chromium 配置读回和连续冷启动回归已经完成；下一步补齐 Tampermonkey 最小用户脚本端到端注入，并扩大带版本与包哈希的真实扩展样本。
- ⏳ 将 MV2/MV3、service worker、content script、runtime messaging、storage、DNR、`scripting`/`userScripts`、站点访问、action/current tab、options、native messaging 和其他 Chrome API 分项测试；每项只使用“已验证、部分支持、未通过、未验证、受限”结论。
- ⏳ iCloud Passwords 的包/权限已加载，且通用真实 tab/frame 消息链路已进入探针；但系统 manifest 只注册在 Chrome 专用目录，Apple helper 的 Parent Launch Constraints 要求获批的浏览器 managed entitlement 或名单内的 Bundle ID + Team ID，当前个人团队 Apple Development Rex 仍不满足。未完成 Apple 正式接入前保持受限，不复制/重签 helper 或伪装受支持浏览器。
- ✅ 签名隐私目录与 PSL 在线更新客户端：Ed25519、同源下载、原子安装、LKG、启动回退、降级拒绝与 kill switch；生产端点/公钥尚待发布配置。
- ⚠️ 完整 brave-core + Thorium 源码融合与自建 CEF 发行包。
- ⚠️ DevTools 左侧、底部与独立窗口停靠模式。

## 进行中 — v0.5.3-beta.1

- ⏳ 原生文件选择、JavaScript 对话框和全屏窗口体验。
- ⏳ 页面安全状态与 Renderer 崩溃恢复界面。
- ⏳ 下载信誉/内容校验与批量清理策略；普通传输继续由 Chromium 独占。
- ⚠️ Chromium 扩展运行时已接入，但不承诺每个 Chrome Web Store 扩展或所有 Chrome API 均兼容，也不提供 Google 账号同步。

## v0.9.7 → v1.0.0

- **v0.9.7 build 970：** Rex 扩展管理 UI、Chromium 权威配置读回与冷启动恢复的本地 Beta 基线；正式分发工作包仍未完成。
- **v0.9.7 正式分发门禁：** Developer ID、Hardened Runtime、公证、Gatekeeper、应用更新和回退；外部条件不足时保持阻塞，不把 ad-hoc 包改称正式候选。
- **v0.9.8 build 985：** Chromium 下载生命周期与 Rex 右侧 UI 映射、下载旧快照清理与批量记录删除、侧栏持久收藏与收窄收藏/固定分区、GitHub release 崩溃修复、工具栏浮层独立 NSPanel、签名隐私目录/PSL 更新客户端、策略迁移、四类供应链边界、Cookie/统计语义和“当前不提供恶意网站检测”决策已完成；生产更新配置和正式分发仍受外部门禁阻塞。
- **v0.9.9：** 文件选择、JavaScript 对话框、全屏、Renderer 恢复、默认浏览器、无障碍、诊断、扩展自动更新与更广样本回归。
- **v1.0.0：** 功能冻结后的 RC 全矩阵、压力与恢复演练、安全审计和稳定发布。

详细工作包、交付物和逐版退出条件见 [v0.9.7 至 v1.0.0 逐版本工作计划](Documentation/VersionPlan.md)。
