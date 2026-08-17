# 2026-08-17 全量编译 CEF/Chromium 与默认浏览器修复

日期：2026-08-17  
基准版本：v0.9.9（构建 993）  
本次构建：v0.9.9 build 998 Beta  
状态：Unreleased（已合入工作树）  
CEF 版本：151.3.18+gbeff58d+chromium-151.0.7922.138（本地全量源码编译）  
Chromium 版本：151.0.7922.138  
架构：Apple Silicon arm64 only  
构建配置：Xcode Release（Apple Development 签名）  
构建产物：`Dist/Rex.app`

## 目标

1. 全量编译 CEF/Chromium 源码，开启专有编解码器支持，修复抖音等流媒体站点视频播放问题。
2. 修复设置为默认浏览器后从其他应用打开链接创建多窗口而非标签页的问题。
3. 修复外部链接打开后 Rex 不自动激活到前台的问题。
4. 添加鼠标悬停标签页显示标题和地址功能。
5. 清理不再需要的 UA 兼容身份模拟代码和示例标签页数据。

## 全量编译 CEF/Chromium 源码

### 背景

CEF 标准发行包（SpotifyCDN）编译时未开启 `proprietary_codecs`，导致 `MediaSource.isTypeSupported()` 和 `HTMLMediaElement.canPlayType()` 对 H.264/AAC/HEVC 返回 `false`。抖音等流媒体站点在能力探测阶段就判定浏览器不支持现代多媒体，弹出"浏览器版本过低"或视频无限加载。即使通过 JS shim 骗过 API 探测层，MSE 播放管道的 `EnableBitstreamConverter` RPC 仍被编译时门控拒绝，比特流无法转换。

### 编译参数

```text
proprietary_codecs=true
ffmpeg_branding=Chrome
is_official_build=true
enable_widevine=true
target_cpu=arm64
chrome_pgo_phase=0
```

### 编译过程

1. 下载 CEF 源码（commit `beff58d`）。
2. `gclient sync` 同步 Chromium 源码和第三方依赖（约 120GB）。
3. `gclient runhooks` 生成构建配置。
4. 安装 Metal Toolchain（`xcodebuild -downloadComponent MetalToolchain`）。
5. `ninja -C out/Release_GN_arm64 cefclient`（52004 个编译目标）。
6. `make_distrib.py --minimal` 生成 CEF binary distribution。

### 验证

- "Proprietary codecs not enabled in this Chromium build" 错误字符串已消失。
- `avc1.`、`mp4a.40` 等 H.264/AAC 编解码器字符串存在。
- H.264/AAC 通过 macOS VideoToolbox/AudioToolbox 原生解码。

## 默认浏览器多窗口修复

### 问题

设置为默认浏览器后从其他应用打开链接会创建多个窗口而非在现有窗口添加标签页。

### 根因

SwiftUI `WindowGroup` 缺少 `handlesExternalEvents(matching:)` 修饰符，导致 macOS 为每个外部 URL 事件打开新窗口。

### 修复

为 `browser` 和 `private-browser` 两个 `WindowGroup` 添加 `.handlesExternalEvents(matching: [])`，阻止 SwiftUI 的 WindowGroup 认领外部 URL 事件。所有外部链接完全由 `application(_:open:)` 统一路由到现有窗口的新标签页。

## 外部链接激活修复

### 问题

从其他应用点击链接后标签页已创建，但 Rex 窗口未自动激活到前台。

### 修复

在 `RexAppDelegate.application(_:open:)` 中外部 URL 路由后调用 `NSApp.activate(ignoringOtherApps: true)`。

## 标签页悬停提示

### 问题

系统默认 tooltip 延迟 2 秒，体验不佳。

### 实现

新增 `Sources/RexApp/DesignSystem/FastTooltip.swift`，使用 SwiftUI popover 实现 1 秒延迟的自定义 tooltip，替换系统 `.help()` 修饰符。在 `LiquidGlassTabRow`、`CollapsedTabButton` 和 `ArchivedTabRow` 中对标签页应用 `.fastTooltip()`，悬停 1 秒后显示标题和地址。

## CEF 辅助窗口崩溃修复

### 问题

CEF 辅助 Chrome 窗口成为主窗口时 macOS 断言崩溃（`NSWindow _changeJustMain` 断言失败）。

### 修复

在 `makeMainWindow` 调用前检查 `canBecomeMainWindow`。

## UA 兼容身份代码移除

全量编译 CEF 后 UA 模拟不再需要。移除以下内容：

- `RexSiteCompatibilityPolicy.h`（已删除）
- `RexChromeCompatibilityUserAgent()`、`RexChromeBrandVersionList()`、`RexChromeCompatibilityIdentityParameters()`、`RexDefaultCompatibilityIdentityParameters()`
- `RexBrowserClient` 中的 `site_compatibility_*` 成员变量和方法
- `CefDevToolsMessageObserver` 基类继承
- `RexHelperMain.mm` 中的 `RexInstallChromeCompatibilityUserAgentData` 和 UA-CH 注入代码
- `OnBeforeBrowse` 和 `OnBeforeResourceRequest` 中的兼容身份路由逻辑

## 示例标签页数据移除

移除 `BrowserStore` 中的 `sampleTabs`（`https://example.com`、`https://www.apple.com` 等示例标签页）。`restorePreviousSession=true` 时现在也使用起始页作为初始标签页，实际会话从数据库异步恢复。

## 本次构建版本历史

| 构建 | 内容 |
|---|---|
| 993 | 基线版本（未发布到本日志） |
| 994 | 全量编译 CEF，专有编解码器，JS codec shim |
| 995 | 移除 JS shim，全量编译 CEF 正式版 |
| 996 | `handlesExternalEvents` 多窗口修复 |
| 997 | 标签页悬停提示，外部链接激活 |
| 998 | CEF 崩溃修复，截图修复，UA 清理，sampleTabs 清理 |

## 打包结果

已生成：

- `Dist/Rex.app`（364M，arm64，build 998）
- `Dist/Rex-v0.9.9-macos-arm64-chromium.zip`（160M）

SHA-256：

```text
（见 Dist/SHA256SUMS）
```

签名：Apple Development（个人团队证书 P3GFVW5397）

## 已知限制

- 本包使用免费个人团队证书签名，不能通过 Developer ID、公证和 Gatekeeper 正式门禁。
- Chrome Web Store 扩展自动更新尚未完成。
- chromium_git 源码树（229GB）已在编译后删除释放空间。
