# 掌阅 m.zhangyue.com 观察项闭环（任务 #1422，2026-11-20）

## 探测过程（决策树四步全走完）
1. **活书 url 从站内取**：m.zhangyue.com 首页 SSR 直出 `/detail/<数字id>` 链接（10161848/11105315/11281768/11284901），不自造。
2. **双指纹**：curl(移动 UA) 200 32KB、undici(桌面 UA) 200 27KB，全通无 WAF，UA 不敏感。
3. **枚举全部 meta property**：无 og/og:novel——只有 name=description/keywords（SEO 字段，书名带[精品]尾巴不可直接用）。
4. **形态/API 切换不成立**（SSR 已直出，无 JSON-LD），落第④步专用 parse。

## 正文锚点（三本书交叉验证一致）
- 主信息限定 `class="bookview"` 块（至 `</dl>`）——**推荐区「同类好书/作者其他书籍」也有 dl/dt/「连载中|已完结」tag，全站匹配必误取他书**
- 书名 `<dt class="ellipsis2">`；作者 `class="it red"`（同行前置=出版方，如「春芒文化 | 似水无痕」）；类别 `data-js="goCategory"` span（该串还在 JS 绑定代码出现，限定块内唯一）
- 封面 `class="bookcover"` img=绝对 https CDN（bookbk.img.zhangyue01.com，带 ?v= 参数可加载）
- 简介 `data-js="brief_intro_txt"` p，剥「内容简介：」前缀
- **状态：主区无字段——留空（同 mcxs 先例）。`<title>` 的「完结小说_都市免费小说」是 SEO 固定模板，与真实类别/状态无关（古代言情书也写「都市」、4997 章连载书也写「完结小说」）——绝不能取**

## 改动
- NovelMetaService.parseZhangyue（rule='掌阅小说网'）+ fetchDetail 分派 `m.zhangyue.com/detail` + 头注释掌阅行。

## 验证
- 回归 **65/65**：ZY_PAGE=真页节选，断言推荐区他书不干扰、title SEO 模板不当状态、出版方不混作者、「内容简介：」前缀剥离、端到端分派。
- 离线 harness 在线真跑 3 本全字段命中（雪落红炉/哈利波特完整系列/废柴逆天召唤师，书名作者类别封面简介全对，状态空）。
- 构建 BUILD SUCCESSFUL。

## 板上结果（如实：工具执行线未完成，与本次改动无关）
- 装机启动成功、对话链路通。但该长会话历史已含 #1419 拒绝线+纠正线双方言论，模型对工具列表出现**跨轮自反振荡**：先否认 get_novel_meta →诊断轮答「共 16 个、末位 forget_memory、倒数第二 get_novel_meta」（=全量送达，且自认前错）→再一轮翻供「只有 15 个没有它」。证据截图 218-novel-zhangyue-tool-oscillation.png。
- 定性：长会话上下文污染不可诊断化（每轮都能自翻），非本轮代码变量——parseZhangyue 分派在客户端、65/65 回归与 3 本在线真跑已覆盖；工具执行线有 #1420-21 三张截图（215/216/217）背书。
- 强化建议 #1551：板上需要「新建会话」能力，被污染的长会话无法自救。

## 结论
掌阅=接入成功（专用规则）；主流官方站清单至此闭环（起点/云起/潇湘/书旗/塔读/番茄/掌阅），无「不可接」遗留。