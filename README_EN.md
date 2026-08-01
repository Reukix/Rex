# Rex

[简体中文](README.md) | English

![Version](https://img.shields.io/badge/version-0.9.9%20Beta-202124)
![macOS](https://img.shields.io/badge/macOS-14%2B-007AFF)
![Architecture](https://img.shields.io/badge/architecture-Apple%20Silicon-34C759)
![License](https://img.shields.io/badge/license-AGPL--3.0-F5A623)

Rex is a native desktop browser for macOS, built around vertical tabs,
workspaces, side-by-side browsing, and privacy protection by default. Its
interface is implemented with SwiftUI and AppKit, while Chromium Embedded
Framework (CEF) provides the web platform and extension runtime.

The current release is **v0.9.9 build 990 Beta**. Rex is under active
development and is not yet intended to replace a production browser for every
workflow.

## Highlights

- **Native macOS interface**: SwiftUI and AppKit own the browser chrome,
  navigation, tabs, downloads, dialogs, settings, and extension management.
- **Chromium compatibility**: CEF 150 renders the web and provides Chromium
  networking, DevTools, downloads, permissions, and extension APIs.
- **Vertical tabs and workspaces**: Organize sessions without compressing tabs
  into a narrow horizontal strip.
- **Split view**: Browse two pages side by side in one window.
- **Privacy shield**: Removes known tracking parameters, attempts HTTPS
  upgrades, blocks curated request domains, and restricts third-party cookies.
- **Rex-managed downloads**: Chromium owns transfers and file writes while Rex
  presents native progress, history, and file actions.
- **Extension management**: Install, update, enable, disable, configure, and
  remove supported Chromium extensions from the native `rex://extensions` UI.
- **No AI layer**: Rex does not include chat, page summarization,
  recommendations, or automated browsing features.

Extension support is substantial but not identical to Google Chrome. Some
Chrome Web Store extensions depend on APIs or native UI behavior that Rex does
not currently implement.

## Requirements

- macOS 14 or later
- Apple Silicon (`arm64`); Intel Macs are not supported
- Xcode with the macOS SDK
- XcodeGen, CMake, and Ninja for the full Chromium build

## Build

Build the lightweight Swift Package preview:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Prepare the full CEF/Chromium application:

```bash
Scripts/fetch-cef.sh
Scripts/build-cef-runtime.sh
xcodegen generate --spec project.yml
```

Create a local Release package without an Apple developer certificate:

```bash
REX_PACKAGE_SIGNING_MODE=adhoc \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
Scripts/package-chromium-app.sh 0.9.9 990 Release
```

Artifacts are written to `Dist/Rex.app` and
`Dist/Rex-v0.9.9-macos-arm64-chromium.zip`. The ad-hoc signature only makes the
nested macOS code structurally valid. It is not a Developer ID signature,
notarization, or Gatekeeper-approved distribution.

## Testing Safety

Automated QA must never launch a built Rex bundle or executable directly and
must not use `open`. Use the isolated smoke-test entry point, which creates a
temporary user profile and mock keychain environment:

```bash
Scripts/run-isolated-rex-smoke.sh
```

Do not point `CFFIXED_USER_HOME` at a real home directory. Existing Rex
preferences, caches, saved state, and `~/Library/Application Support/Rex` are
user-owned data and must not be modified or deleted by test cleanup.

## License

Rex's original source code is licensed under the
[GNU Affero General Public License v3.0](LICENSE). Third-party projects and
bundled components, including CEF and Chromium, remain subject to their own
licenses and notices.
