# 纵横 zongheng.com 接入板上验证（任务 #1413，2026-11-20）

## 结论：#1411「纵横无 og、疑似 JS 壳」是误判
- 实测 www.zongheng.com/book/1435440.html：Nuxt SSR 直出、UTF-8、**og:novel 全量**（book_name/category/author/read_url/update_time/latest_chapter_name/latest_chapter_url/status）。
- 漏判根因：#1411 探测脚本锚点正则只认 `property="og:novel:*"`，而纵横用 `name="og:novel:*"` 写法。项目 pickMeta 本就两种都认，故 **og:novel 规则（#1412）零改动即覆盖纵横**。

## 实际改动
- `NovelMetaService.unwrapBrokenContent(raw)`：纵横 SSR 缺陷——og:description 值被模板二次包壳成 `content=&quot;…&quot;`，解析前剥壳；其余站不受影响（仅值以 content=" / content=&quot; 开头才动）。
- parseGeneric 注释更新（覆盖站清单加纵横/飞卢，注明 name=/property= 两种写法）。

## 验证
- 回归 **53/53**：新增纵横 fixture（真实 name= 写法 + 脏壳 description），断言 rule=og:novel、书名齐天/作者日落红尘/类别玄幻奇幻/状态连载中、intro 以「纵横小说网提供」开头且无 `content=` 壳无尾引号。
- 真实页面离线复验：intro 头尾干净（`…量大管饱！】`结尾）。
- 构建 BUILD SUCCESSFUL；板上截图 `.verify-shots/20261119/206-novel-zongheng.png`（02:03）：《齐天》全字段可读，模型主动提出「简介开头是站点宣传语，写进书架前可截掉，只保留【大长篇爆火玄幻】往后」——脏壳修复+站宣语识别都到位。
- 复现：装机 → 书架 tab → wand → 「用 get_novel_meta 抓这个详情页，只调这一个工具：https://www.zongheng.com/book/1435440.html」。

## 方法论修正（写进后续探测纪律）
探测脚本的正则必须兼容 meta 属性两种顺序与 property/name 两种属性名，否则清单漏判（飞卢、纵横两次踩同一坑）。
