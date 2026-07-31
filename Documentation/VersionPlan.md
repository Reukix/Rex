# Rex v0.9.7 至 v1.0.0 版本工作计划

最后更新：2026-07-30
实施基线：v0.9.7（build 970，本地 Beta）
上位计划：[Rex v1.0 未来实施计划](FuturePlan.md)

本文把 `FuturePlan.md` 的 M0-M5 里程碑落实到具体版本。版本号表示完成门禁后的交付节点，不代替问题关闭；若某一版本的退出条件未满足，后续版本不得用改号方式绕过。

## 1. 版本总览

| 版本 | 对应里程碑 | 核心目标 | 版本结束状态 |
|---|---|---|---|
| v0.9.6 | M0 + M1 历史阶段 | 扩展运行时与启动恢复基线 | 历史记录保留；可见扩展管理架构已由 v0.9.7 取代 |
| v0.9.7 | M1 收口 + M2 未完成 | build 970 Rex 管理 UI/Chromium 权威状态本地 Beta；继续推进正式分发 | 当前仅为 ad-hoc 本地 Beta；正式结束仍要求可公证、可通过 Gatekeeper、可更新和回退 |
| v0.9.8 | M3 | 安全与隐私基线 | 规则、站点归属、下载和隐私语义达到稳定版标准 |
| v0.9.9 | M4 | 基础浏览与扩展交付收敛 | 自动更新和更广样本回归完成，进入 v1.0 功能冻结 |
| v1.0.0 | M5 | RC 验证与稳定发布 | 发布矩阵、稳定性门槛和最终门禁全部通过 |

依赖关系：`v0.9.7 build 970 本地 Beta -> v0.9.7 正式分发门禁 -> v0.9.8 -> v0.9.9 -> v1.0.0`。扩展站点访问、用户脚本、文件网址、action/current tab、native messaging 边界及冷启动恢复仍是 build 970 的优先收口项；Developer ID、Hardened Runtime、公证、Gatekeeper、应用更新和回退未完成前，v0.9.7 不得被描述为正式分发候选。

## 2. 全版本执行规则

- 每个工作包同时交付代码、自动化测试、实机记录、用户可见文案和发布数据。
- 计划工作包状态只使用“未开始、进行中、已验证、接受限制”；“已实现但未验证”仍视为进行中。扩展能力矩阵另用“已验证、部分支持、未通过、未验证、受限”。
- 新增流程必须定义成功、失败、取消、超时、重试、退出和崩溃恢复语义。
- 修改磁盘包、会话、扩展、更新或隐私数据时，必须加入强制终止后的恢复测试。
- 每个候选包从干净目录构建；版本、构建号、体积、签名和 SHA-256 只能从最终产物回填。
- v0.9.9 结束时冻结功能；v1.0.0 只接受发布阻断、安全问题和确认的高优先级回归修复。
- Intel、Google 账号同步、Rex 自有系统密码/Keychain 集成、AI 功能和 M6 增强不进入本轮版本范围；第三方扩展的 native messaging 兼容性继续单独给出真实结论。

## 3. v0.9.6：历史扩展与启动基线

### 版本目标

本节保留 v0.9.6 的历史工作包和 build 962 候选记录。其 Chromium 扩展运行时、导航屏障和持久安装恢复仍是后续基础；可见扩展管理页方案已在 v0.9.7 改为 Rex SwiftUI/AppKit，不再把 Chromium 原生页面坐标作为当前目标。

### 工作包

| ID | 工作 | 完成标准 |
|---|---|---|
| V096-BASE-01 | 修正文档与结构化能力数据偏差 | README、FEATURES、架构、安全文档、功能数据和源码口径一致，发布校验可拒绝关键不一致 |
| V096-BASE-02 | 保存 v0.9.5 启动与资源基线 | 记录环境、命令、首个网页导航时间、扩展 generation、恢复窗口数、进程数和典型资源数据 |
| V096-EXT-01 | 发布版本化扩展能力矩阵 | API 与真实样本分开记录版本/哈希、环境、结果和限制，只使用已验证、部分支持、未通过、未验证、受限 |
| V096-EXT-02 | 历史原生管理页实验 | build 962 的子窗口命中实验仅作为历史记录；v0.9.7 已由 Rex 自有管理 UI 取代 |
| V096-EXT-03 | 修复站点访问与用户脚本 | 静态/可选 host permission、`activeTab`、`tabs.sendMessage`、`webNavigation` frame、`scripting`/`userScripts` 有授权、撤销、导航、重启探针；Tampermonkey 最小脚本通过 |
| V096-EXT-04 | 冻结 action/current tab 边界 | URL/标题元数据、真实 tab ID 与权限授予分开建模；静态 popup 回归通过，不可实现的 action API 有准确用户可见限制 |
| V096-EXT-05 | 验证 native messaging 与 iCloud 边界 | 通用测试 host 给出端到端结论并区分包加载/host 可用；只安装经校验的 Apple 系统 manifest，不复制 helper；无 managed entitlement/Developer ID 或真实 tab/frame 链路时明确受限 |
| V096-START-01 | 建立 `reconciling`、`ready`、`degraded` 状态机 | generation、开始时间、实际集合、失败原因和最终状态可诊断 |
| V096-START-02 | 给导航屏障设置可测试 deadline | pipe 初始化失败、无回复和事务挂起都能超时、取消并释放 pending URL |
| V096-START-03 | 固化空集合与成功语义 | 空集合会清理旧注册；ready 只在实际集合与预期集合一致时成立 |
| V096-START-04 | 增加失败状态和主动重试 | 用户可看到扩展错误并重试；补偿成功后每个活跃普通网页最多重载一次 |
| V096-START-05 | 加固事务与窗口恢复 | replacement journal、连续 generation、多窗口、关窗、退出和强制终止路径可恢复 |

### build 962 候选状态

- Chromium 导航加载、进度、前进后退与刷新/停止已收敛为单一事实来源；Rex 保留现有 UI，仅映射 Chromium 的实时状态。导航代次回归覆盖旧终态隔离和重定向完成，不再用 URL 完全相等猜测加载是否结束。
- `V096-EXT-02`：build 962 曾构建 Chromium 子窗口绘制/点击坐标修复；该方案未作为当前架构继续验收，v0.9.7 改由 Rex 自有管理 UI 承担全部可见交互。
- `V096-EXT-03`：普通非隐私 HTTP(S) 页面已使用 Chrome runtime，真实 sender tab/frame 与定向 `tabs.sendMessage` 已进入探针；Tampermonkey 最小脚本的注入、撤销和重启仍未实测，保持最高优先级。
- `V096-EXT-04`：静态 popup 以 CEF 真实 `tabId` 精确匹配来源，重复 URL/标题不再误选。完整 `activeTab`、原生 action 和 `tabs.create` 临时返回 ID 的后续可用性接受限制，不以模拟 ID 替代原 WebContents 接管。
- `V096-EXT-05`：iCloud Passwords 的扩展包加载与 Apple native host 可用性已分开呈现；当前 ad-hoc 包缺 Developer ID、managed entitlement 与 helper 名单身份，结论为“接受限制”。
- 最终 ZIP 已完成 Xcode Release、arm64、版本、解压、deep/strict codesign 和 SHA-256 验包；GUI 与本地 listener 门禁未通过前，不把 v0.9.6 工作包整体标记为“已验证”。

### 必须交付

- 扩展能力矩阵、固定测试包/哈希、API 探针结果和真实样本报告。
- Tampermonkey 授权/撤销/重启的实机记录；可见管理页的后续门禁转入 v0.9.7 Rex UI 与 Chromium 权威读回。
- action/current tab capability 结论和 native messaging/iCloud 支持或受限结论；本地 ad-hoc ZIP 不得把 iCloud 标记为已生效。
- 启动状态机和故障注入测试套件。
- 空集合、损坏扩展、pipe 失败/无回复、补偿成功、多窗口和隐私窗口测试记录。
- 可诊断的扩展 degraded 状态及重试入口。
- v0.9.6 Apple Silicon 预发布 App、ZIP、构建清单和 SHA-256；本次不生成 DMG。

### 退出门禁

- v0.9.6 历史运行时行为和限制有可重复记录；当前可见管理 UI 不再沿用该坐标方案。
- Tampermonkey 在受支持 HTTP(S) 页面通过“允许用户脚本 + 所有网站”最小注入用例，撤销后停止；失败时不得把 UI 开关状态写成已生效。
- 受控来源元数据不再被误报为真实 `activeTab`；扩展包 ready 不再误报为 native host ready；action 和 native messaging/iCloud 的支持或受限结论均有可重复证据。
- 任一扩展启动故障都不能让普通网页无限期停在 `about:blank`。
- ready 路径首次文档无需刷新即可通过 content script 与 DNR 探针。
- degraded 路径保留具体错误，同时在 deadline 内释放所有待导航页面。
- 连续 generation 和故障恢复不产生重复导航、重复重载、孤立窗口或遗留异步任务。
- M0 文档/能力数据偏差关闭，后续问题均可追溯到一个版本工作包。

## 4. v0.9.7：本地 Beta 架构基线与未完成的正式分发

### 版本目标

build 970 先固定“Rex 可见外壳、Chromium 权威后端”的扩展管理架构，并以 ad-hoc ZIP 作为本地 Beta 基线。在此基础上继续建立 Developer ID 主分发链路，让 Rex 在带 quarantine 的新环境中无需手工绕过 Gatekeeper 即可安装、启动、更新并在失败时回退。后半部分仍未完成。

### build 970 本地 Beta 基线

- `rex://extensions` 的列表、详情、返回和管理操作由 Rex SwiftUI/AppKit 呈现；内部路由不向 Chromium 发起可见导航。
- `chrome://extensions` 只在不可见、受控的上下文中提供 `chrome.developerPrivate` API，绝不作为用户可见管理页面。
- 网站访问严格映射 `ON_CLICK`、`ON_SPECIFIC_SITES`、`ON_ALL_SITES`；用户脚本和文件网址设置写入 Chromium 后立即读回，UI 只显示返回状态。
- 连续冷启动必须复用 Chromium profile 的持久安装记录，不重复触发 `runtime.onInstalled`、onboarding 或安装成功页，并保持 storage identity。
- build 970 仅交付本地 Beta ZIP，不生成 DMG；最终 App 为 `343M` / `351344 KiB`，ZIP 为 `142,723,427` bytes（`147740 KiB` / `144M`），SHA-256 为 `0940bab0c6541b39b85a26668096dfbd738ae1dc5c62360a8a5a0ab7f45480f3`，包清单见 `Dist/PACKAGE-INFO.txt`。
- iCloud Passwords native host、完整 Chrome 扩展 API 兼容、Developer ID、Hardened Runtime、公证、Gatekeeper、应用更新和回退均未完成或不承诺。

### 正式分发工作包状态

以下原 v0.9.7 分发工作包全部保持**未完成**；证书、Team ID、feed 和公证凭据等外部条件不足时状态为阻塞，不得用 build 970 的 ad-hoc 包替代验收。

### 前置外部条件

- Developer ID Application 证书、Team ID 和公证凭据可用。
- 正式 bundle ID、stable/beta feed 地址和更新签名密钥保管方式已确认。
- 发布机或 CI 能从干净环境重建固定的 CEF 150 依赖。

### 工作包

| ID | 工作 | 状态 | 完成标准 |
|---|---|---|---|
| V097-DIST-01 | 拆分 local/distribution 打包模式 | 未完成 | distribution 模式拒绝空 identity、关闭 Hardened Runtime 或 Team ID 不一致 |
| V097-DIST-02 | 审计签名和 entitlement | 未完成 | 主 App、CEF、动态库及五个 Helper 使用同一团队和最小 entitlement |
| V097-DIST-03 | 自动完成公证与装订 | 未完成/外部条件阻塞 | `notarytool` accepted，`stapler validate` 与 `spctl --assess` 通过 |
| V097-UPD-01 | 接入签名完整包更新 | 未完成 | 优先验证 Sparkle 2，支持 stable/beta、版本单调性、跳过版本和验签 |
| V097-UPD-02 | 建立失败恢复与回退 | 未完成 | 网络、验签、下载、安装和更新后启动失败都不破坏当前可用版本 |
| V097-SUPPLY-01 | 固化密钥和产物边界 | 未完成 | 私钥/token 不进入仓库，更新包、appcast 和回退包分别签名校验 |

### 必须交付

- Developer ID 签名、公证并装订的候选 App、ZIP/DMG。
- entitlement 审计记录和第三方许可/CEF 分发范围记录。
- stable/beta 更新 feed、签名完整包、回退包和演练日志。
- 干净安装、旧 Beta 升级、quarantine 首启和更新失败恢复报告。

### 退出门禁

- `codesign --verify --deep --strict`、公证、装订和 Gatekeeper 验证全部通过。
- 主 App、CEF 和全部 Helper 的版本、架构、Team ID、Hardened Runtime 状态一致。
- 旧签名 Beta 可以更新到候选版；损坏包或错误签名不会替换当前版本。
- 至少完成一次更新后启动失败的自动或可重复回退演练。

证书或 feed 等外部条件未满足时，v0.9.7 保持阻塞，不把 ad-hoc 包描述为正式分发候选。

## 5. v0.9.8：安全与隐私基线

### 版本目标

让隐私目录、站点归属、下载保护和隐私窗口落盘行为具有可审计、可更新、可回滚且与界面文案一致的安全边界。

### 工作包

| ID | 工作 | 完成标准 |
|---|---|---|
| V098-CATALOG-01 | 签名隐私目录在线更新 | 支持版本、大小限制、原子安装、last-known-good、回滚和 kill switch |
| V098-SITE-01 | 接入维护中的 PSL/eTLD+1 | 覆盖 ICANN/private suffix、IDN、localhost 和 IP，并有迁移测试 |
| V098-DL-01 | 收敛 Chromium 下载权威边界 | Chromium 独占请求、重定向、传输、落盘和生命周期；Rex 只映射右侧 UI |
| V098-PRIVATE-01 | 明确隐私窗口下载落盘 | 文件可落盘，但不写入普通历史和下载资料库；当前无额外确认 |
| V098-SEM-01 | 统一 Cookie 与隐私统计语义 | 应用级 Cookie 开关、当前文档或标签会话计数的 UI/存储/文档一致 |
| V098-THREAT-01 | 决定恶意网站检测边界 | 选定 provider/本地列表/明确不提供之一，并记录隐私、许可、延迟和离线行为 |
| V098-SUPPLY-01 | 审计四类供应链 | CRX、普通下载、隐私目录包和应用更新包使用各自明确的验证边界 |

### 必须交付

- 隐私目录更新服务、签名格式、回滚机制和故障注入测试。
- PSL 数据来源、版本、更新策略与站点策略迁移报告。
- Chromium 下载状态映射、隐私窗口记录隔离及对应自动化。
- 安全/隐私能力决策记录和准确的设置页、功能数据、README 文案。

### 退出门禁

- 过期、损坏、降级或错误签名的目录包被拒绝，离线继续使用最后有效版本。
- 站点归属不再依赖少量手写后缀，常见和边界域名测试通过。
- GitHub 重定向下载、取消和重试都保持 Chromium 单一生命周期，Rex 不暂停或重放。
- 产品不把当前指纹网络拦截描述为通用指纹随机化，也不暗示不存在的恶意网站检测。

## 6. v0.9.9：功能收敛与冻结

### 版本目标

完成稳定版必须具备的基础浏览流程、扩展自动更新和更广类别样本回归，并在版本结束时进入 v1.0 功能冻结；不得重新放宽 v0.9.6 已冻结的能力边界。

### 工作包

| ID | 工作 | 完成标准 |
|---|---|---|
| V099-BROWSE-01 | 完成原生文件选择 | 单文件、多文件、文件夹、取消、休眠保护和安全作用域访问通过 |
| V099-BROWSE-02 | 完成 JavaScript 对话框 | alert/confirm/prompt/beforeunload 的焦点、关闭和导航取消语义正确 |
| V099-BROWSE-03 | 完成网页全屏 | Escape、菜单栏/Dock、分屏冲突和多显示器恢复通过 |
| V099-RECOVER-01 | 收敛 Renderer 崩溃与页面安全状态 | 错误页、重载/关闭/恢复可用，证书/HTTP/HTTPS/混合内容状态不陈旧 |
| V099-SYSTEM-01 | 接入默认浏览器和窗口几何恢复 | 注册/检测失败可操作；窗口在显示器缺失时回到可见区域 |
| V099-DATA-01 | 解决两套收藏边界 | 合并或明确分离，新标签页和资料库的名称与数据语义一致 |
| V099-A11Y-01 | 收敛无障碍与电源行为 | 键盘、VoiceOver、减少动态/透明度通过；低电量监听真实存在或删除声明 |
| V099-DIAG-01 | 提供主动诊断导出 | 可预览、默认脱敏，不含历史、Cookie、表单、扩展私有数据和完整路径 |
| V099-EXT-01 | 扩大真实扩展样本矩阵 | 在 v0.9.6 API 基线上覆盖内容拦截、生产力、开发工具、主题/界面、内容增强和当前标签权限类别，不宣称全 Chrome 兼容 |
| V099-EXT-02 | 完成扩展自动更新 | 官方来源、CRX 验签、ID 复核、安全解包、generation 和 journal 回退通过 |

### 必须交付

- 基础浏览自动化与可重复实机用例集。
- 脱敏诊断包规范及敏感数据审查记录。
- 更新后的扩展样本矩阵和自动更新成功/失败/回滚报告。
- 功能冻结清单、v1.0 已知限制清单和 v0.9.9 候选包。

### 退出门禁

- 文件选择、JavaScript 对话框、全屏、Renderer 恢复、默认浏览器和无障碍达到稳定版门槛。
- 扩展自动更新覆盖成功、无更新、网络失败、签名失败、解包失败、运行时拒绝和崩溃恢复。
- 所有基础浏览阻断问题清零；保留的扩展限制已获产品确认并在用户可见位置说明。
- v1.0 功能列表冻结，未完成的 M6 增强从 v1.0 范围移除。

## 7. v1.0.0：RC 与稳定发布

### 版本目标

不再扩展功能，通过完整兼容、压力、恢复、安全和分发验证，把 v0.9.9 的冻结功能集交付为稳定版。

### RC 节奏

1. `v1.0.0-rc.1`：完成全矩阵首轮，关闭全部 P0，冻结性能阈值和支持范围。
2. `v1.0.0-rc.2`：只修复 rc.1 的发布阻断、安全问题和高优先级回归，重跑受影响矩阵及发布门禁。
3. 额外 RC：仅在 rc.2 仍有阻断问题时增加；每次都必须重新签名、公证、更新并验证回退。
4. `v1.0.0`：候选包二进制不再改变；只在完全相同的已验证产物上完成稳定通道发布。

### 工作包

| ID | 工作 | 完成标准 |
|---|---|---|
| V100-RC-01 | 执行系统和显示矩阵 | 支持的 Apple Silicon macOS、浅/深色、辅助显示设置、多显示器和刷新率通过 |
| V100-RC-02 | 执行会话和扩展矩阵 | 多窗口、强退/崩溃恢复、分屏、空/损坏扩展、更新和补偿 generation 通过 |
| V100-RC-03 | 执行网络、分发和隐私矩阵 | 代理/离线/TLS、quarantine、更新/回退、权限、Cookie、PSL 和危险下载通过 |
| V100-STAB-01 | 执行稳定性与压力门槛 | 启动循环、更新中断、4 小时混合负载和资源基线无未解释回退 |
| V100-REL-01 | 完成发布审计 | 安全、隐私、许可、CEF 版本、已知限制和全部文档签字完成 |
| V100-REL-02 | 发布稳定通道 | 最终 App、ZIP/DMG、appcast、哈希和发布说明引用同一已验证产物 |

### 最低稳定性门槛

- 连续 100 次带会话恢复的启动/退出无永久 `about:blank`、丢失窗口或重复首导航。
- 连续 25 次扩展更新中断/恢复后，磁盘包、Chromium 实际集合和 Rex 状态一致。
- 至少 10 次应用更新成功/失败/回退组合不损坏安装和用户资料。
- 至少一次 4 小时混合浏览、双页、媒体、下载、DevTools 和扩展负载后，无孤立 Helper 或无法结束任务。
- 所有 P0 为零；未关闭 P1 必须有书面风险接受、用户可见限制和明确后续版本。

### 最终发布门禁

- Swift、CEF bridge、Xcode Release、Release Notes Validator 和 MV3 探针全绿。
- Developer ID、Hardened Runtime、entitlement、公证、装订和 Gatekeeper 验证全绿。
- 应用、扩展和隐私目录三类更新分别完成成功、拒绝和回退测试。
- 最终候选包的版本、架构、Team ID、构建清单、SHA-256 和发布文档一致。
- CHANGELOG、README、功能数据、项目状态、版本计划和发布说明同步完成。

## 8. 问题到版本的归属

| 问题域 | 负责版本 | v1.0 处理结果 |
|---|---|---|
| 导航屏障、fail-open、generation、扩展事务恢复 | v0.9.6 历史基线 + v0.9.7 回归 | 必须关闭死锁、避免冷启动重复安装并保留明确降级 |
| Developer ID、Hardened Runtime、公证、应用更新 | v0.9.7 | 必须完成正式分发与回退 |
| 隐私目录、PSL、危险下载、隐私落盘和安全文案 | v0.9.8 | 必须完成或做出准确的能力决策 |
| 文件选择、JS 对话框、全屏、崩溃恢复和默认浏览器 | v0.9.9 | 必须完成 |
| Rex 扩展管理 UI、Chromium 配置读回、站点访问/用户脚本、能力矩阵和 action/`activeTab` 边界 | v0.9.7 | 当前最高优先级；三态与开关读回、实测行为和准确能力边界必须完成 |
| native messaging / iCloud Passwords | v0.9.7 | 通用能力单独验证；正式支持还需 Rex profile manifest、Apple managed entitlement 或 helper 签名名单接纳，以及原始 helper 端到端结果 |
| 扩展自动更新和更广类别样本矩阵 | v0.9.9 | 自动更新、回退和分类样本报告必须完成 |
| 无障碍、低电量、窗口恢复和诊断导出 | v0.9.9 | 必须实现并验证，或删除领先声明 |
| 全矩阵、压力、恢复、安全审计和正式发布 | v1.0.0 | 全部门禁通过 |
| App Store、分屏增强、通用指纹随机化、自建 CEF | v1.0 后 M6 | 不阻塞本轮稳定版 |

## 9. 外部决策截止点

| 决策 | 最晚完成版本 | 默认方向 |
|---|---|---|
| Developer ID 团队、bundle ID、公证凭据 | v0.9.7 开始前 | Developer ID 为 v1.0 主分发路径 |
| Apple 浏览器 passkey managed entitlement | v0.9.6 形成 iCloud 结论前 | 由组织账号 Account Holder 正式申请；未获批时 iCloud Passwords 保持受限 |
| 更新框架、feed 和密钥保管 | v0.9.7 开始前 | 优先 Sparkle 2，先完整包后差分 |
| PSL 数据源与恶意网站检测边界 | v0.9.8 开始前 | 使用维护中的 PSL；安全能力按真实选型呈现 |
| 完整 `activeTab`/action 与 native messaging 可行性 | v0.9.6 退出前 | 有限期验证，不做误导性的近似兼容或宿主身份绕过 |
| 收藏数据边界 | v0.9.9 功能冻结前 | 合并或明确分离，用户文案和数据语义一致 |
| macOS 支持范围和测试设备 | v1.0.0-rc.1 前 | 以 DeliveryPlan 为基线并在 RC 前冻结 |

## 10. 相关文档

- [v1.0 未来实施计划](FuturePlan.md)
- [当前项目状态与问题清单](CurrentProjectStatus.md)
- [测试与交付计划](DeliveryPlan.md)
- [安全、隐私与性能](SecurityPrivacyPerformance.md)
- [路线图](../ROADMAP.md)
