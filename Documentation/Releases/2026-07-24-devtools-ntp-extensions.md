# 2026-07-24 DevTools 拖拽 / 新标签页 / 扩展入口

日期：2026-07-24  
基准版本：v0.5.2-beta.1  
状态：Unreleased（已合入工作树）  
CEF 版本：150.0.14+g7c1aa68+chromium-150.0.7871.129  
架构：Apple Silicon arm64 only

## 目标

1. 修复拖动开发者工具宽度时网页与 DevTools 闪烁、抽搐。
2. 新标签页去掉搜索引擎芯片（改由设置管理），并增加实用布局。
3. 在性能监测（内存/CPU）右侧增加扩展入口，支持本地 Chrome 风格扩展包管理。

## 问题 1：DevTools 拖拽闪烁

### 原因

- SwiftUI 每次亚像素宽度变化都重建内容区与 DevTools 区。
- 拖动期间仍可能触发宽度动画。
- CEF `layout` + `NSViewFrameDidChangeNotification` 双重通知形成反馈环。
- 每次布局都调用 `WasResized` + `NotifyScreenInfoChanged`，拖动时过度重绘。

### 改动

| 文件 | 变更 |
|---|---|
| `Sources/RexApp/State/BrowserStore.swift` | `resizeDeveloperTools` 宽度 `floor` 量化，阈值从 0.5pt 提到 3pt |
| `Sources/RexApp/Features/AppShell/BrowserRootView.swift` | 内容/DevTools 宽度整点化；拖动时 `disablesAnimations`；彻底禁用宽度动画 |
| `ChromiumBridge/RexChromiumRuntime.mm` | 去掉 DevTools frame-change observer；子视图仅在尺寸变化时设 frame；`syncNativeBrowserView` 整点量化并对 `WasResized`/`NotifyScreenInfoChanged` 节流 |

## 问题 2：新标签页

### 改动

文件：`Sources/RexApp/Features/SplitView/BrowserContentView.swift`（`BrowserStartPageView`）

- **移除** `SearchEngine.allCases` 搜索引擎切换芯片。
- 保留搜索框，继续使用 `store.preferences.searchEngine`（设置页选择）。
- 增加问候语、搜索引擎设置入口、快捷操作（新标签 / 隐私窗口 / 历史 / 书签 / 下载 / 恢复关闭标签 / 扩展）。
- 有数据时展示书签网格与最近访问列表。

## 问题 3：扩展

### 改动

| 文件 | 作用 |
|---|---|
| `Sources/RexApp/Domain/BrowserExtensionModels.swift` | 扩展包模型 + 本地目录持久化（`~/Library/Application Support/Rex/Extensions/`） |
| `Sources/RexApp/Features/Extensions/BrowserExtensionsView.swift` | 扩展管理 UI：加载未打包扩展、启用/禁用、Finder 显示、移除 |
| `Sources/RexApp/Features/AppShell/BrowserRootView.swift` | 工具栏 `ToolbarStatusCluster` 右侧拼图按钮 + sheet；「更多」菜单入口 |
| `Sources/RexApp/State/BrowserStore.swift` | `isExtensionsPresented` |

### 运行时说明

当前 CEF 150 最小发行版 **没有** 公开的 `CefExtension` / `LoadExtension` API。  
扩展管理器可安装并保存 Chrome 风格 `manifest.json` 包；页面脚本注入等执行能力标记为「待运行时支持」，与产品文档中的受控扩展子集规划一致。

## 文件日志

- `ChromiumBridge/RexChromiumRuntime.mm`
- `Sources/RexApp/State/BrowserStore.swift`
- `Sources/RexApp/Features/AppShell/BrowserRootView.swift`
- `Sources/RexApp/Features/SplitView/BrowserContentView.swift`
- `Sources/RexApp/Domain/BrowserExtensionModels.swift`（新增）
- `Sources/RexApp/Features/Extensions/BrowserExtensionsView.swift`（新增）
- `CHANGELOG.md`
- `Documentation/Releases/2026-07-24-devtools-ntp-extensions.md`（本文件）

## 验证建议

1. 打开任意页面 → F12 打开开发者工具 → 拖动左侧分隔条：页面与 DevTools 不应再明显闪烁/抽搐。
2. 新建标签页：无搜索引擎芯片；搜索走设置中的默认引擎；快捷操作与书签/历史可用。
3. 点击性能指标右侧拼图图标：可加载含 `manifest.json` 的文件夹，列表可启用/移除。
4. 可选：`Scripts/package-chromium-app.sh 0.5.2-beta.1 523` 重新打包完整 Chromium 应用。

## 完整包（build 523）

已通过 `Scripts/package-chromium-app.sh 0.5.2-beta.1 523` 产出：

| 产物 | 路径 |
|---|---|
| 可运行应用 | `Dist/Rex.app`（约 339M） |
| Zip 归档 | `Dist/Rex-v0.5.2-beta.1-macos-arm64-chromium.zip`（约 135M / 141225925 bytes） |
| 校验 | `Dist/SHA256SUMS` / `Dist/PACKAGE-INFO.txt` |

- 版本：0.5.2（CFBundleShortVersionString）
- 构建号：523
- 架构：arm64
- CEF：150.0.14+g7c1aa68+chromium-150.0.7871.129
- Chromium：150.0.7871.129
- SHA256：`6a77578c3d4b06bfa3994ef38128ab4454cb2ded72cd00c67c5fbe6dd63e1cf1`
- 已嵌入：Chromium Embedded Framework + Helper / GPU / Renderer / Plugin / Alerts
