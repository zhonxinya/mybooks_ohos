# so-novel 镜像域质量审计 + 棉花书吧接入（任务 #1419，2026-11-20）

## 审计方法
10 本活书（6 域各 2 本，url 取自 so-novel 实搜聚合结果）离线实跑 `fetchDetail`，
统计每域 rule 命中与字段完整度。

## 质量矩阵（审计结论）
| 域 | rule 命中 | 书名 | 作者 | 类别 | 状态 | 封面 | 简介 |
|----|-----------|------|------|------|------|------|------|
| mcxs.info | og:novel | ✅ | ✅ | ✅ | 页面无字段 | ✅ | ✅ |
| yeudusk.com | og:novel | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| shuhaige.net | og:novel | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| quanben.io | og:novel | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| ujxsw.org | 悠久书城（#1418） | ✅ | ✅ | ✅ | 页面无字段 | ✅ | SEO 句 |
| mianhuaks.com | 通用og（审计前） | ✅ | ✅ | ❌ | ❌ | ❌默认图 | SEO 句 |

- **修正 #1411 清单第三次**：mcxs/yeudusk/shuhaige/quanben 实际都带 og:novel 全量
  （此前探测正则偏悲观漏判）——通用规则即够，不需专用 parse。
- mcxs 状态空 = 页面确实无 `og:novel:status` 也无正文状态（2026-11-20 实测
  /96_96183/ 全 meta 枚举），非解析 bug，留空不猜。
- **mianhuaks 是唯一真兜底域**：无 og:novel；封面槽多为站默认图 `/asset/default.jpg`；
  「分类」只是 `/tags.html` 导航链接，页面无类别字段。

## mianhuaks.com（棉花书吧）结构（2026-11-20 实测 3 本：/fiction/243044.html 等）
- 真实详情页 url 形如 `https://www.mianhuaks.com/fiction/<id>.html`（so-novel 候选原样；
  `/book/<id>/` 形态 301→404，不存在）。
- 主区 `<section class="… flex items-start">` 内：唯一 `<h1>` 书名（无站名坑）、
  `作者：<a href="/profile/…">`、`状态：连载|完结`、封面 `<img src>`（常为默认图）。
- 简介 `<div id="desc">`：内嵌 `<p>` 与防盗混淆 `<img src='/asset/fonts/45.png'>`、
  `&gt;strong&lt;` 实体——clean 剥标签后正文连贯。
- 推荐区另有 `/thumb/<id>.jpg` 他书缩略图——主区块锚定防误取。

## 改动
- `NovelMetaService.parseMianhua`（rule='棉花书吧'）：主区 block 内取书名/作者/状态
  （连载→连载中、完结→已完本归一）；`default.jpg` 判定为无封面留空；类别留空不猜；
  简介 id="desc" 4000 字符窗口。fetchDetail 分派 `mianhuaks.com`。
- `rewriteUrl`：ujxsw https 端口不通（curl 000），手贴 `https://…ujxsw.org…` 降为 http。

## 验证
- 回归 **60/60**（fixture=实测页面节选；断言默认图不算封面、推荐区不误取、
  导航「分类」不误猜、完结归一、fetchDetail 分派命中、ujxsw https 降级）。
- 真页整页离线实跑 3 本全命中（mh/mh2/mh3.html，非节选）。
- 构建 BUILD SUCCESSFUL。
- 板上（签名安装后，AI 助手会话）：
  - `213-novel-mianhuaks-tool-execution.png`（04:41）：模型实际发起 get_novel_meta
    tool call，活动线「抓书源站详情页：网文元数据获取失败：详情页获…」——
    当时给的 `/book/94801/` url 404（真实路径是 `/fiction/<id>.html`），错误路径正确。
  - `214-novel-tool-hallucination-context.png`（04:39）：同会话另一轮模型声称
    「工具列表里没有 get_novel_meta」并精确列数 15 个工具——**与 04:41 轮自相矛盾**。
    客户端 `AiService:437` 无条件附 `AiTools.definitions()` 全量 16 项，AiTools.ets
    TOOL_DEFS 含 TOOL_GET_NOVEL_META；判定为 deepseek-v4.1-flash 在该长会话上下文中的
    幻觉+自我强化（首轮否认后各轮复读），非代码缺陷。未点「清空」重开会话
    （属用户可见数据，留待用户决定）。
  - 复现：装机 → 书架 tab → wand → 「用 get_novel_meta 抓
    https://www.mianhuaks.com/fiction/243044.html，只列规则、书名、作者、状态、简介前20字」。
    若模型否认工具存在，新开/清空会话后重试即可。

## 意义
so-novel 候选 6 域质量审计收官：4 域通用 og:novel 即够、ujxsw/mianhuaks 已专用规则转正。
get_novel_meta 对聚合搜索候选 url 无结构性盲区，且 6 域字段完整度全部记录在案。
