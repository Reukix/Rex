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
- 扩展事务恢复：同路径更新在 Chromium ack 前重建 store 时自动恢复旧包；阻塞一次 runtime sync 后并发停用与删除仍严格串行。
- 扩展包性能：启动时每包只完整扫描一次，启停只更新内存状态；单次 manifest 解析只读取一次 locale 消息字典。
- 下载进度发布：进行中事件约按 80 ms 合并，完成、取消和失败终态立即发布。
- MV3 黑盒探针：严格筛选 Rex 网页 target，忽略隐藏 `about:blank` 扩展上下文；在不刷新、不重复 `Page.navigate` 的首次文档上覆盖 service worker、content script、runtime messaging、`chrome.storage.local`、Chromium DNR、options、静态 `default_popup` 与完整热生命周期。
- Release Notes JSON/Markdown 版本一致性。

## UI 自动化

建立带稳定 accessibility identifier 的测试：新建/关闭/恢复标签、空间切换、键盘聚焦地址栏、左右分屏、标签右键菜单、拖动比例、交换页面、隐私盾牌、降低透明度和完整键盘遍历。扩展 UI 覆盖通用列表、整行点击、小型面板、`rex-extension` 路由恢复、真实 options 页面、热安装/启停/更新/移除状态，以及清单静态 `default_popup` 资源在小型面板中的直接加载。热变更完成后，活跃普通 HTTP(S) 页面应立即重载一次，休眠页面应在恢复时只重载一次，隐私窗口不应重载；`chrome.tabs.create` 转交不得产生临时 browser 与 Rex 标签的双文档请求。最终 UI 冒烟必须确认 Rex 没有显示 Chrome 标签栏、地址栏或扩展管理页，同时 `default_popup`/options 内容确实来自已安装包，并验证在 `rex-extension` 页再次点击扩展按钮不会崩溃、面板的 `chrome.tabs.query({active:true,currentWindow:true})` 返回最近来源网页。使用 uBlock Origin Lite/AdGuard 与至少一个非拦截扩展走同一通用路径，不为受测扩展增加专用业务行为；商店在线下载另设显式网络集成验证。该结果仅表示静态 popup 获得受控的来源标签查询语义，不代表 Chromium 原生 action popup 或完整 `activeTab` 权限已经可用。

## 兼容性矩阵

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
| 1.0 | 稳定发布 | 阻断问题清零，发布清单全绿 |

## 主要风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| CEF/Chromium 高频升级 | 安全补丁与回归成本高 | 固定稳定分支、自动构建与站点回归套件 |
| SwiftUI 与 NSView 生命周期错配 | 闪白、焦点丢失、崩溃 | AppKit 拥有稳定 host，SwiftUI 只做布局 |
| App Sandbox/商店政策 | 无法上架或能力受限 | 早期 entitlement 验证，Developer ID 为主通道 |
| 隐私规则破坏站点 | 登录/支付失败 | 标准默认、站点例外、可解释报告和兼容反馈 |
| 双页资源占用 | 内存、电池压力 | 可见页优先级、后台休眠、指标与压力测试 |
| 扩展兼容范围 | 用户预期落差 | 区分 Rex 产品外壳与 Chromium 原生执行；公布已验证 API 和受测扩展，不把核心探针通过宣传为全商店兼容 |

## 发布门禁

本地 Beta 构建必须先通过 `RexReleaseValidator`：应用版本、功能数据和最新发布数据一致；功能 ID 唯一；状态值有效；当前版本详情页存在。之后执行单元测试、CEF arm64 构建和 `Scripts/verify-mv3-extension-runtime.mjs`：探针必须排除隐藏 `about:blank` 上下文，并在不刷新、不重复导航的首次文档上覆盖冷启动与热安装/启停/更新/移除；再完成 AdGuard 与至少一个非拦截扩展的通用 UI 冒烟、无调试监听端口检查和验包。只有实际命令成功后才能把对应探针和版本验收写成已通过；最终构建完成后才可在 CHANGELOG 与版本详情页回填 ZIP 字节数、App/ZIP 占用和 SHA-256，不得使用旧包数据。正式外部分发还必须通过 Developer ID 签名、公证和更新回退演练。
