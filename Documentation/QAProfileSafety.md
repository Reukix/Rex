# Rex QA 配置隔离与 2026-07-30 事件记录

## 当前结论

2026-07-30 早期 QA 曾直接启动真实 Rex 配置：
`~/Library/Application Support/Rex`。已知 `03:13-03:33 +0800` 时间窗内可确认有
12 个 Chromium 文件发生写入，范围包括图形缓存、DIPS、网络持久状态和一个网站的
IndexedDB 日志。

真实配置在 `12:45-12:46 +0800` 又发生了后续运行和写入，因此不能用当前文件时间
安全区分 QA 写入与之后的正常使用。未发现可直接采用的旁路备份或本地 Time Machine
快照，本项目不会自动删除、覆盖或回滚该配置。

同日 `22:39:46-22:42:14 +0800` 的下载矩阵 GUI 尝试又因 `/Applications/Rex.app`
与隔离构建使用相同 bundle ID，绕过预期隔离启动了真实 profile Rex，随后还直接启动过
build 981。两次进程均已通过 Cocoa 正常退出，但
`~/Library/Application Support/Rex/Chromium` 下的元数据发生变化。没有删除、恢复或回滚
真实配置；失败证据保留于 `/tmp/rex-download-matrix.gGKMWW` 和
`/tmp/rex-qa-smoke.HmCiQD`。以后不得使用通用 GUI 控制或 Launch Services 操作 Rex QA，
只能使用本文件规定的隔离脚本。

取证期间曾对 `Browser.sqlite` 执行只读 SQLite quick check；数据库返回 `ok`，但 SQLite
仍更新了 `Browser.sqlite-shm` 的文件时间。以后检查活动或最近使用的 SQLite 配置时，
必须先复制数据库、WAL 和 SHM 到隔离目录，再针对副本检查，不能直接打开真实数据库。

## 唯一支持的自动化启动方式

```bash
Scripts/run-isolated-rex-smoke.sh
```

脚本会：

- 拒绝在 Rex 或 Rex Helper 已运行时开始测试；
- 为 `CFFIXED_USER_HOME` 创建独立的 `/tmp/rex-qa-smoke.*` 目录；
- 传入 `REX_QA_ISOLATED=1`；应用只有在该标志与 `/tmp/rex-qa-smoke.*` 固定目录同时
  通过校验时才启用内存偏好，并跳过真实 `com.rex.browser` preferences 与
  `Rex.primaryWindowID` 的读写；
- 仅为隔离 QA 传入 CEF 官方 macOS 测试参数 `--use-mock-keychain`，避免 Chromium
  profile 加密初始化读取或修改用户登录 Keychain；正式 Rex 启动不使用该参数；
- 直接启动 app bundle 内的 Rex executable，避免 Launch Services 复用真实进程；
- 启动前后比较真实 Rex 配置、preferences、cache、HTTP storage、WebKit、cookies、
  containers、application scripts、logs 和 saved state 的元数据指纹；
- 指纹不一致时在保留的 `/tmp/rex-qa-smoke.*` 中写入前后元数据清单与
  `user-owned-metadata.diff`，只列路径、类型、时间、大小和符号链接目标，不读取文件内容；
- 只向隔离 Rex 的 PID 发送标准 Cocoa termination request，要求日志确认
  `CefShutdown()` 完成，并在最多 2 秒的短轮询后检查没有遗留 Rex Helper；
- 成功时只删除自己创建的临时目录，失败时保留隔离 profile 供检查；
- 如果真实配置发生变化，只报告失败，不执行自动回滚。

可传入其他 app 路径和最多 60 秒的运行时间：

```bash
Scripts/run-isolated-rex-smoke.sh /path/to/Rex.app 5
```

需要保留成功测试的隔离 profile 时：

```bash
REX_PRESERVE_QA_PROFILE=1 Scripts/run-isolated-rex-smoke.sh
```

## 恢复边界

如果需要恢复真实配置，必须先由用户明确选择恢复目标和允许丢弃的时间范围，并先创建
完整、可验证的配置副本。没有 QA 前备份时，不应根据 mtime 猜测并替换 Preferences、
Local State、Sessions、扩展 LevelDB 或 Rex SQLite 文件。
