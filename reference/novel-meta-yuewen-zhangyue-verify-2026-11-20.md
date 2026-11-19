# 阅文系/掌阅系官方站手贴 url 场景接入（任务 #1421，2026-11-20）

## 候选来源：legado 语料（1118 源）grep 站名，非凭空猜
塔读 tadu.com、潇湘 xxsy.net、云起 yunqi.qq.com、书旗 t.shuqi.com、掌阅 m.zhangyue.com。
规则字段直接映射到解析锚点（云起/书旗=og:novel 写法、塔读=og:novel、潇湘=class.title@h1 等）。

## 双指纹实测结论（curl+undici 全 200，无 WAF 壳）
| 站 | 详情页形态 | 元数据 | 处置 |
|----|-----------|--------|------|
| 书旗 t.shuqi.com | /book/<id>.html | **og:novel 全量**（status 完结/连载） | 通用规则零改动 ✓ |
| 塔读 www.tadu.com | /book/<id>/ | **og:novel 全量**；og:title 脏尾巴由 book_name 去尾；og:image 双斜杠 `media3.tadu.com//2023/…` 实测 200 可加载 | 通用规则零改动 ✓ |
| 云起 yunqi.qq.com | **/read/<id>/ 是阅读壳无 og**；同 ID /detail/<id> og:novel 全量 | 站内导航链到 read 形态 | rewriteUrl read→detail |
| 潇湘 www.xxsy.net | /book/<id>（17 位长 id） | 无 og，Vue SSR 正文锚点 | parseXxsy 专用 |
| 掌阅 m.zhangyue.com | 未深测 | legado 规则只有简介/目录无书名作者锚点 | 留观察项 |

## 潇湘锚点（实测 /book/37389130704030609）
- 书名：`class="title"` 块内 `<h1>`（**块首是「手机阅读」链接，不可 h1 直兜**——同梧桐/悠久坑）
- 作者：同块 `<span>文 / 挣脱蛛网的蝴蝶</span>`
- 状态/类别：`class="sub-cols"` 内 span 序列——**首 span 是「会员作品」标签非状态**，
  取 连载|完结 归一；类别 `类别：科幻空间`
- 封面：`class="bookprofile"` 内 img `//bookcover.yuewen.com/…`（协议相对升 https）
- 简介：`id="book_intro"` 纯文本（white-space:pre-line），窗口 4000

## 改动
- `NovelMetaService.parseXxsy`（rule='潇湘书院'）+ fetchDetail 分派 xxsy.net。
- `rewriteUrl`：云起 `read/<id>` → `detail/<id>`。
- 头注释补阅文/掌阅系结论。书旗/塔读/云起 detail 零解析改动（通用 og:novel 即中）。

## 验证
- 回归 **63/63**（潇湘 fixture=真页节选断言手机阅读链接不干扰/会员标签跳过/协议相对封面升级；
  云起 rewrite+og:novel 端到端；塔读式脏 title+双斜杠封面 fixture）。
- 离线 fetchDetail 在线真跑 4 站全命中（含 read 壳重写）。
- 构建 BUILD SUCCESSFUL。
- 板上截图（05:36/05:37 单屏全字段）：
  - `216-novel-xxsy-full-fields.png`：规则：潇湘书院/《星际？不慌，我有万界位面！》/
    挣脱蛛网的蝴蝶/科幻空间/连载中/bookcover.yuewen.com 封面/简介前 20 字。
  - `217-novel-yunqi-read-rewrite-full-fields.png`：发 /read/ 壳 url，规则：og:novel
    （来源 read url）/《粟粟》/荆棘之歌/古代言情/连载中/封面/简介——重写路径板上证实。
- 复现：装机 → 书架 tab → wand → 「用 get_novel_meta 抓 <上表 url>，
  回复只列规则、书名、作者、类别、状态、封面、简介前20字」。

## 意义
手贴 url 场景补齐阅文系（云起/潇湘，起点已接）与掌阅系（书旗）三大站；
塔读顺带命中。so-novel 候选 6 域 + 官方站主流清单至此基本无盲区。
