# 梧桐中文 wtzw 专用规则板上验证（任务 #1415，2026-11-20）

## 改动
- `NovelMetaService.parseWtzw`（www.wtzw.com/book/ID.html 分派）：无 og 标签，锚点全部来自 legado 语料选择器实测转正则——
  - 书名/状态：`class="li_tit"` 块内 `h1>a` + `<i class="tag">已完结</i>`（**顶层 `<h1>` 是「免费小说就在梧桐中文网」站名宣传语，绝不能走 h1 兜底**——语料 `class.li_tit@tag.a` 的层级原因）
  - 作者 `class="sName"`；封面 `class="w_pic"` 内 img src（协议相对 `//cdn.qimao.com/…`，absolutize 补全）；简介 `class="pWorkInformation"` 块
  - 类别页面上没有 → 留空不猜
- 状态「已完结→已完本」归一复用 og:novel 同款逻辑。

## 验证
- 真页离线：《我的少年班》/卿殇/已完本/绝对封面/简介正确。
- 回归 **54/54**（fixture=实测页面节选，断言防顶层 h1 误取、状态归一、类别空）。
- 构建 BUILD SUCCESSFUL。
- 板上截图 `.verify-shots/20261119/207-novel-wtzw.png`（02:33）：活动线「规则：梧桐中文」，回复书名/作者/已完本/https://cdn.qimao.com 封面/完整简介；模型注「类别和字数是空的」「简介的~与省略号来自源页原样保留」。
- 复现：装机 → 书架 tab → wand → 「用 get_novel_meta 抓这个详情页，只调这一个工具：https://www.wtzw.com/book/224292.html」。

## 意义
legado 语料选择器 → 专用正则的转化路线首次走通（#1411 清单里 wtzw 是 rich 规则榜第一），后续同类无 og 站（如 wxscs 若解锁）可复制此法。
