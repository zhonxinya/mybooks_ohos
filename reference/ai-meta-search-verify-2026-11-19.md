# AI 元数据搜索（search_meta）验证记录（2026-11-19）

分支 feature/ai-meta-search（叠在 feature/ai-soul-memory 之上；灵魂 PR 合并后本分支 diff 自动干净）。
设备：Pura70Pro 无窗口模拟器，服务商 OpenCode (Go)，Test Server 192.168.31.160:5010。

## 站点可达性调研（curl 实测，2026-11-19）
| 通道 | 结果 |
|---|---|
| www.qidian.com/sos | ❌ 云盾 202 JS 挑战（probe.js），纯 rcp 不可接 |
| m.qidian.com/soushu | ❌ CSR Vue 壳无数据 + yw_risk_verify 风控签名 |
| m.qidian.com API | ❌ 301/需签名 |
| so-novel 聚合 | ✅ 可用但当前书源列表无起点源（quanben/书海阁/悦读库/悠久）；用户可自行导入起点书源规则 |
| book.douban.com/j/subject_suggest | ✅ 200 JSON 无验证（桌面 UA），type=b 过滤图书 |
| book.douban.com/subject/{id}/ | ✅ 200 HTML，v:average 评分、info 块出版社/ISBN/页数/装帧/定价、intro 简介全部可解析 |
| googleapis Books / openlibrary | ❌ 本机与设备网络均不通（国内） |
| baike.baidu.com/api/search | ⚠️ 302（未接，refer 通道已覆盖百度百科） |

**结论**：起点无直连路径；search_meta 三通道 = 豆瓣直连（新）+ 服务端 refer（豆瓣/百度/亚马逊/新华）+ so-novel 网文源。

## 实现
- `MetaSearchService.ets`：suggest（8 条上限、过滤非 b 类型）、detail（正则解析 v:average/v:itemreviewed/info 标签对/intro 取最长）、rcp GET + 桌面 UA、非 2xx 抛错降级。
- `AiTools.search_meta`：subject_id→详情；book_id→searchRefer（候选缓存与 set_cover 共享）；query/isbn→suggest+so-novel；分组输出；读工具不过写闸门。
- SYSTEM_PROMPT 补 search_meta 说明。

## 回归与构建
- `node --experimental-strip-types scripts/check_ai_assistant.mjs` → **42/42**（新增 2 用例：suggest/detail 解析含 403 降级、三通道聚合+空参引导+闸门断言；工具数断言 14→15）。
- 构建 BUILD_OK；签名见 "Sign Hap success"；装机 AppMod finish。

## 板上步骤与截图（.verify-shots/20261119/）
| 截图 | 状态 | 复现 |
|---|---|---|
| 130_search_meta_douban.png | 「用 search_meta 查《三体》刘慈欣，告诉我豆瓣评分和出版社」→ 两条活动线（suggest 出 subject_id=2567698+真实封面 URL；detail 出 **8.9/重庆出版社(2008年1月)/ISBN 9787536692930/302页/平装/23.00元**）→ AI 主动提议补到书架 | 对话页清空后发送 |
| 131_search_meta_refer.png | 「查 id=1481 的多源候选」→ 12 条候选（豆瓣/豆瓣V2/百度百科/悠久小说网+出版社列）→ AI 主动识别第 12 条是同人《从三体逃到超神》非同一本 | 同对话续问 |

## 备注
- 起点元数据如后续要接：唯一现实路径是**用户在 so-novel 服务导入起点书源规则**，search_meta 的网文源通道自动透传（含最新章节/更新状态）。
- 豆瓣 suggest 接口是搜索框联想老接口（无鉴权、返回紧凑 JSON），若未来豆瓣加验证需切 subject 页搜索解析。
