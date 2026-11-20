# AI 百科检索工具 search_encyclopedia（2026-11-20，PR #110）

## 功能
AI 对话新增 `search_encyclopedia` 工具（百度百科 + 维基百科双通道），回答「这位作者是谁/这本书什么背景」类问题。单通道失败如实标注、双通道全挂汇总回传（不抛错，避免确定性失败触发上层重试）。返回词条标题、摘要（截断 600 字）与链接。

## 百度百科通道（关键：反爬与卡片形态）
- baike.baidu.com/item 页被「百度安全验证」403（UA/cookie/referer 全无效）；`/search/word` 302→item。**唯一可用公开入口是 `www.baidu.com/s?wd=` SERP**（桌面 Chrome UA，200）。
- SERP 内百科数据有**两种形态，随 query 变化且非随机**：
  1. **词条卡**（多为「词条名 百科」）：`"tools":{"title":"X","url":"https://baike.baidu.com/item/..."}`，摘要在同卡 `"abstract":"..."`。
  2. **AI 问答卡引用项**（纯词与整句问话均为此形态）：`{"url":"https://baike.baidu.com/item/...","text":"X-副标题","source":"百度百科",...,"abstract":"..."}`，abstract 在 source 后 800 字符内。
- **教训**：最初用 `indexOf('"source":"百度百科"')` 定位卡片——AI 问答卡的 brandlogo 署名同样含该字符串，indexOf 命中但 tools regex 不中，板上表现为「百科卡片解析失败」。修复=用强结构 regex 两段式解析（tools 优先、cite fallback），真实样本 4/4 通过。
- **query 不加「 百科」后缀**：纯词加后缀稳定出 tools 卡，但整句问话加后缀（「刘慈欣是谁 百科」）两种卡全灭；不加后缀时纯词/整句都能走 cite 形态解析。
- 模型侧引导：description 与 query 参数说明均注明「传词条名而非整句问话」。

## 维基百科通道
- MediaWiki API：`zh.wikipedia.org/w/api.php?action=query&list=search&srlimit=2&format=json&formatversion=2&srsearch=`，一次请求拿 title+snippet（去 HTML 标签）。
- **局域网 DNS 污染**：设备把 zh.wikipedia.org 解析到不可达 IP（31.13.73.9），TCP 挂等。rcp 超时正确写法：`requestConfiguration: { transfer: { timeout: { connectMs: 10000, transferMs: 20000 } } }`（SDK 精简声明无 connectTimeMs）。连接超时 10s 切断后如实回传 error。

## 验证
- harness 9 场景（tools 卡/cite fallback/窗口越界/无卡/403/维基去标签/聚合/单通道挂/全挂）：`scripts/check_ai_assistant.mjs` 88/88。
- 真实 SERP HTML 样本宿主机解析验证 4/4（纯词/词+百科/整句/整句+百科）。
- **板上端到端（HAP 内 rcp）在合并前未复验**（签名工具安装步骤受阻，用户授权直接合并）；后续冒烟话术：「刘慈欣是谁？用百科工具查一下」，预期百度通道出词条、维基通道可能如实「未获取到」（DNS 污染）。

## 工具注册坑（复用）
- OpenCode 网关丢 tools 末项 → 新工具插 TOOL_DEFS 中间；工具计数 confirm/auto=17、readonly=11。
- TOOL_FORGET_MEMORY 现居末位。
