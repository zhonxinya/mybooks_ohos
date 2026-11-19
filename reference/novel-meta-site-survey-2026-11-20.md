# 网文元数据源站点调研清单（任务 #1411，2026-11-20）

## 方法
1. **开源书源语料**：`reader3_srever/docs/bookSource.json`（legado 规则 1118 条），按 `ruleBookInfo` 同时带 `intro`+`coverUrl` 选择器计数排序取 top25，得到"社区已解明详情页锚点"的候选站。
2. **官方主流站**补充：纵横/飞卢/晋江/刺猬猫/磨铁/榕树下/QQ阅读起点网页等。
3. **双指纹可达性**：curl(TLS-A) 与 node undici(TLS-B) 各 GET 首页，max-time 9s，记录状态码/长度/标记。
4. **二级详情页验证**：对可达站取示例详情页，检查 og:novel:* 全量元标签 / og:description / 语料 CSS 选择器实证命中、charset、WAF 特征。

探测脚本：`.tmp/nm_probe.mjs`（32 站首页）、`.tmp/nm_probe2.mjs`（12 站详情页），结论以实测为准。

## 已支持（排除）
17k.com（专用规则）、quanben.io / mcxs.info / shuhaige.net / mianhuaks.com / yeudusk.com（通用 og 兜底）、ujxsw.org（og 缺失）、so-novel 聚合通道自带类别/状态/字数。

## 可支持清单（第一批实施候选）

| 站点 | 可达性(双指纹) | 详情页 SSR | 锚点 | 结论 |
|------|----------------|------------|------|------|
| m.kujiang.com 酷匠 | 200/200 | ✅ 17KB | og:novel 全量(author/book_name/status/update_time/latest_chapter_name)+ogdesc+og:image 绝对 URL，UTF-8 | **#1412 首选** |
| www.ciweimao.com 刺猬猫 | 200/200 | ✅ 107KB | og:novel 全量(category/author/book_name/read_url)+ogdesc+og:image，UTF-8 | #1412 同规则覆盖 |
| www.rongshuxia.com 榕树下 | 200/200 | ✅ 182KB | og:novel 全量+ogdesc+og:image(bookcover.yuewen.com)+作品类别 cn-label，UTF-8 | #1412 同规则覆盖 |
| b.faloo.com 飞卢 | 200/200 | ✅ 162KB | ogdesc/og:image 有但 **GBK 乱码**（charset=gbk） | #1414：需字符集解码路线 |
| www.wtzw.com 梧桐中文 | 200/200 | ✅ 118KB | 无 og；语料选择器实测 author=class.sName、cover=class.w_pic(协议相对 //cdn.qimao.com)、intro=class.pWorkInformation 全部命中 | 次批，专用规则 |
| www.wxscs.com 万象书城吧 | 首页 200 有 og:novel 模板 | ❌ 详情页 403 | 首页过、详情页拦 | 观察（或需 Cookie） |
| www.jjwxc.net 晋江 | 双指纹体量差异大(12KB vs 69KB) | ⚠️ novelid=10 死链 1.4KB | 老 SSR PHP 站 | 观察：活样本+编码需再验 |
| www.zongheng.com 纵横 | 200/200 | ⚠️ 58KB 无 og | 疑似部分 JS 壳 | 观察：需专用规则调研 |
| m.suixkan.com / sma.yueyouxs.com / www.bixiange.top | 首页 200 | ❓ 首页抓不到详情链接形态 | 链接在 JS 数据里 | 弃（性价比低） |

## 明确不可行（拒入清单）
- 503/证书/拒连/超时：0794r.com(503)、liyuxiangku.com(TLS 证书)、qiutiandog.com(拒连)、yeban360.com(reset)、92popo.cc(reset)、yuyouku.com(超时)、xqishuta.net(拒连)、22mt.net(reset)、ip.33xs.com(超时)、isex.work(超时)
- 状态码拦：soshu8.com(521/undici ERR)、flydoing.com(403)
- JS 壳/空页(首页体量<1KB 或空)：so.html5.qq.com(200/0)、api-bc.wtzw.com(200/0)、motie.com(796B)、dbxsd.com(705B)、tatays.com(311B)、qmbook.taoyuewenhua.net(39B)、yiyeshu.cc(11KB 无锚点)
- **bixiange.top：仅 curl 可达、undici 被拒**——rcp TLS 栈与两者皆不同，此类站必须板上实测才算数（双指纹差异警报）。

## 对后续任务的直接结论
1. **#1412 应实现「og:novel:* 通用规则」**：`<meta property="og:novel:book_name|author|category|status|update_time|latest_chapter_name">` + 现有 og:description/og:image，一次拿下酷匠/刺猬猫/榕树下三个官方站（全 UTF-8、无 WAF、纯 SSR）。现有 parseGeneric 只读 og:description/og:image，需扩展 og:novel 解析。
2. 飞卢(#1414)与纵横：前者需 GBK 解码（rcp 返回 utf8 字符串会乱码，考虑 `TextDecoder('gbk')` 或 iconv-lite 移植路线），后者需专项锚点调研。
3. 梧桐中文(wtzw)可复用 legado 选择器转正则（`.sName`、`.pWorkInformation`、`//cdn.qimao.com` 协议相对封面——absolutize 已支持）。
4. 搜索引擎/聚合站路线不变：so-novel 聚合已兜住 265 条书源候选，本清单是给 get_novel_meta 的 url 提供"哪些详情页值得抓"的先验。
