# 番茄小说接入 + OpenCode 网关丢 tools 末项取证（任务 #1420，2026-11-20）

## 番茄小说 fanqienovel.com 探测结论
- 详情页 `/page/<id>` 是 SPA（1.6MB，数据全在 `window.__INITIAL_STATE__`，SSR 无 og/itemprop），
  但**同 ID 的 `/api/book/info?bookId=<id>` 双指纹（curl/undici）裸通、无签名、无 cookie**，
  code=0 时字段全量（2026-11-20 实测 4 本）。→ rewriteUrl 重写走 API，不解析 1.6MB 页面。
- 字段语义（交叉验证钉死）：
  - `creationStatus`：**0=完结、1=连载**——用《皇后重生要谋反》(0，末章「第966章 终章（完）」)
    与《高手下山》(1，末章无完结标记) 交叉验证；`status` 恒 1 无区分度，不可用。
  - `categoryV2`：JSON 字符串（双层编码），**首元素恒为主分类（Dim=10，4 本实测）**。
  - `thumbUrl`：带签名 CDN url（`x-expires` 约 24h 过期）——实时展示够用，不可持久化存储。
  - `abstract` 含换行，clean 压平；`wordNumber`/`lastChapterTitle` 备用。
- 活书 id 来源：首页 SSR 含 23 个 `/page/<id>` 链接（编造 id 会 404，教训同 mianhuaks）。
- legado 语料（1118 源）无番茄规则；WebSearch 环境不可用，路线靠实探发现。

## 改动
- `NovelMetaService.parseFanqie`（rule='番茄小说'）：解析 info API JSON；code!=0 透出 message；
  categoryV2/JSON 解析失败只丢类别不连带其余字段。
- `rewriteUrl`：`fanqienovel.com/page/<id>` → `api/book/info?bookId=<id>`。
- fetchDetail 分派 fanqienovel.com。
- **`AiTools.TOOL_DEFS` 顺序调整**（fix 7fa9c2ee）：末位改为 forget_memory，见下。

## 重大取证：OpenCode 网关丢 tools 数组最后一项
- 现象（#1419 遗留）：模型声称「工具列表里没有 get_novel_meta」并精确列数 15 个工具——
  恰为 TOOL_DEFS 前 15 项、缺末位。本轮板上问「你列表最后一个工具叫什么」，
  模型答 **search_meta（第 15 项）**；reorder 重装后再问，答 **forget_memory（新末位）**
  且模型主动自纠「get_novel_meta 其实在列表里，是第 15 个」——
  **tools 末项被链路丢弃是确定性行为，非模型幻觉**（修正 #1419 的定性）。
- 客户端无过错：chatViaGateway `payload['tools']=attach` 全量 16 项直接 stringify。
  网关（OpenCode Go，ai_provider=opencode）源码不在本机工作区，无法本仓修复。
- 规避：TOOL_DEFS 末位放最低频工具（forget_memory），注释钉死「新增工具不得放末位」。
- 规避有效性板上证实：reorder 后模型**自发**调用 get_novel_meta（用户消息未点名工具）。

## 验证
- 回归 **61/61**（fixture=info API 真实响应 base64，categoryV2 截真首元素；断言
  rewriteUrl、creationStatus 0/1 归一、code!=0 错误透出、非 JSON 兜底、端到端分派）。
- 构建 BUILD SUCCESSFUL（两次：接入 + reorder）。
- 板上截图 `.verify-shots/20261120/215-novel-fanqie-full-fields.png`（05:19）单屏全字段：
  活动线「抓书源站详情页：网文元数据（规则：番茄小说…）」、《武碎星河》/妖夜/
  传统玄幻/已完本/签名封面 url/简介前 20 字。
- 复现：装机 → 书架 tab → wand → 「帮我补全这本番茄小说的元数据
  https://fanqienovel.com/page/7064405896540982309 ，只列规则、书名、作者、类别、状态、封面、简介前20字」。
  （旧会话若仍复读「工具不在列表」，先清空或换会话——历史污染会拖慢模型自纠。）

## 意义
番茄=so-novel 候选池外最大主流免费网文平台，用户手贴 url / search_meta 网文通道场景补齐。
#1419 的「模型幻觉」定性被本轮推翻并修复——真正根因是网关丢 tools 末项，
所有「模型看不到新工具」的历史现象（含 #1416-1418 需点名才调用）得到统一解释。
