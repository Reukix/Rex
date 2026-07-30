# Rex QA 配置隔离与 2026-07-30 事件记录

## 当前结论

2026-07-30 早期 QA 曾直接启动真实 Rex 配置：
`~/Library/Application Support/Rex`。已知 `03:13-03:33 +0800` 时间窗内可确认有
12 个 Chromium 文件发生写入，范围包括图形缓存、DIPS、网络持久状态和一个网站的
IndexedDB 日志。

真实配置在 `12:45-12:46 +0800` 又发生了后续运行和写入，因此不能用当前文件时间
安全区分 QA 写入与之后的正常使用。未发现可直接采用的旁路备份或本地 Time Machine
快照，本项目不会自动删除、覆盖或回滚该配置。

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
- 直接启动 app bundle 内的 Rex executable，避免 Launch Services 复用真实进程；
- 启动前后比较真实 Rex 配置、preferences、cache、HTTP storage、WebKit、cookies、
  containers、application scripts、logs 和 saved state 的元数据指纹；
- 只向隔离 Rex 的 PID 发送标准 Quit Apple Event 验证正常退出，并检查没有遗留
  Rex Helper；
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
