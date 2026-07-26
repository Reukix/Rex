# 2026-07-24 修复验证日志

日期：2026-07-24  
基准版本：v0.5.2-beta.1（构建 521）  
状态：Unreleased（已合入工作树，尚未发版）  
CEF 版本：150.0.14+g7c1aa68+chromium-150.0.7871.129  
Chromium 版本：150.0.7871.129  
架构：Apple Silicon arm64 only  
构建配置：Xcode Debug  
构建产物：`/Users/yuki/Library/Developer/Xcode/DerivedData/Rex-eaavxbrpajcmdyandyjweerpvvdv/Build/Products/Debug/Rex.app`

## 目标

在 v0.5.2-beta.1 之上修复 DevTools 交互、折叠侧栏布局、标签关闭入口、导航栏信息展示，以及“默认搜索引擎后新建标签页空白”等问题，并完成 Debug 构建与相关回归验证。

## 验证结果

- `xcodebuild` Debug 构建成功。
- 相关测试通过：
  - 新建标签页首页
  - 搜索引擎持久化
  - 私密窗口初始化

## 对应修复

### DevTools 拖动留白 / 卡顿

- 固定内容区与工具区宽度分配。
- 拖动期间禁用动画。
- 向 CEF 同步 `WasResized` / 屏幕信息。

### 折叠侧栏 UI 错乱

- 折叠态改为垂直居中的工作空间 + 标签图标布局。
- 宽度约束为 58pt。

### DevTools 点击偏移

根因：隐藏 popup 与可见宿主坐标不同步。

修复后行为：

- DevTools 优先 `SetAsChild` 嵌入宿主面板。
- 始终用已存储的 popup 窗口同步尺寸。
- `ignoresMouseEvents = YES`，避免命中区整体下移。

### 标签页关闭按钮

- 展开 / 折叠态都始终显示 X。
- 不再只能通过右键关闭。

### 导航栏左侧功能 + 锁图标

- 左侧显示内存 / CPU 占用。
- 点击锁图标弹出网站信息（连接、协议、地址、隐私拦截、权限入口）。
- 说明：完整系统证书链 UI 尚未接 CEF 证书详情，当前为连接摘要。

### 默认搜索引擎后新建标签页空白

- 新建标签页（含私密窗口初始页）会打开当前默认引擎首页。
- 例如默认 Google 时打开 `https://www.google.com/`。

## 主要改动文件

- [`ChromiumBridge/RexChromiumRuntime.mm`](../../ChromiumBridge/RexChromiumRuntime.mm)
- [`Sources/RexApp/Features/AppShell/BrowserRootView.swift`](../../Sources/RexApp/Features/AppShell/BrowserRootView.swift)
- [`Sources/RexApp/Features/AppShell/ProcessMetricsMonitor.swift`](../../Sources/RexApp/Features/AppShell/ProcessMetricsMonitor.swift)
- [`Sources/RexApp/Features/Tabs/BrowserSidebar.swift`](../../Sources/RexApp/Features/Tabs/BrowserSidebar.swift)
- [`Sources/RexApp/State/BrowserStore.swift`](../../Sources/RexApp/State/BrowserStore.swift)
- [`Sources/RexApp/Domain/BrowserPreferences.swift`](../../Sources/RexApp/Domain/BrowserPreferences.swift)

## 与 CHANGELOG 对齐

本批改动已记入根目录 [`CHANGELOG.md`](../../CHANGELOG.md) 的 `Unreleased`：

- DevTools 拖动留白与卡顿
- DevTools 点击偏移
- 折叠侧栏布局错位
- 标签页始终显示关闭按钮
- 导航栏内存 / CPU 与锁图标网站信息
- 新建标签页打开默认搜索引擎首页

## 已知限制（本批未关闭）

- 页面证书与安全状态详情仍未接入完整 CEF 证书链 UI；锁图标弹层目前提供连接摘要与相关入口。
- 本批为 v0.5.2-beta.1 之上的修复合集，尚未提升营销版本号 / 构建编号。
- Developer ID 签名、公证与自动更新仍属正式发布阶段。

## 回退说明

- 本批不升级 SQLite schema。
- 搜索引擎与新建标签页首页行为继续依赖现有偏好键（如默认搜索引擎）。
- 回退前仍建议备份 `~/Library/Application Support/Rex/Browser.sqlite`。
