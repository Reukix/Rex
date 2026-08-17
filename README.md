# Rex

简体中文 | [English](README_EN.md)

![版本](https://img.shields.io/badge/version-0.9.9%20Beta-202124)
![系统](https://img.shields.io/badge/macOS-14%2B-007AFF)
![架构](https://img.shields.io/badge/architecture-Apple%20Silicon-34C759)
![许可证](https://img.shields.io/badge/license-AGPL--3.0-F5A623)

Rex 是一款面向 macOS 的原生桌面浏览器，围绕垂直标签页、工作空间、双页面分屏和默认隐私保护构建。界面由 SwiftUI 与 AppKit 实现，网页平台和扩展运行时由 Chromium Embedded Framework（CEF）提供。

当前版本为 **v0.9.9 build 998 Beta**。项目仍在持续开发中，暂不适合作为覆盖所有使用场景的生产级主浏览器。

## 主要特性

- **原生 macOS 界面**：浏览器外壳、导航、标签页、下载、对话框、设置和扩展管理均由 SwiftUI 与 AppKit 呈现。
- **Chromium 兼容能力**：CEF 151 负责网页渲染、网络、开发者工具、下载、权限和扩展 API。CEF 运行时使用本地全量源码编译版本，开启专有编解码器（H.264/AAC/HEVC），支持抖音等流媒体站点视频播放。
- **垂直标签页与工作空间**：按场景组织浏览会话，避免大量标签页挤在横向栏中。鼠标悬停标签页时显示标题和地址。
- **默认浏览器**：Rex 可注册为 macOS 默认浏览器，从其他应用打开链接时自动激活并在现有窗口创建新标签页。
- **双页面分屏**：在同一个窗口内并排浏览两个页面。
- **隐私盾牌**：清理已知追踪参数、尝试升级 HTTPS、拦截精选请求域名并限制第三方 Cookie。
- **Rex 原生下载界面**：Chromium 负责传输和文件写入，Rex 提供进度、历史记录与文件操作。
- **扩展管理**：通过原生 `rex://extensions` 界面安装、更新、启停、配置和移除受支持的 Chromium 扩展。
- **不包含 AI 功能**：不提供聊天、网页总结、推荐或自动浏览能力。

Rex 已支持较完整的扩展工作流，但并不等同于 Google Chrome。部分 Chrome Web Store 扩展依赖 Rex 尚未实现的 API 或 Chromium 原生界面行为。

## 系统要求

- macOS 14 或更高版本
- 仅支持 Apple Silicon（`arm64`），不支持 Intel Mac
- 安装带 macOS SDK 的 Xcode
- 完整 Chromium 构建需要 XcodeGen、CMake 和 Ninja

## 构建

构建轻量 Swift Package 预览版：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

准备完整 CEF/Chromium 应用：

```bash
Scripts/fetch-cef.sh
Scripts/build-cef-runtime.sh
xcodegen generate --spec project.yml
```

构建不使用 Apple 开发者证书的本地 Release 包：

```bash
REX_PACKAGE_SIGNING_MODE=adhoc \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
Scripts/package-chromium-app.sh 0.9.9 998 Release
```

产物位于 `Dist/Rex.app` 和 `Dist/Rex-v0.9.9-macos-arm64-chromium.zip`。ad-hoc 签名只用于满足 macOS 嵌套代码的结构要求，不属于 Developer ID 签名、公证或通过 Gatekeeper 的正式分发包。

## 测试安全

自动化 QA 不得直接启动构建后的 Rex App 或可执行文件，也不得使用 `open`。请使用隔离烟测入口，它会创建临时用户目录和模拟 Keychain 环境：

```bash
Scripts/run-isolated-rex-smoke.sh
```

不得把 `CFFIXED_USER_HOME` 指向真实用户目录。现有 Rex 偏好设置、缓存、保存状态以及 `~/Library/Application Support/Rex` 均属于用户数据，测试清理不得修改或删除这些内容。

## 许可证

Rex 的原创源代码采用 [GNU Affero General Public License v3.0](LICENSE) 许可。CEF、Chromium 以及其他第三方项目和捆绑组件继续适用各自的许可证与声明。
