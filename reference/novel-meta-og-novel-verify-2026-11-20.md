# og:novel:* 通用规则板上验证（任务 #1412，2026-11-20）

## 改动
- `NovelMetaService.parseGeneric`：详情页含 `og:novel:book_name` 时走结构化规则（rule='og:novel'）——
  书名/作者/类别取 `og:novel:*` 字段（弃带「最新章节-站名」尾巴的 og:title），状态「完结|完本→已完本、连载→连载中」归一，
  缺字段留空不猜；无 og:novel 时维持原松散 og 兜底逻辑不变。
- 覆盖站点（#1411 实测清单）：m.kujiang.com、www.ciweimao.com、www.rongshuxia.com。

## 验证
- 回归：`node --experimental-strip-types scripts/check_ai_assistant.mjs` → **51/51**
  （新增 2 断言组：酷匠 fixture 书名/作者/已完本归一/`<br/>`不断句；刺猬猫 fixture 去站名尾巴/无 status 字段不瞎猜；
  get_novel_meta 端到端行含「规则：og:novel」）。fixture 全部取自 2026-11-20 实测页面节选。
- 构建：`./scripts/build-hap.sh` 日志含 BUILD SUCCESSFUL（判定用 grep，不信 exit code）。
- 板上（截图 `.verify-shots/20261119/204-novel-ogkujiang.jpeg`，01:07）：
  发「用 get_novel_meta 抓这个详情页的元数据，只调这一个工具：https://m.kujiang.com/book/91737」→
  活动线「抓书源站详情页：网文元数据（规则：og:novel…）」，回复含
  书名《灯下黑》/作者 鱼不语/**状态 已完本**（页面原文「完结」）/封面 kjcdn 绝对 url/完整简介；
  模型并自主补充「这个页面没给类别和字数（字段是空的）」——缺字段不猜的行为在回复侧同样成立。
  复现：装机后书架 tab→wand→输入上述指令。

## 已知边界
- 酷匠 og:description 实为人物台词摘录而非剧情梗概（页面如此，非解析问题）。
- 飞卢 b.faloo.com 有 og 锚点但 GBK 编码（#1414 处理）；梧桐中文 wtzw 无 og、走语料选择器专用规则（次批）。
