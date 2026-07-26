# 2026-07-24 间距收紧与 Chromium 完整包

日期：2026-07-24  
基准版本：v0.5.2-beta.1（构建 521）  
本次构建：v0.5.2-beta.1（构建 522）  
状态：Unreleased（已合入工作树）  
CEF 版本：150.0.14+g7c1aa68+chromium-150.0.7871.129  
Chromium 版本：150.0.7871.129  
架构：Apple Silicon arm64 only  
构建配置：Xcode Debug（`CODE_SIGNING_ALLOWED=NO`）

## 目标

1. 按截图反馈收紧主窗口顶部与侧栏空白间距。
2. 产出包含 Chromium/CEF runtime 与全部 Helper 的完整可运行包。
3. 记录本次改动文件与验证方式。

## UI 间距调整

针对截图中标题栏红绿灯与内存/CPU 指标、侧栏区域之间空隙过大的问题：

| 区域 | 原值 | 新值 |
|---|---|---|
| 主布局 `VStack` spacing | 8 | 4 |
| 工具栏 `padding.top` | 8 | 2 |
| 工具栏/内容水平 padding | 10 | 8 |
| 内容底部 padding | 10 | 6 |
| 侧栏与内容 `HStack` spacing | 8 | 6 |
| 侧栏与内容宽度扣除 | 8 | 6 |
| `RexMetrics.toolbarHeight` | 54 | 44 |
| 地址栏高度 | 36 | 32 |
| 指标芯片高度 | 28 | 26 |
| 工具栏内部 `HStack` spacing | 8 | 6 |
| 折叠侧栏工作区 spacing | 8 | 6 |
| 侧栏顶部 padding（折叠/展开） | 8 / 10 | 6 / 8 |
| 标签搜索框 top padding | 8 | 6（并加 bottom 2） |
| 折叠标签列表 spacing / 垂直 padding | 8 / 8 | 6 / 6 |
| 展开标签列表 spacing / 垂直 padding | 5 / 7 | 4 / 5 |
| 权限提示条 top padding | 60 | 48 |

## 完整 Chromium 包

新增脚本：

```bash
Scripts/package-chromium-app.sh [version] [build] [Debug|Release]
# 默认: 0.5.2-beta.1 522 Debug
```

脚本流程：

1. 校验 Apple Silicon。
2. 构建 CEF bridge / Helper（`Scripts/build-cef-runtime.sh`）。
3. `xcodegen generate` 刷新 Xcode 工程。
4. `xcodebuild` 构建嵌入 CEF 的 `Rex.app`。
5. 校验 framework 与 5 个 Helper 均已嵌入。
6. 输出：
   - `Dist/Rex.app`（可直接运行）
   - `Dist/Rex-v0.5.2-beta.1-macos-arm64-chromium.zip`
   - `Dist/SHA256SUMS`
   - `Dist/PACKAGE-INFO.txt`

预期嵌入内容：

- `Chromium Embedded Framework.framework`
- `Rex Helper.app`
- `Rex Helper (Alerts).app`
- `Rex Helper (GPU).app`
- `Rex Helper (Plugin).app`
- `Rex Helper (Renderer).app`
- `Resources/CEF-LICENSE.txt`
- `Resources/Chromium-CREDITS.html`

## 本次改动文件

| 文件 | 变更类型 | 说明 |
|---|---|---|
| [`Sources/RexApp/Features/AppShell/BrowserRootView.swift`](../../Sources/RexApp/Features/AppShell/BrowserRootView.swift) | 修改 | 收紧主窗口/工具栏/内容区/权限条间距；地址栏与指标芯片高度下调 |
| [`Sources/RexApp/Features/Tabs/BrowserSidebar.swift`](../../Sources/RexApp/Features/Tabs/BrowserSidebar.swift) | 修改 | 收紧侧栏工作区、搜索框、标签列表间距 |
| [`Sources/RexApp/DesignSystem/LiquidGlass.swift`](../../Sources/RexApp/DesignSystem/LiquidGlass.swift) | 修改 | `toolbarHeight` 54 → 44 |
| [`Scripts/package-chromium-app.sh`](../../Scripts/package-chromium-app.sh) | 新增 | 一键构建并打包含 Chromium 的完整应用 |
| [`CHANGELOG.md`](../../CHANGELOG.md) | 修改 | Unreleased 增加间距修复与打包脚本条目 |
| [`Documentation/Releases/2026-07-24-spacing-chromium-package.md`](./2026-07-24-spacing-chromium-package.md) | 新增 | 本文件：改动与打包日志 |

## 验证

- 间距：对比截图区域，标题栏与工具栏、侧栏内容更紧凑。
- 构建：`Scripts/package-chromium-app.sh 0.5.2-beta.1 522 Debug`
- 产物检查：`Dist/Rex.app/Contents/Frameworks/` 含 CEF + 5 Helper；`lipo -info` 为 arm64。

## 已知限制

- 本包为 Debug + ad-hoc/`CODE_SIGNING_ALLOWED=NO` 本地包，非正式公证分发包。
- 营销版本仍记为 0.5.2-beta.1，构建号建议记为 522。
- Developer ID 签名、公证与自动更新仍属正式发布阶段。

## 回退

- UI 间距回退：还原上述三个 Swift 文件的 spacing/padding 数值。
- 打包脚本可直接删除，不影响现有 `fetch-cef` / `build-cef-runtime` / `embed-cef-runtime` 流程。

## 打包结果

已生成：

- `Dist/Rex.app`（339M，arm64，build 522）
- `Dist/Rex-v0.5.2-beta.1-macos-arm64-chromium.zip`（145M）
- `Dist/SHA256SUMS`
- `Dist/PACKAGE-INFO.txt`

SHA-256：

```text
8adc1dc36578186a9bf8abef1e7fcb83c8242b2c238af70f657bc5d623069ea8  Rex-v0.5.2-beta.1-macos-arm64-chromium.zip
```

嵌入校验：

- Chromium Embedded Framework.framework
- Rex Helper / Alerts / GPU / Plugin / Renderer
- CEF-LICENSE.txt / Chromium-CREDITS.html
- `CFBundleShortVersionString=0.5.2`，`CFBundleVersion=522`
