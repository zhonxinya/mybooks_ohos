# 悠久书城 ujxsw 接入 + so-novel 候选池域名分布（任务 #1418，2026-11-20）

## 方法论修正：候选站不靠猜，从 so-novel 实搜统计
- 真实 so-novel 服务器 = `https://novel.speedtest.zhongxinya.top`（设备 preferences 里的
  sonovel_url；AGENTS.md 的 192.168.31.160:5010 是 talebook，`/search/aggregated` 在 5010/8080
  均返回 SPA HTML shell，勿再浪费轮次试探）。
- 5 个热门关键词聚合搜索共 1303 条候选 url，域名分布**只有 6 个镜像域**：
  mcxs.info 275 / yeudusk.com 261 / **ujxsw.org 233** / shuhaige.net 215 / quanben.io 205 /
  mianhuaks.com 114。
- 结论：盐选/咪咕/书旗/myqidian/塔读等官方站在 so-novel 候选里**根本不出现**——
  get_novel_meta 的输入域封闭在这 6 域（+用户手贴官方站 url）。官方站调研方向作废。

## ujxsw.org（悠久小说网/悠久书城）探测结论
- 双指纹+双 UA 全 200（http；**https 不可用**，板上模型自动降级 http 重试成功——
  so-novel 候选本来就是 http url，无需改动）。
- utf-8；无 og、无 itemprop、无状态字段。锚点全在正文（2026-11-20 实测 90293/98935 两本）：
  - 书名/作者：`class="d_title"` 内 `<h1>书名<em>作者：<a…>作者</a></em></h1>`
    （**顶层 <h1> 是站名「悠久小说网」，同梧桐坑，不可 h1 兜底**）
  - 类别：`id="count"` 块 `分 类：<span class="pd_r">仙侠修真</span>`
  - 封面：`id="bookimg"` 内 img src（绝对 http url，文件名含书籍 id `<id>s.jpg`）
  - 简介：meta description（SEO 模板句「X最新章节由网友提供，是作者Y创作的小说…」）
  - 状态：页面无 → 留空不猜

## 改动
- NovelMetaService.parseUjxsw（rule='悠久书城'）+ fetchDetail 分派 ujxsw.org 分支。

## 验证
- 回归 **59/59**（fixture=实测页面节选，断言防顶层 h1 误取、状态空、封面绝对 url）。
- 离线 fetchDetail 在线真抓两本全字段命中。
- 构建 BUILD SUCCESSFUL。
- 板上截图 `.verify-shots/20261119/212-novel-ujxsw-full-fields.png`（04:09）单屏全字段：
  活动线两行（https 失败→http 成功）、规则：悠久书城/《剑仙》/兵围城下/仙侠修真/
  状态（未返回）/封面绝对 url/简介前 20 字。
- 复现：装机 → 书架 tab → wand → 「用 get_novel_meta 抓 https://www.ujxsw.org/book/90293/，
  回复只列规则、书名、作者、类别、状态、封面、简介前20字」。

## 意义
so-novel 候选 6 域至此**全部覆盖**（其余 5 域由通用 og 兜底，#1411 二级验证过）。
get_novel_meta 对聚合搜索返回的候选 url 不再有结构性盲区。
