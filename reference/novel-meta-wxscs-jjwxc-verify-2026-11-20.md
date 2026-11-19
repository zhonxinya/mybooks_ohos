# 万相书城+晋江接入板上验证（任务 #1417，2026-11-20）

## 探测结论（双指纹）
### 万相书城 www.wxscs.com（清单原判「详情页 403 观察」→ 转正）
- 首页 200/30KB 直出 /book/<id>/ 链接；详情页桌面 Chrome UA **403（Apache 裸 403 非 WAF 壳）**，
  Referer=首页无效；**移动 UA（Pixel Chrome）200/31KB**，curl 与 undici 双指纹全放行。
- 页面 og:novel 全量（property= 写法：book_name/author/category/status=「完结」/update_time/
  latest_chapter_name），og:image 相对路径 `/uploads/cover/pic<id>.jpg`（absolutize 补全）。
- legado 语料里的 wxsc8.com 移动域已失效（302 → js96110 反诈站，域名易主），不可依赖。
- 接入方式：fetchText UA 按站点选择（wxscs.com → MOBILE_UA），解析零改动（og:novel 规则覆盖）。

### 晋江 www.jjwxc.net（清单原判「体量差异+死链 观察」→ 转正）
- 首页 200/72KB 直出活 novelid；onebook.php?novelid=<id>：http 301→https、双指纹 200，
  响应 gzip（rcp 透明解压），**gb18030 编码、charset 声明在字节 240**（decodeBody 4KB 窗口内）。
- 无 og、无 JS 挑战，SSR 直出 **schema.org Book 微数据**：itemprop=articleSection（书名，
  在 h1 内 span）、author、genre（四段串「原创-纯爱-幻想未来-剧情」）、updataStatus（连载/已完结）、
  image（**img 带畸形 `_src="…" src="…"` 双属性**，须用 \ssrc= 只认真实 src）、
  description（div#novelintro，实测本书案 4874 字符才闭合——截断窗口 2000 会整段漏）。
- 接入方式：parseJjwxc 专用规则（rule='晋江'），fetchDetail 分派 jjwxc.+onebook.php。

## 改动
- NovelMetaService：MOBILE_UA 常量 + fetchText 按站点选 UA；parseJjwxc；分派加 jjwxc 分支；头注释更新。

## 验证
- 回归 **58/58**：wxscs 端到端（含「必须移动 UA」「其他站保持桌面 UA」双断言）；
  parseJjwxc 模板串（防 _src 误取、>2000 字符长简介、状态归一、类别原样）；
  晋江真页 gb18030 节选 base64 端到端（全字段+不乱码）。
- 离线真页 fetchDetail：wxscs《新月剑》/司马紫烟/玄幻奇幻/已完本/绝对封面；
  晋江《海岛求生：生活玩家种田囤货》/绯夷/原创-纯爱-幻想未来-剧情/连载中/完整简介。
- 构建 BUILD SUCCESSFUL。
- 板上截图（.verify-shots/20261119/）：
  - `209-novel-jjwxc-rule-line.png`：活动线「规则：晋江，来源 jjwxc」+书名行
  - `210-novel-jjwxc-title-author.png`：书名/作者/类别字段
  - `211-novel-jjwxc-cover-intro.png`：封面绝对 url+简介前 20 字（gb18030 不乱码）
  - wxscs 板上证据=控件树文本（活动线「规则：og:novel，来源 https://www.wxscs.com/book/…」+
    书名/作者/玄幻奇幻/已完本/封面 https://www.wxscs.com/uploads/cover/pic10212.jpg/简介全命中，
    若 UA 特判未生效则抓取直接 403 无输出）；同组件渲染质量由晋江截图代证——
    会话历史 UI 列表滚动回弹严重，未能截到含全部字段的整屏（如实记录）。
- 复现：装机 → 书架 tab → wand → 「用 get_novel_meta 抓 https://www.wxscs.com/book/10212/，
  回复只列规则、书名、作者、类别、状态、封面、简介前20字」（晋江同理换 url）。

## 意义
- 「桌面拦/移动放」后门从起点（换 host）扩展到 UA 维度（同 host 换 UA），rewriteUrl+UA 双通道
  覆盖两类风控形态。
- 晋江=首个 schema.org 微数据锚点站，为无 og 老 SSR 站提供第二条通用路线（先查 itemprop 再写专用规则）。
