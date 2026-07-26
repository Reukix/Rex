# 2026-07-24 性能监测 / DevTools 平滑拖拽 / NTP 收藏 / 菜单与右键

日期：2026-07-24  
版本：v0.5.3-beta.1（build 524）  
状态：Released package  
CEF 版本：150.0.14+g7c1aa68+chromium-150.0.7871.129  
架构：Apple Silicon arm64 only

## 目标

1. 性能监测只保留内存 + CPU（去掉加载进度）。
2. 拖动开发者工具时使用更平滑的方式，降低闪烁/重绘抽搐。
3. 新标签页增加「收藏网站」卡片栏（仅 NTP，非网页收藏）。
4. macOS 菜单栏「标签页 / 工作空间」按实际数量显示。
5. 右键菜单删除「显示网页源代码」。
6. 推进版本并构建完整 Chromium 包，整理完成日志。

## 改动详情

### 1. 性能监测

文件：`Sources/RexApp/Features/AppShell/BrowserRootView.swift`（`ToolbarStatusCluster`）

- 删除加载进度 `metricChip` 与 54pt 预留空位。
- 集群固定宽度从 198 调整为 138，仅内存 + CPU。

### 2. DevTools 平滑拖拽

| 文件 | 变更 |
|---|---|
| `BrowserRootView.swift` | `@State developerToolsDragWidth` 本地拖拽宽度；拖动中不每帧写 store |
| `BrowserStore.swift` | `begin/endDeveloperToolsResize` 挂起/恢复 CEF layout sync；`resizeDeveloperTools(..., force:)` 在松手时提交 |
| `RexChromiumRuntime.h/.mm` | `setLayoutSyncSuspended:` / `flushLayoutSync`；拖动中只改 native frame，跳过 `WasResized`；松手后全量 flush |

### 3. NTP 收藏网站

| 文件 | 变更 |
|---|---|
| `Sources/RexApp/Domain/NewTabFavorites.swift` | `NewTabFavoriteSite` + `NewTabFavoritesStore`（JSON 持久化） |
| `BrowserStore.swift` | `newTabFavorites` / add / remove / load / persist；隐私窗口不持久化 |
| `BrowserContentView.swift` | 「收藏网站」卡片栏 + 添加（当前页/剪贴板）+ 右键移除 |

说明：与 `bookmarks`（网页收藏/资料库）完全分离。

### 4. 菜单栏

文件：`Sources/RexApp/Application/RexApp.swift`（`BrowserCommands`）

- 标签页：仅 `1...min(8, visibleTabs.count)` +「最后一个标签页」（⌘9）。
- 工作空间：按 `spaces` 实际名称与数量列出（最多 9，⌃1…）。

### 5. 右键菜单

文件：`ChromiumBridge/RexChromiumRuntime.mm`（`OnBeforeContextMenu`）

- 删除 `MENU_ID_VIEW_SOURCE` /「显示网页源代码」。
- 保留「检查」。

## 文件日志

- `ChromiumBridge/RexChromiumRuntime.h`
- `ChromiumBridge/RexChromiumRuntime.mm`
- `Sources/RexApp/Application/AppVersion.swift`
- `Sources/RexApp/Application/RexApp.swift`
- `Sources/RexApp/Domain/NewTabFavorites.swift`（新增）
- `Sources/RexApp/Features/AppShell/BrowserRootView.swift`
- `Sources/RexApp/Features/SplitView/BrowserContentView.swift`
- `Sources/RexApp/State/BrowserStore.swift`
- `project.yml`
- `Scripts/package-chromium-app.sh`
- `CHANGELOG.md`
- `Documentation/Releases/2026-07-24-metrics-devtools-ntp-favorites.md`（本文件）

## 验证建议

1. 工具栏左侧仅见内存、CPU 芯片，无加载百分比。
2. 打开 DevTools → 拖动左侧分隔条：拖动过程应更平滑；松手后页面与 DevTools 尺寸一次对齐。
3. 新标签页「收藏网站」可添加/打开/移除；书签区仍独立；隐私窗口不出现该栏。
4. 仅 3 个工作空间时，菜单「工作空间」只显示 3 项且为真实名称。
5. 页面右键无「显示网页源代码」，仍有「检查」。

## 完整包

```bash
Scripts/package-chromium-app.sh 0.5.3-beta.1 524
```

产物：

- `Dist/Rex.app`
- `Dist/Rex-v0.5.3-beta.1-macos-arm64-chromium.zip`

### 包校验

| 项 | 值 |
|---|---|
| 版本 | `v0.5.3-beta.1` / build `524` |
| `Info.plist` | `CFBundleShortVersionString=0.5.3`，`CFBundleVersion=524` |
| 架构 | arm64 |
| CEF | `150.0.14+g7c1aa68+chromium-150.0.7871.129` |
| App 体积 | ~340M |
| Zip 体积 | ~135M（144M 十进制） |
| SHA256 | `1055be883530d73810d18454891972b545d24ec28e26c9aa68d5a83661e158df` |
| 校验文件 | `Dist/SHA256SUMS` / `Dist/PACKAGE-INFO.txt` |

