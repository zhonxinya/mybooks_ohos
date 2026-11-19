# 飞卢 GBK 解码板上验证（任务 #1414，2026-11-20）

## 改动
- `NovelMetaService.fetchText` 拆出 `decodeBody(body)`：先按 utf-8 解码前 **4096 字节**嗅探 `charset=gbk|gb2312|gb18030|big5`（ASCII 在 GBK 里透传，嗅探可靠），命中则用 `util.TextDecoder` 对应编码全量解码，异常回退 utf-8。
- 依据：本机 SDK `@ohos.util.d.ts` 明文声明 TextDecoder 支持 gbk/gb2312/gb18030/big5（比网络文档更硬的证据）；飞卢 b.faloo.com 实测 content-type=gb2312、页面 174KB。
- **关键坑**：飞卢 charset 声明在字节 **2413**——首版嗅探窗口 2048 漏检，板上仍乱码；扩到 4096 后修复。回归补了「charset 落 2~4KB 窗口」的 padding 用例。

## 验证
- 回归 **52/52**（fixture=飞卢实测 meta 行的 gb18030 字节 base64；另含 utf-8 透明性断言 + 2~4KB 布局断言）。
- 构建 BUILD SUCCESSFUL ×2（修复前后各一次）。
- 板上两轮：第一轮（2KB 窗口）模型明确报「全是乱码…GBK/GB2312 按 UTF-8 解码了」并拒绝猜值——失败路径表现也正确；第二轮（4KB 窗口）截图 `.verify-shots/20261119/205-novel-faloo-gbk.png`（01:40）：书名《盘点万界战力等级，论外吓尿诸天》/作者 幽兰翰墨/类别 同人小说/封面 img.faloo.com/完整简介，模型注「状态和字数是空的、简介源页即截断」。
- 复现：装机 → 书架 tab → wand → 「再用 get_novel_meta 抓一次 https://b.faloo.com/1484744.html」。

## 意外发现
- 飞卢页面其实带 og:novel:book_name/author/category（板上 rule=og:novel），#1411 探测漏判是因为其锚点正则只认 property 在前的属性顺序——pickMeta 两种顺序都认。清单文档的「飞卢无 og:novel」结论以板上为准。
