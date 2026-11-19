# 语料消耗期第二批：书坊/顶点接入（含顶点 UA 拦截破解）、txt80 不接（任务 #1424，2026-11-20）

## 批量 GET 存活探测（15 域）
活网文站：txt80.cc、sfwx.com、dingdians.com（顶点主域，语料只记了死掉的 2dingdian.net）。
死域再添：zaohuatu/x23us/bgwxc/qiutiandog/wxmmain/xbiquge/sfwx 外的 919yq(1.8KB 可疑小壳)、
0794r(503)、tianxiasy(979B)。类型甄别排除：missevan=广播剧、idejian/ximalaya=听书。

## 双指纹实测
| 站 | 形态 | 结论 |
|----|------|------|
| 书坊 www.sfwx.com | `/\d+/\d+/`，curl 4.7KB/undici 29KB 全 200 | og:novel 全量→通用零改动；协议相对封面 `//www.sfwx.com/images/…` 由 absolutize 按页面协议补全；**语料写 @get JS 而实页 og 齐全（legado 规则≠站点实况第五次验证）** |
| 顶点 www.dingdians.com | `/index/<id>/`，curl/undici 200、og:novel 全量 | 通用零改动 + **两个坑**：①状态值「全本」→并入完本归一；②**按桌面 OS 特征拦 UA**——完整 `Windows NT 10.0…` 串返回 2.5KB「身份验证」JS 壳（fetchText 原桌面 UA 中招，在线真跑当场暴露），移动 UA（Pixel7 串）直出全量→并入 fetchText 按站特判（同 wxscs 先例）。UA 矩阵：完整 Win=拦、短 Win=拦、简 Chrome=放、undici=放、移动=放——**判据=Windows 桌面特征** |
| 八零 www.txt80.cc | `/danmei/txt<id>.html` 200 27KB 无 og | **不接**：TXT 下载站，书名只可靠出现在 SEO title/keywords，简介 description 是「剧情+内容标签+主角配角」拼接文、作者夹在 keywords 逗号串里——元数据价值低，不值得专用规则 |

## 改动
- NovelMetaService：fetchText UA 特判加 dingdians.com（移动 UA）；parseGeneric og:novel 状态归一补「全本」；头注释消耗期第二批审计行。
- 回归 +1 用例（67/67）：SF_PAGE/DD_PAGE 真页节选——书坊端到端+协议相对封面、顶点「全本」→已完本、dingdians 请求头断言 Mobile UA。

## 验证
- 在线真跑 4 本全字段命中（书坊《大明第一国舅》《引狼入室》、顶点《我真不是邪神走狗》[全本→已完本]《1852铁血中华》[连载中]）。
- 关键顺序教训：**fixture 全绿 ≠ 站点可达**——curl/undici 手工探测 UA 与项目 fetchText UA 是第三种组合，必须离线 harness 走真实 fetchDetail 才暴露 UA 拦截（本轮在线复跑当场挂出）。
- 回归 67/67；BUILD SUCCESSFUL×2。板上跳过：长会话污染未变（#1422 振荡取证在案），行为变更已由真实 fetchDetail 在线链路等价取证。

## 结论
通用规则再扩书坊/顶点 2 域。语料 top40 已扫完：接入=qunxs/一页书/书坊/顶点(+前轮全部)，
不可接=阅友(HMAC)/txt80(下载站)，其余死域。候选池至此**实质枯竭**——后续新站以用户点名驱动为宜。