# Chromium GUI 下载实机矩阵

此矩阵只允许通过 `Scripts/run-isolated-download-matrix.sh` 执行。脚本复用
`run-isolated-rex-smoke.sh`，使用 `/tmp/rex-qa-smoke.*` 的独立 profile、CEF
`--use-mock-keychain`，把文件固定保存到该次 profile 内的 `Downloads/Rex`，并在
启动前后比较真实 Rex 数据的元数据指纹。不得直接运行 App、使用 `open`，也不得在已有
Rex/Helper 进程存在时绕过拒绝逻辑。

## 执行

```bash
Scripts/run-isolated-download-matrix.sh /absolute/path/to/Rex.app
```

推荐每个样本使用一次独立运行，减少 Chromium 原生窗口与测试页面之间的焦点切换：

```bash
Scripts/run-isolated-download-matrix.sh /absolute/path/to/Rex.app installer.pkg
```

第二个参数可取 `safe.pdf`、`installer.pkg`、`setup.sh`、`invoice.pdf.command` 或
`photo.png`。脚本会直接打开该下载，并只核对该样本的 HTTP 请求；省略参数则保留五项
完整矩阵模式。在 60 秒窗口内记录构建、macOS、CEF/Chromium 版本、时间和截图。磁盘
文件与下载资料库只检查隔离 profile。驱动会核对 loopback 日志，
所选样本没有收到 HTTP 请求时直接失败，不允许把未执行的矩阵记为通过。测试服务统一
返回 `Content-Disposition: attachment`，确保直接打开单个样本时也进入下载流程。

| 样本 | Chromium 元数据 | Rex 预期 | 结果 |
|---|---|---|---|
| `safe.pdf` | PDF + `application/pdf` | Chromium 完成传输，Rex 映射进度和终态 | 待实机 |
| `installer.pkg` | 安装包 MIME | 同上，不由 Rex 暂停或恢复 | 待实机 |
| `setup.sh` | shell MIME | 同上，不由 Rex 重放请求 | 待实机 |
| `invoice.pdf.command` | 双扩展名 | 同上，保留 Chromium 文件名 | 待实机 |
| `photo.png` | 扩展名 PNG + `text/html` | 同上，保留 Chromium MIME | 待实机 |

通过条件：五项都由 Chromium 完成请求、重定向、传输与落盘，不显示 Chromium 原生保存
或下载浮层；新下载开始时 Rex 右侧模块自动弹出并显示相符的文件名、进度和终态，同一任务
后续更新不重复弹出；退出后无 Rex Helper 残留，真实用户数据指纹不变。
该结果不等同于恶意软件、信誉、代码签名或公证扫描。
