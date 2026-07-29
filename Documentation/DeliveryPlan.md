# 测试与交付计划

## 单元测试

- 模型 Codable 往返与旧版本迁移。
- URL 输入规范化、危险 scheme 拒绝和搜索回退。
- 标签创建/关闭/固定/归档状态机。
- 空间切换和跨空间移动。
- 左右分屏创建、标签菜单放置/替换、比例边界、交换、旧方向迁移和恢复。
- 隐私规则优先级、按 profile/host 的 Safari 式站点策略持久化、同站标签同步与权限过期。
- 历史删除时间边界：过去 1 小时、24 小时、7 天的 cutoff 包含边界，所有时间清空。
- 标题栏红黄绿按钮净空计算，以及全屏普通边距回退。
- Chrome Web Store URL/ID 解析、下载主机限制、CRX 身份/签名验证、安全解包和受管安装事务。
- 商店扩展启动身份复核：manifest 公钥推导的 runtime ID 必须与验签 store ID 一致。
- 扩展热生命周期：安装、启用、停用、手动更新和移除分别生成串行 generation，并在 Chromium 的实际启用路径与预期受管集合一致后完成。
- 扩展冷启动屏障：恢复的 HTTP(S) 标签在 extension-ready generation 前不发出目标请求；预期集合为空时也完成一次精确清理，不让 profile 中的陈旧受管扩展越过屏障。
- 扩展冷启动恢复：已存在于 Chromium profile 的持久安装记录只做集合对账，不重复执行首次安装；连续启动不得再次触发 `runtime.onInstalled`、onboarding 或安装成功页，`chrome.storage.local` 持久身份保持不变。
- 扩展事务恢复：同路径更新在 Chromium ack 前重建 store 时自动恢复旧包；阻塞一次 runtime sync 后并发停用与删除仍严格串行。
- 扩展包性能：启动时每包只完整扫描一次，启停只更新内存状态；单次 manifest 解析只读取一次 locale 消息字典。
- 下载进度发布：进行中事件约按 80 ms 合并，完成、取消和失败终态立即发布。
- MV3 黑盒探针：严格筛选 Rex 网页 target，忽略隐藏 `about:blank` 扩展上下文；在不刷新、不重复 `Page.navigate` 的首次文档上覆盖 service worker、静态 content script/host permission、双向 runtime messaging、定向 `tabs.sendMessage`、真实 sender tab/frame、`chrome.storage.local`、Chromium DNR、options、静态 `default_popup` 与完整热生命周期。该探针不覆盖完整 `activeTab`、`webNavigation` frame、`scripting`、`userScripts`、可选站点访问或 native messaging，发布结果不得外推。
- 扩展权限探针：分别覆盖静态/可选 host permission、允许/撤销/重启、跨来源导航、`activeTab`、`tabs.sendMessage`、`webNavigation.getAllFrames`、`scripting` 和 `userScripts`，并让 UI 状态与网页内真实注入/通信结果逐项对账。
- 扩展管理路由与配置：`rex://extensions` 列表、详情、返回和无效 ID 均由 Rex 状态驱动，不发送 Chromium 可见导航；网站访问覆盖 `ON_CLICK`、`ON_SPECIFIC_SITES`、`ON_ALL_SITES`，用户脚本与文件网址开关覆盖写入、即时读回、失败、重试和陈旧返回值，UI 必须以 Chromium 读回结果为准。
- native messaging 探针：先用可控测试 host 覆盖发现、握手、双向消息、host 缺失、拒绝、断线和退出；第三方私有 host 另做独立结果，不能由通用探针推断。
- Release Notes JSON/Markdown 版本一致性。

## UI 自动化

建立带稳定 accessibility identifier 的测试：新建/关闭/恢复标签、空间切换、键盘聚焦地址栏、左右分屏、标签右键菜单、拖动比例、交换页面、隐私盾牌、降低透明度和完整键盘遍历。扩展 UI 覆盖 Rex 自有的 `rex://extensions` 列表、详情、返回、安装、启停、移除、选项入口和无效路由，确认内部页切换不触发 Chromium 页面导航；`chrome://extensions` 只能存在于不可见的受控 API 上下文，任何 Chrome 标签栏、地址栏或原生管理 WebUI 出现都视为失败。网站访问三态、用户脚本和文件网址开关必须逐项验证“写入 Chromium -> 读回 Chromium -> UI 更新”，并覆盖拒绝、超时、重试和读回值不同于目标值的场景。热变更完成后，活跃普通 HTTP(S) 页面应立即重载一次，休眠页面应在恢复时只重载一次，隐私窗口不应重载；冷启动不得重复触发扩展 onboarding 或安装成功页。`chrome.tabs.create` 转交不得产生临时 browser 与 Rex 标签的双文档请求。Tampermonkey 必须以最小用户脚本验证“允许用户脚本 + 所有网站”的授权、撤销和重启行为；uBlock Origin Lite/AdGuard 与至少一个非拦截扩展走同一通用路径，不为受测扩展增加专用业务行为。商店在线下载另设显式网络集成验证。静态 popup 只允许 Rex 传递 tab identity，URL/标题必须来自 Chromium 权限裁剪后的 `tabs.get`；无 `tabs` 或匹配 host permission 的样本必须看不到敏感字段。真实 tab ID、消息和注入探针未同时通过时，不得宣称 Chromium 原生 action popup 或完整 `activeTab` 可用。

## 扩展兼容性矩阵

每个候选包保存 CEF/Chromium、macOS、扩展/夹具版本和包哈希。状态只使用“已验证、部分支持、未通过、未验证、受限”；API 探针和真实扩展样本分别记账。

| 能力/样本 | 当前基线 | 候选包必须验证 |
|---|---|---|
| service worker、runtime messaging、`storage.local` | 已验证 | 首次文档、重启和热更新无回归 |
| Manifest V2 执行 | 未验证 | 加入代表样本，或在 UI/发布说明中明确当前只保证已测 MV3 子集 |
| 静态 content script/host permission、静态 DNR | 部分支持 | 扩大到授权/撤销、不同来源；动态/会话规则不得由静态结果外推 |
| options、包内页面、静态 `default_popup` | 部分支持 | 路由、尺寸、焦点、多窗口和来源页关闭/切换 |
| Rex `rex://extensions` 管理界面 | 测试中 | 列表/详情/返回/操作均由 Rex 呈现且不触发 Chromium 可见导航；隐藏 `chrome://extensions` 只用于 API |
| 网站访问三态、用户脚本与文件网址配置 | 测试中 | 三态及两个开关均完成 Chromium 写入和即时读回；失败时不乐观更新 UI |
| `activeTab`、`tabs.sendMessage`、`webNavigation` frame、`scripting`、`userScripts`、运行时站点访问 | 部分支持 | API 探针与 Tampermonkey 最小用户脚本同时通过，或准确固定受限项 |
| action 无 popup/动态 popup | 受限 | 有时限验证；不可实现时安装、管理和发布说明均可见 |
| native messaging | 未通过 | 通用测试 host 独立通过后才能改变状态 |
| iCloud Passwords | 受限 | 包/权限已加载；系统 manifest 只注册在 Chrome 专用目录，Apple helper 的 Parent Launch Constraints 要求获批的 managed entitlement 或名单内 Bundle ID + Team ID，当前 ad-hoc Rex 均不满足；UI 必须区分包 ready/host unavailable，只接受原始 helper 的端到端结果，不复制/重签 helper 或伪装宿主 |
| uBlock Origin Lite | 部分支持 | 只记录实测 DNR/popup 子集，不外推整个扩展 |
| Tampermonkey | 未通过 | 用户脚本/所有网站、撤销与重启场景 |
| 其他未覆盖 Chrome API/表面 | 未验证 | `bookmarks`、`history`、`downloads`、`cookies`、`webRequest`、菜单/命令/通知、`identity`、DevTools、side panel、offscreen、theme 按类别逐项加入 |

## 系统与显示兼容性矩阵

覆盖 macOS 14/15/26/27 的 Apple Silicon 设备，以及浅/深色、高对比、降低透明度、减少动态效果、多显示器和 60/120 Hz。Intel 架构明确不受支持，也不进入测试矩阵。

## 阶段计划

| 里程碑 | 目标 | 退出条件 |
|---|---|---|
| 0.1 alpha | 产品外壳、模型、版本体系 | 可编译运行，核心 UI 可操作 |
| 0.2 alpha | CEF 最小集成、导航、多标签 | renderer 隔离，崩溃不退出主进程 |
| 0.3 alpha | 空间、分组、持久化 | 会话恢复与迁移测试通过 |
| 0.4 alpha | 双页面分屏 | resize 不重建页面，状态恢复通过 |
| 0.5 beta | 基础隐私、权限、隐私窗口 | 安全评审与站点兼容测试通过 |
| 0.8 beta | 域名目录隐私盾牌、仅左右分屏与标签菜单操作 | Swift 测试与完整 CEF arm64 Debug 打包通过 |
| 0.8.1 | 资料库历史清理与原生标题栏布局 | 四档历史删除、空状态布局和窗口按钮净空回归通过 |
| 0.9 | 新标签页、版本信息与扩展发现 | 收藏表单、中文菜单、功能数据与扩展边界回归通过 |
| 0.9.2 | Rex 扩展外壳与 Chromium 扩展运行时 | 核心 MV3 探针、静态 `default_popup` 资源直载、通用双扩展 UI、重启生命周期和无 Chrome 浏览器 UI 回归通过 |
| 0.9.4 | 扩展热生命周期、冷启动就绪屏障与性能收敛 | 首次文档和热生命周期探针、单次包扫描、下载进度节流及无调试监听端口检查通过 |
| 0.9.5 | Safari 式网站隐私策略与扩展面板稳定性 | 站点策略持久化/同步测试、来源标签上下文探针、CEF 浮窗回归及 Release 打包通过 |
| 0.9.6 | 扩展运行时与启动恢复历史基线 | Chromium 执行主链和持久安装恢复进入历史发布记录 |
| 0.9.7 build 970 | Rex 扩展管理架构本地 Beta | Rex 可见管理 UI、Chromium 权威配置读回和冷启动不重复 onboarding 通过；Developer ID 正式分发仍未完成 |
| 0.9.8 | 安全与隐私基线 | 签名目录更新、PSL、危险下载、隐私落盘和供应链边界验证通过 |
| 0.9.9 | 基础浏览与扩展交付收敛 | 浏览阻断问题清零，扩展自动更新与更广样本回归通过，进入功能冻结 |
| 1.0.0 | RC 与稳定发布 | 全矩阵、压力、恢复、安全审计和发布清单全绿 |

## 主要风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| CEF/Chromium 高频升级 | 安全补丁与回归成本高 | 固定稳定分支、自动构建与站点回归套件 |
| SwiftUI 与 NSView 生命周期错配 | 闪白、焦点丢失、崩溃 | AppKit 拥有稳定 host，SwiftUI 只做布局 |
| App Sandbox/商店政策 | 无法上架或能力受限 | 早期 entitlement 验证，Developer ID 为主通道 |
| 隐私规则破坏站点 | 登录/支付失败 | 标准默认、站点例外、可解释报告和兼容反馈 |
| 双页资源占用 | 内存、电池压力 | 可见页优先级、后台休眠、指标与压力测试 |
| 扩展兼容范围 | 权限 UI 显示已开启但网页仍不可用，或用户误以为全商店兼容 | 区分 Rex 元数据桥、Chromium 真实 tab/权限与第三方 native host；公布逐 API 和逐样本结果，不把核心探针通过宣传为全商店兼容 |

## 发布门禁

build 970 本地 Beta 已通过 `RexReleaseValidator`、Swift 单元测试、CEF arm64 Release、完整 Xcode Release、MV3 verifier 自测、Rex `rex://extensions` 实机界面和最终 ZIP 验包。探针持续覆盖首次文档、连续冷启动不重复 `runtime.onInstalled`/onboarding、持久 storage identity，以及热安装/启停/更新/移除；Tampermonkey 最小用户脚本注入与更多真实扩展样本仍是后续兼容性门禁。`chrome://extensions` 必须保持不可见。native messaging/iCloud 保留受限结论，当前 ad-hoc ZIP 缺 Apple managed entitlement 和 Developer ID，不得把 iCloud 标为已生效。build 970 只交付 ZIP，不生成 DMG；最终 App 为 `343M` / `351344 KiB`，ZIP 为 `142,723,427` bytes（`147740 KiB` / `144M`），SHA-256 为 `0940bab0c6541b39b85a26668096dfbd738ae1dc5c62360a8a5a0ab7f45480f3`。Developer ID、Hardened Runtime、公证、Gatekeeper、应用更新和回退仍是未完成的正式分发门禁。
