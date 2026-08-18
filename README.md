# Rex

简体中文 | [English](README_EN.md)

![版本](https://img.shields.io/badge/version-1.0.0-202124)
![系统](https://img.shields.io/badge/macOS-14%2B-007AFF)
![架构](https://img.shields.io/badge/architecture-Apple%20Silicon-34C759)
![许可证](https://img.shields.io/badge/license-AGPL--3.0-F5A623)

Rex 是一款面向 macOS 的原生桌面浏览器，围绕垂直标签页、工作空间、双页面分屏和默认隐私保护构建。界面由 SwiftUI 与 AppKit 实现，网页平台和扩展运行时由 Chromium Embedded Framework（CEF）提供。

当前版本为 **v1.0.0 build 1001**。项目仍在持续开发中，暂不适合作为覆盖所有使用场景的生产级主浏览器。

## 主要特性

- **原生 macOS 界面**：浏览器外壳、导航、标签页、下载、对话框、设置和扩展管理均由 SwiftUI 与 AppKit 呈现。
- **Chromium 兼容能力**：CEF 151 负责网页渲染、网络、开发者工具、下载、权限和扩展 API。CEF 运行时使用本地全量源码编译版本，开启专有编解码器（H.264/AAC/HEVC），支持抖音等流媒体站点视频播放。
- **垂直标签页与工作空间**：按场景组织浏览会话，避免大量标签页挤在横向栏中。鼠标悬停标签页时显示标题和地址。
- **默认浏览器**：Rex 可注册为 macOS 默认浏览器，从其他应用打开链接时自动激活并在现有窗口创建新标签页。
- **双页面分屏**：在同一个窗口内并排浏览两个页面。
- **隐私盾牌**：清理已知追踪参数、尝试升级 HTTPS、拦截精选请求域名并限制第三方 Cookie。
- **Rex 原生下载界面**：Chromium 负责传输和文件写入，Rex 提供进度、历史记录与文件操作。
- **扩展管理**：通过原生 `rex://extensions` 界面安装、更新、启停、配置和移除受支持的 Chromium 扩展。
- **会话恢复**：自动保存和恢复窗口、标签页、分屏组合和工作空间状态，重启后继续浏览。
- **标签页管理**：固定标签页、标签分组、归档不常用标签页、自动休眠空闲标签页释放内存、恢复关闭的标签页。
- **快捷键**：31 个键盘快捷键覆盖导航、标签、查找、缩放、分屏、开发者工具和资料库操作。
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
Scripts/package-chromium-app.sh 1.0.0 1001 Release
```

产物位于 `Dist/Rex.app` 和 `Dist/Rex-v1.0.0-macos-arm64-chromium.zip`。ad-hoc 签名只用于满足 macOS 嵌套代码的结构要求，不属于 Developer ID 签名、公证或通过 Gatekeeper 的正式分发包。

## 技术架构

| 层级 | 技术 | 职责 |
|------|------|------|
| 应用外壳 | SwiftUI + AppKit | 窗口管理、标签列表、工具栏、设置面板、下载管理、文件选择和对话框 |
| 网页运行时 | CEF 151 / Chromium 151.0.7922.138 | 网页渲染、网络栈、V8 引擎、Blink、扩展 API、开发者工具、GPU 合成 |
| CEF 桥接层 | Objective-C++ | RexChromiumRuntime 统一管理浏览器生命周期、多进程 Helper、扩展运行时对账和 DevTools 管道 |
| 持久化层 | SQLite + Swift | 标签会话、浏览历史、收藏夹、下载记录、网站权限和隐私策略持久化 |
| 隐私引擎 | C++ | 域名目录拦截、请求分类、HTTPS 升级和追踪参数清理 |

CEF 运行时使用本地全量源码编译，GN 参数为 `proprietary_codecs=true ffmpeg_branding=Chrome is_official_build=true chrome_pgo_phase=0 target_cpu=arm64`，H.264/AAC/HEVC 通过 macOS VideoToolbox/AudioToolbox 原生解码。

## 项目结构

```
Rex_project/
├── Sources/RexApp/          # Swift 应用层
│   ├── Application/         # App 入口、窗口协调、菜单和版本管理
│   ├── State/               # BrowserStore 标签页状态机
│   ├── Domain/              # 数据模型、隐私策略、扩展目录
│   ├── Features/            # 标签列表、工具栏、分屏、设置、资料库
│   ├── DesignSystem/        # 液态玻璃面板、工具提示、色彩体系
│   ├── ChromiumIntegration/ # CEF 引擎适配和 App 委托
│   └── Persistence/         # SQLite 持久化层
├── ChromiumBridge/          # Objective-C++ CEF 桥接
│   ├── RexChromiumRuntime   # 浏览器生命周期、事件分发
│   ├── Privacy/             # Thorium 性能参数和隐私引擎
│   └── Tests/               # 桥接层 C++ 测试
├── Chromium/                # CEF 构建配置和版本锁定
├── Vendor/CEF/              # 编译好的 CEF 二进制
└── Scripts/                # 构建、打包、验证和烟测脚本
```

## 许可证

Rex 的原创源代码采用 [GNU Affero General Public License v3.0](LICENSE) 许可。CEF、Chromium 以及其他第三方项目和捆绑组件继续适用各自的许可证与声明。
