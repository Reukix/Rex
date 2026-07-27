# 安全、隐私与性能方案

## 安全边界

- Chromium renderer、GPU 和 utility 进程与原生主进程隔离，启用 Chromium sandbox 与 site isolation。
- Bridge 采用闭合命令/事件枚举；对 URL 协议、消息大小、tab/profile ownership 和枚举值逐项验证。
- 网页 JavaScript 无法直接获得 Keychain、文件系统、剪贴板、摄像头、麦克风或原生对象。
- Rex 不提供 Google 账号同步，也不保存同步令牌。下载由 CEF 下载回调和系统目标选择流程管理；危险文件检测、Safe Browsing、签名及 MIME 一致性校验尚未实现。
- Chrome Web Store 扩展安装使用独立的受限下载链路：只允许 Google 官方更新/包主机，验证 CRX 扩展 ID 与签名，限制下载、文件数和解包大小，并拒绝路径穿越、符号链接、重复路径和不支持的 ZIP 格式。该校验不等同于通用文件下载的危险内容扫描。
- 商店扩展读取时重新验证 manifest 公钥推导出的 Chromium runtime ID 与验签 store ID；身份缺失或不一致的包不会进入预期运行集合。
- 启用的扩展本体在 Chromium 中执行，并获得 manifest 声明且由 Chromium 允许的权限。安装、启用、停用、手动更新和移除使用 browser-target Extensions CDP 即时对账；只有实际启用的受管路径匹配预期 generation 后才报告成功。
- 内部扩展控制通道在 `CefInitialize` 前预留 Chromium `--remote-debugging-pipe` 使用的 fd 3/4，不绑定 loopback 或其他 TCP 监听地址，也不把 browser CDP 能力暴露给普通网页 target。
- 冷启动恢复的 HTTP(S) browser 在扩展 generation 就绪前保持 `about:blank`；即使预期集合为空，也先清理 profile 中的陈旧受管注册。热变更只立即重载活跃普通 HTTP(S) 页面，休眠或冻结页面恢复时重载一次，隐私窗口不运行扩展。
- 同路径更新在任何目录换盘前原子写入 replacement journal；Chromium ack 后才提交并清理备份，确认前崩溃会在下次启动恢复上一版本。扩展状态只由相关命令 completion 提交，延迟广播不能覆盖新事务。
- 内容拦截目录编译在 `RexPrivacyEngine.cpp` 中，没有独立规则包、签名校验、在线更新或自定义订阅链路。

## 隐私架构

当前隐私链路由三个独立层组成，不是所有网络请求依次经过同一条规则管线：

1. **Swift 顶层导航策略**：`PrivacyURLPolicy` 在地址栏提交和 Rex 接管的弹窗导航时移除 `_hsenc`、`fbclid`、`gclid`、`utm_*` 等已知追踪参数，并对非本地 HTTP 地址尝试 HTTPS。只有特定 TLS 不可用错误允许回退 HTTP；证书、DNS 和通用网络错误不会降级。该策略不改写页面自行发起的 CEF 子资源。
2. **CEF 子资源目录拦截**：`RexPrivacyEngine.cpp` 内置 45 个广告、41 个追踪、10 个指纹和 8 个社交目录条目。`OnBeforeResourceLoad` 在 IO 线程分类请求，命中时返回 `RV_CANCEL`，并把类别和域名作为 blocked event 回传。主框架导航永不在该层拦截；第一方未知时放行。
3. **CEF Cookie 设置**：第三方 Cookie 限制通过 RequestContext/profile 的 `profile.cookie_controls_mode` 全局偏好执行。`CanSendCookie` 与 `CanSaveCookie` 不逐请求阻断，因此单标签关闭盾牌不会关闭全局 Cookie 限制，盾牌的 Cookie 拦截计数通常也不会增加。

扩展声明的 DNR 由 Chromium 扩展运行时单独执行，不合并到 `RexPrivacyEngine`，也不受 Rex 盾牌级别解释为另一套近似规则。扩展自身的网络行为和权限应按其 manifest 与 Chromium 扩展安全模型评估。

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
- 受管扩展启动校验每包只完整扫描一次；启停只更新内存运行状态，不重复遍历扩展文件树。
- 单次 manifest 解析只加载一次对应 `_locales/.../messages.json`，名称与描述复用同一本地化字典。
- Chrome Web Store 下载中的进度约每 80 ms 合并发布一次，完成、取消和失败终态立即发布。
- 普通窗口关闭时取消其会话恢复、导航、休眠和事件任务，并销毁该窗口全部 CEF 页面，避免不可见 renderer、媒体、网络或扩展内容继续占用资源。
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
