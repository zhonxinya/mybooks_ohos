# 起点 qidian.com 接入板上验证（任务 #1416，2026-11-20）

## 探测结论（双指纹）
- www.qidian.com / book.qidian.com：**202/209B probe.js 指纹挑战**（`var buid` + `/C2WF946J0/probe.js`，阅文系风控，curl/undici 皆拦；非 acw_sc__v2 家族）。
- **m.qidian.com/book/ID/：curl 与 undici 双路 200**（119KB），SSR、**og:novel 全量**（property= 写法：category/author/book_name/status=「连载」/update_time/latest_chapter_name），og:image 协议相对 `//bookcover.yuewen.com/…`，书籍 ID 与桌面端相同。
- m.qidian.com 首页 200/76KB 直出书籍链接（探测即用）。

## 改动
- `NovelMetaService.rewriteUrl(url)`：`www|book.qidian.com/book|info/<id>` → `https://m.qidian.com/book/<id>/`（fetchDetail 抓取前重写）。桌面版被 so-novel 书源候选引用时自动走移动版。
- 解析本身**零改动**——og:novel 规则（#1412）直接命中起点。

## 验证
- 回归 **55/55**：rewriteUrl 三断言（www 无斜杠/book info 带斜杠/他站不动）+ m.qidian 真实 meta fixture 端到端（书名/作者/异术超能/连载→连载中归一/协议相对封面补全 https://bookcover.yuewen.com/…）。
- 构建 BUILD SUCCESSFUL。
- 板上截图 `.verify-shots/20261119/208-novel-qidian.png`（03:03）：发**桌面版 url** https://www.qidian.com/book/1050742867/ → 活动线「规则：og:novel」，回复《美利坚：超凡入圣》/白魔星/异术超能/连载中/绝对封面/完整简介；模型注「字数空、【】标签是作者自打的」。
- 复现：装机 → 书架 tab → wand → 「用 get_novel_meta 抓这个详情页，只调这一个工具：https://www.qidian.com/book/1050742867/」。

## 意义
起点是网文第一主流站，此前完全空白；probe.js 挑战不可破但**移动版同 ID 免挑战**是结构性后门。rewriteUrl 通道为后续同类站点（桌面拦/移动放行的站）提供模板。
