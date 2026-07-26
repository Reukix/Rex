# 隐私盾牌内置请求目录

本文档列出 `ChromiumBridge/Privacy/RexPrivacyEngine.cpp` 当前编译进 CEF 请求层的全部规则。目录共包含 104 条原始规则：45 条广告、41 条追踪、10 条指纹和 8 条社交规则。其中 3 条是 `host + path` 规则，并非纯域名；跨类别去重后共有 101 个不同的规则字符串。

## 广告目录（45 条）

```text
2mdn.net
aax.amazon-adsystem.com
ad.doubleclick.net
adform.net
admob.com
adnxs.com
ads.linkedin.com
ads.pubmatic.com
ads.twitter.com
ads.yahoo.com
adservice.google.com
adsrvr.org
advertising.com
amazon-adsystem.com
an.facebook.com
app-measurement.com
bidswitch.net
casalemedia.com
contextweb.com
creative.ak.fbcdn.net
criteo.com
criteo.net
doubleclick.net
exoclick.com
googleadservices.com
googlesyndication.com
googletagservices.com
ib.adnxs.com
media.net
moatads.com
openx.net
outbrain.com
pagead2.googlesyndication.com
partner.googleadservices.com
pubmatic.com
rubiconproject.com
securepubads.g.doubleclick.net
smartadserver.com
s0.2mdn.net
static.ads-twitter.com
taboola.com
teads.tv
tpc.googlesyndication.com
yieldmo.com
z.moatads.com
```

## 追踪目录（41 条）

```text
amplitude.com
analytics.google.com
analytics.twitter.com
api.segment.io
bat.bing.com
cdn.segment.com
clarity.ms
connect.facebook.net
facebook.net
fullstory.com
google-analytics.com
googletagmanager.com
heap-api.com
heapanalytics.com
hotjar.com
hs-analytics.net
insight.adsrvr.org
log.byteoversea.com
metrics.icloud.com
mixpanel.com
mouseflow.com
newrelic.com
nr-data.net
optimizely.com
pixel.facebook.com
px.ads.linkedin.com
quantserve.com
scorecardresearch.com
segment.com
segment.io
sentry.io
snap.licdn.com
static.hotjar.com
static.ads-twitter.com
stats.g.doubleclick.net
t.co
tiktok.com/i18n/pixel
tr.snapchat.com
www.google-analytics.com
www.googletagmanager.com
www.facebook.com/tr
```

以下两条追踪规则带路径条件：

- `tiktok.com/i18n/pixel`：主机为 `tiktok.com` 或其子域，且 URL path 包含 `/i18n/pixel`。
- `www.facebook.com/tr`：主机为 `www.facebook.com` 或其子域，且 URL path 包含 `/tr`。

## 指纹目录（10 条）

```text
api.fpjs.io
cdn.fpjs.io
device-api.fpjs.io
fingerprint.com
fingerprintjs.com
fpcdn.io
fpjs.io
metrics.icloud.com
clientservices.googleapis.com
deviceid.adobe.com
```

这里的“指纹保护”仅取消已知目录命中的网络请求，不会随机化 Canvas、WebGL、Audio 或其他浏览器指纹表面。

## 社交目录（8 条）

```text
connect.facebook.net
platform.twitter.com
platform.linkedin.com
platform.instagram.com
widgets.pinterest.com
apis.google.com/js/platform.js
s7.addthis.com
w.sharethis.com
```

`apis.google.com/js/platform.js` 是 `host + path` 规则：主机为 `apis.google.com` 或其子域，且 URL path 包含 `/js/platform.js`。

## 匹配语义

- 请求主机和路径先转换为小写。
- 纯主机规则匹配该主机本身及其任意子域，并要求点号边界。例如，`doubleclick.net` 会匹配 `stats.g.doubleclick.net`，但不会匹配 `notdoubleclick.net`。
- `host + path` 规则同时要求主机匹配，并要求 URL path 包含给定路径片段。匹配的是 path，不包含 query，也不是完整路径相等判断。
- 主框架导航不会在此层被取消；第一方来源无法判断时按非第三方处理并放行。
- 标准和严格模式只对第三方请求应用广告、追踪目录。自定义模式在 CEF 中映射为激进模式，会把广告、追踪目录匹配扩展到第一方请求。
- 指纹目录仅在第三方请求且指纹保护开关开启时应用。社交目录仅在第三方请求且保护级别为严格或激进时应用。
- 第三方判断使用源码中的简化 registrable-domain 算法及少量常见二级后缀，不是完整 Public Suffix List。

## 重复项与分类优先级

同一类别内部没有完全相同的规则字符串。以下 3 条规则跨类别重复：

| 规则 | 出现类别 | 实际优先类别 |
| --- | --- | --- |
| `static.ads-twitter.com` | 广告、追踪 | 广告 |
| `metrics.icloud.com` | 追踪、指纹 | 追踪 |
| `connect.facebook.net` | 追踪、社交 | 追踪 |

请求分类顺序为：广告目录 → 追踪目录 → 指纹目录 → 社交目录 → 激进模式路径启发式。首次命中后立即返回，因此上表中的前置类别获胜。社交目录命中后也会上报为追踪类别。

除完全重复外，父域匹配还会产生跨类别覆盖：

- 追踪规则 `insight.adsrvr.org` 会先被广告规则 `adsrvr.org` 命中。
- 追踪规则 `px.ads.linkedin.com` 会先被广告规则 `ads.linkedin.com` 命中。
- 追踪规则 `stats.g.doubleclick.net` 会先被广告规则 `doubleclick.net` 命中。

激进模式另有独立的第三方路径启发式，命中后上报为 `suspiciousScript`；这些路径片段不计入上述 104 条目录规则。
