# legado 语料下一批镜像站审计：群小说/一页书接入、阅友不可接（任务 #1423，2026-11-20）

## 候选来源
reader_core/test/fixtures/parallel-book-sources.json（1118 源）域名分布统计 top40 +
按任务点名的笔趣阁系/顶点/69 书城逐一存活探测。**探测一批死一批是常态**：
笔趣阁系变体 biquge55.net(ECONNRESET)/biquge.cc·xbiqu.com(lander 停放壳)/2dingdian.net(ENOTFOUND)、
69shuba.com、midukanshu.com、suixkan.com、qubook.org、27k.net、tianmeixs.com 全灭。

## 活站双指纹实测
| 站 | 形态 | 结论 |
|----|------|------|
| 群小说 www.qunxs.com | `/xiaoshuo_<id>.html`，curl 40KB/undici 33KB 全 200 | **og:novel 全量→通用零改动**；双斜杠封面 `qunxs.com//images/…` **GET 200 可加载（HEAD 503 是方法差异，别拿 HEAD 判生死）** |
| 一页书 www.yiyeshu.cc | `/aibooks/<id>.html` 200 70KB | **og:novel 全量→通用零改动**；legado 规则只写 intro/cover 是源作者偷懒，实际 og 齐全（脏 og:title 由 book_name 去尾）；og:read_url 指向 yiyeshu.xyz 变体域不影响解析 |
| 阅友 yueyouxs.com | www=Vue SPA 壳；m 站首页仅备案链接；goway API `/goway/goread/app/book/detail` 需 **HMACMD5 签名**（tmpToken+time+sign 参数） | **不可接**（纯客户端不做签名逆向，番茄先例是零签名才成立） |

## 改动（行为零变更）
- NovelMetaService.ets 头注释补「legado 语料下一批镜像站审计」行（qunxs/一页书通用命中、阅友签名、笔趣阁系死域清单、HEAD/GET 方法差异教训）。
- 回归 +1 用例（66/66）：QX_PAGE/YE_PAGE=真页节选，断言通用 og:novel 端到端、双斜杠封面 url 原样保留、脏 og:title 去尾。

## 验证
- 离线 harness **在线真跑 4 本全字段命中**（qunxs 2 本：COD乙女/被厌弃的男妻；一页书 2 本：重生之宠妻手册/官媛——书名作者类别状态封面简介全对，rule=og:novel）。
- 回归 66/66；构建 BUILD SUCCESSFUL。
- 板上跳过：本轮无解析代码行为变更（通用规则本就覆盖，4 本在线真跑等价取证）；且既有长会话已被工具否认线污染（#1422 振荡取证），上板无增益。

## 结论
通用 og:novel 规则再扩 2 个活镜像域；语料候选池进入消耗期——主流官方站+镜像域+笔趣阁系残党已扫完，
下一批需从语料 top40 更深处（missevan 是广播剧、idejian 是听书，需甄别非网文类）或用户点名站继续。