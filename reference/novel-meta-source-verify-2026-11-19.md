# 网文元数据源——板上验证记录（2026-11-19）

## 需求
用户：「新增更多 小说，网文元数据源，避免 豆瓣找不到」；方向确认「仍尝试硬写几个网文源」；
并纠正「so-novel 只是小说下载，不包含元数据」。

## 调研收口
- search.17k.com 被阿里云 WAF acw_sc__v2 JS 挑战拦死（curl 405、undici 200 挑战页、混淆脚本带
  完整性自检不可沙箱模拟）→ **放弃站内搜索**。
- 实测 so-novel 聚合搜索 `/search/aggregated?kw=` 返回体本就带
  sourceId/sourceName/url/bookName/author/category/status/wordCount/latestChapter——
  「书源已经不少，主要是没被用上」：类别/状态/字数此前被行模板丢掉，简介/封面确实没有。
- 17K 书详情页 www.17k.com/book/ID.html 无 WAF、全字段服务端渲染（window.$__BOOK、og:image、
  og:description、.label 状态角标、作品类别表格）。
- 镜像书源站（quanben.io/mcxs/shuhaige/mianhuaks/yeudusk）详情页普遍带 og:description/og:image，
  作通用兜底规则；封面可能是相对路径需按页面 url 补全。

## 方案
- `services/NovelMetaService.ets`：fetchDetail(url) → parse17k / parseGeneric，含 WAF 挑战页识别、
  相对封面补全、实体还原（&lt;br&gt;→换行）。
- `AiTools`：新只读工具 `get_novel_meta`（url 必填）；`search_sonovel` 行模板补 类别/状态/字数
  （SoNovelSearchItem 加 wordCount）；search_sonovel/search_meta 描述同步新链路。

## 回归
50/50（+3 用例：17K 全字段解析含导航「完本小说」不得误判、通用 og+相对封面+WAF 识别+非法 url、
get_novel_meta 工具链路与行模板字段）。

## 板上验证（127.0.0.1:5555，签名包 23:43）
| 截图 | 状态 | 复现 |
|------|------|------|
| 200_get_novel_meta_17K解析成功.png | 17K 专用规则 | 发「用 get_novel_meta 抓取 https://www.17k.com/book/1018082.html…」→ 活动线「抓书源站详情页：网文元数据（规则：17K小说网…）」→ 回复含 类别：东方玄幻/连载状态：连载中/完整简介 |
| 201_书源卡片行带类别状态字数.png | 行模板新字段 | 发「网文源里搜《诡秘之主》…」→ 8 条书源卡片行带 类别/连载/字数（如 书海阁(id=1)，类别…字数：956万字）|
| 202_诡秘之主_通用og补全成功.png | 通用 og 规则 | 同一问的下半屏：活动线「规则：通用og，来源 shuhaige」→ 回复含封面 url + 蒸汽与机械…完整简介 |

- 板上端到端证实：模型能自主走 search_sonovel → get_novel_meta 链，并把多书源字段差异作比较推理
  （「同源的几处标着连载，并显示 12月1日新番外发布」）。
- 网关当日仍偶发长请求超时，与本次改动无关（页面在场同样复现）。
