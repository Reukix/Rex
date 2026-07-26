# 更新日志

## 0.8.1 (build 810) — 2026-07-27

### 资料库清理、隐私目录与原生标题栏布局

- 历史记录页新增「删除浏览数据」菜单，可永久删除过去 1 小时、过去 24 小时、过去 7 天或所有时间的浏览历史；执行前显示范围明确的确认提示，收藏和下载记录不受影响。
- 收藏库与下载的空状态改为填满标题栏下方剩余区域，修复内容垂直居中导致顶部间距过大的问题。
- 主窗口启用全尺寸内容标题栏，导航栏根据真实红黄绿窗口按钮位置动态留出左侧空间并移动到其右侧；进入全屏后恢复普通边距。
- 标题栏改为两张独立卡片：左卡片同时承载原生红黄绿按钮背景与内存/CPU 指标，右卡片只放扩展、导航、地址栏和页面操作，两卡保持 6 pt 间距。关闭性能监控时普通窗口左卡缩为交通灯卡片，全屏时则完全移除左卡。
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

- Release Notes 版本与结构校验通过（v0.8.1，26 个功能 ID）；Swift Testing `77/77` 通过；完整 CEF bridge、XcodeGen 与 Xcode arm64 Debug 构建通过。
- 产物：`Dist/Rex-v0.8.1-macos-arm64-chromium.zip`（143,368,323 bytes；`du` 约 144M）/ `Dist/Rex.app`（约 343M）。
- ZIP SHA-256：`0ab8057b23c905e5c181e5603dd58cae11e40f56ec6989a8f830cd6dfda601b2`；压缩数据完整性校验通过。
- 主程序、CEF 与五个 Helper 均为纯 arm64，App/Helper 版本均为 `0.8.1 / 810`。真实 App 冒烟确认双卡标题栏在普通/全屏与性能监控开/关四种状态下均无覆盖或断层；四档历史删除菜单、收藏/下载空状态的上一轮验证继续有效，运行中 CEF 子进程使用 `Rex/0.8.1`。
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
