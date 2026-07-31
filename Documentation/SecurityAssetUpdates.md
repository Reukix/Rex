# 安全资源在线更新

Rex 把隐私目录和 Mozilla PSL 作为同一个签名安全资源版本选择，避免 Swift 站点策略与
CEF 请求分类跨版本。随 App 发布的 `privacy_catalog.json` 与
`public_suffix_list.dat` 始终是可审计、可离线使用的基线。

## 信任与配置

更新 manifest 的 trust domain 固定为 `com.rex.browser.security-assets`，使用独立的
Ed25519 公钥。Release 构建通过忽略的 `Configuration/RexSigning.local.xcconfig`
映射以下值：

```xcconfig
REX_SECURITY_ASSET_ENDPOINT = https://updates.example.com/rex/security-assets
REX_SECURITY_ASSET_PUBLIC_KEY = <32-byte Ed25519 public key, base64>
```

两个值缺一、格式错误或仍为空时，应用不会发起更新请求。私钥不得进入 Xcode build
setting、App bundle、仓库或日志。应用更新使用另外的
`REX_APP_UPDATE_ENDPOINT` / `REX_APP_UPDATE_PUBLIC_KEY` 与
`com.rex.browser.application-update` trust domain，不能复用安全资源签名结论。

## 包格式

HTTPS 目录只允许四个文件：`manifest.json`、`manifest.sig`、
`privacy_catalog.json`、`public_suffix_list.dat`。`manifest.sig` 是对
`manifest.json` 原始字节的 Ed25519 签名，经 Base64 编码。manifest schema 1 包含：

- 单调递增 `sequence`、`issuedAt`、`expiresAt` 和 `minimumBuild`；
- 两个资源各自固定 kind/filename、版本、字节数和 SHA-256；
- 可选签名控制：强制 bundle、回退到已验证 sequence、吊销 sequence、暂停更新截止时间。

客户端拒绝未知顶层/资源字段、错误 purpose/schema、未来签发、过期候选、低于当前 build、
超限、重复 kind、错误文件名、符号链接、非普通文件、哈希/大小/格式错误和不递增 sequence。
已成为 LKG 的包离线时可在 manifest 到期后继续使用；过期只阻止新安装。

## 状态与回退

状态位于隔离 profile 的 `Application Support/Rex/SecurityAssets`：

```text
SecurityAssets/
  packages/<sequence>/
  state.json
```

下载先进入同一根目录的随机临时目录，完整复验后原子改名。安装只登记 candidate；下一次
真实启动才切换为 active，并写入 validation-pending。CEF 同时解析 PSL 与隐私目录且成功
初始化后清除 pending 并加入 known-good。进程在此之前失败，或下一次启动仍发现 pending，
会把该 sequence 记为失败并回到最高的未吊销 known-good；没有 LKG 时回到 bundle。
进程单例把启动交给已有 Rex 时，候选会恢复为 candidate，不会被误判为启动失败。

生产发布仍需提供 HTTPS 托管、独立离线私钥流程和轮换/吊销操作手册。仓库当前不包含生产
端点、公钥或私钥，因此本地 build 的联网路径默认关闭。
