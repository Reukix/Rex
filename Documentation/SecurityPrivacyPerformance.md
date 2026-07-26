# 安全、隐私与性能方案

## 安全边界

- Chromium renderer、GPU 和 utility 进程与原生主进程隔离，启用 Chromium sandbox 与 site isolation。
- Bridge 采用闭合命令/事件枚举；对 URL 协议、消息大小、tab/profile ownership 和枚举值逐项验证。
- 网页 JavaScript 无法直接获得 Keychain、文件系统、剪贴板、摄像头、麦克风或原生对象。
- Rex 不提供 Google 账号同步，也不保存同步令牌。下载由 CEF 下载回调和系统目标选择流程管理；危险文件检测、Safe Browsing、签名及 MIME 一致性校验尚未实现。
- 内容拦截目录编译在 `RexPrivacyEngine.cpp` 中，没有独立规则包、签名校验、在线更新或自定义订阅链路。

## 隐私架构

当前隐私链路由三个独立层组成，不是所有网络请求依次经过同一条规则管线：

1. **Swift 顶层导航策略**：`PrivacyURLPolicy` 在地址栏提交和 Rex 接管的弹窗导航时移除 `_hsenc`、`fbclid`、`gclid`、`utm_*` 等已知追踪参数，并对非本地 HTTP 地址尝试 HTTPS。只有特定 TLS 不可用错误允许回退 HTTP；证书、DNS 和通用网络错误不会降级。该策略不改写页面自行发起的 CEF 子资源。
2. **CEF 子资源目录拦截**：`RexPrivacyEngine.cpp` 内置 45 个广告、41 个追踪、10 个指纹和 8 个社交目录条目。`OnBeforeResourceLoad` 在 IO 线程分类请求，命中时返回 `RV_CANCEL`，并把类别和域名作为 blocked event 回传。主框架导航永不在该层拦截；第一方未知时放行。
3. **CEF Cookie 设置**：第三方 Cookie 限制通过 RequestContext/profile 的 `profile.cookie_controls_mode` 全局偏好执行。`CanSendCookie` 与 `CanSaveCookie` 不逐请求阻断，因此单标签关闭盾牌不会关闭全局 Cookie 限制，盾牌的 Cookie 拦截计数通常也不会增加。

保护级别语义如下：

- **标准**：匹配第三方广告和追踪目录；`fingerprintProtectionEnabled` 默认为 `true`，所以标准模式当前也会拦截第三方已知指纹服务。
- **严格**：包含标准能力，并追加第三方社交目录。
- **自定义**：Swift 映射为 CEF `aggressive`；广告/追踪目录允许匹配第一方请求，同时对第三方请求启用有限路径启发式。指纹保护仍由独立开关控制。

第一方判断使用有限的 registrable-domain 启发式和少量常见二级后缀表，不是完整 PSL/eTLD+1。盾牌的拦截资源和计数按标签累计并随会话持久化，目前不会在每次主导航后自动清零，因此界面中的统计不能解释为严格的“当前页面最近一次加载”。

隐私窗口使用独立内存 RequestContext，不恢复或写入普通会话资料。它不能向 ISP、组织网络管理员或访问的网站隐藏网络活动。

## 当前功能边界

- 没有恶意网站检测、Safe Browsing、自定义规则、在线目录更新、EasyList 语法或元素隐藏。
- “指纹保护”只阻止目录中已知指纹服务的网络请求，不会随机化 Canvas/WebGL/Audio 等浏览器指纹。
- 没有完整 brave-core 或完整 PSL/eTLD+1 站点例外系统；当前目录匹配与启发式应视为有限覆盖。

## 权限

权限决策键由 profile + top-level origin + requesting origin + permission 构成，支持仅本次、标签关闭撤销、始终允许/阻止与每次询问。屏幕录制、蓝牙、USB、MIDI 等系统级授权需要同时满足 macOS 和站点层决策。

## 性能

- Chromium IPC、历史数据库和规则加载不占用主线程。
- 每个 tab 的宿主 `NSView` 稳定缓存；分屏 resize 只修改 frame。
- 可见分屏页面不休眠；播放媒体、会议、上传下载和设备权限活动页不冻结。
- 内存压力按“已归档→休眠后台→冻结后台”的优先级释放资源，并保留恢复元数据。
- favicon 与快照采用有界 LRU 缓存；侧栏使用 LazyVStack。
- 低电量模式关闭噪点/实时高光，减少模糊层和弹性动画。
- `ProcessMetricsMonitor` 使用 Darwin `proc_*` 接口遍历 Rex 主进程及其 Helper 子进程，按 physical footprint 汇总内存，并根据连续 CPU time 样本计算 Rex 总 CPU；该总量包含 renderer、GPU、utility 和 worker 等子进程。
- 每个网页的指标来自 CEF `CefTaskManager`：通过 `CefBrowser::GetIdentifier` 查找浏览器主 task，再读取该 task 的内存和 CPU。页面只在本机实时展示这些快照，不把它们写入会话数据库。
- Chromium 可能让多个任务共享 renderer 进程；`CefTaskInfo.cpu_usage` 描述 task 所在进程的 CPU，因此共享 renderer 的多个网页行不能相加。独立 GPU、utility、service worker、shared worker 和 dedicated worker 不强行分摊到网页，只计入 Darwin Rex 总量。
- 前台每 1.5 秒采样一次，应用失焦后降为每 6 秒一次；工具栏和详情页共享同一引用计数监测器，避免重复定时器。首轮 CEF 快照预热 2.1 秒，最后一个订阅结束时释放 CefTaskManager 并停止其后台刷新。

## 可观测指标

当前性能页仅实时显示 Rex 进程树总量和 `CefTaskManager` 网页快照，不持久化性能历史。后续诊断计划记录脱敏的启动阶段耗时、tab 创建耗时、renderer 崩溃率、每 tab 内存、分屏 resize 掉帧、规则匹配耗时和会话恢复成功率；诊断导出必须经用户主动触发并预览内容。
