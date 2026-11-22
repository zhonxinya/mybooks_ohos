/**
 * AI 工具定义区（拆分自 AiTools.ets）：结构化行解析、OpenAI function schema 接口、
 * 28 个工具的 define 常量与 TOOL_DEFS 登记表。本文件无运行时依赖（纯数据 + 小函数）。
 */
/** 工具结果里的一本书（供对话页做结构化列表渲染）。 */
export interface ToolBookLine {
  title: string;
  subtitle: string;
  /** 封面相对路径（服务端书库有图时填充；文本解析路径为空串）。 */
  cover: string;
}

/**
 * 把列表类工具输出（`- [前缀] 《书名》 附加信息` 行模板）解析成结构化条目。
 * 约定即格式：search_books / search_sonovel / list_download_tasks 的行模板改了要同步这里。
 */
export function parseToolBookLines(text: string): ToolBookLine[] {
  const lines: string[] = text.split('\n');
  const books: ToolBookLine[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (!line.startsWith('- ')) {
      continue;
    }
    const body: string = line.substring(2);
    const open: number = body.indexOf('《');
    const close: number = body.indexOf('》');
    if (open < 0 || close <= open) {
      continue;
    }
    const prefix: string = body.substring(0, open).trim();
    const suffix: string = body.substring(close + 1).trim();
    books.push({
      title: body.substring(open, close + 1),
      subtitle: prefix.length > 0 ? `${prefix} ${suffix}` : suffix,
      cover: '',
    });
  }
  return books;
}

/** 工具参数的单个属性 schema（OpenAI JSON Schema 子集）。 */
export interface AiToolProperty {
  type: string;
  description: string;
}

export interface AiToolParameters {
  type: string;
  properties: Record<string, AiToolProperty>;
  required?: string[];
}

export interface AiToolFunctionBody {
  name: string;
  description: string;
  parameters: AiToolParameters;
}

/** 请求体 `tools` 数组的一项。 */
export interface AiToolDefinition {
  type: string;
  function: AiToolFunctionBody;
}

/** 工具目录条目（设置页渲染用）。 */
export interface AiToolItem {
  name: string;
  summary: string;
  /** 是否写操作（执行前需用户确认）。 */
  write: boolean;
}

/** 工具目录分组。 */
export interface AiToolGroup {
  title: string;
  items: AiToolItem[];
}

export const SEARCH_LIMIT: number = 8;
export const NOTE_LIMIT: number = 20;
export const HISTORY_LIMIT: number = 10;
export const INTRO_MAX: number = 500;

/** ArkTS 不接受嵌套匿名对象字面量：每层显式声明类型，逐件构造。 */
function prop(type: string, desc: string): AiToolProperty {
  const p: AiToolProperty = { type: type, description: desc };
  return p;
}

function defineTool(name: string, desc: string, props: Record<string, AiToolProperty>,
  required: string[]): AiToolDefinition {
  const params: AiToolParameters = { type: 'object', properties: props, required: required };
  const body: AiToolFunctionBody = { name: name, description: desc, parameters: params };
  const def: AiToolDefinition = { type: 'function', function: body };
  return def;
}

export const EMPTY_PROPS: Record<string, AiToolProperty> = {};
export const NO_REQUIRED: string[] = [];
export const BOOK_ID_PROP: AiToolProperty = prop('number', '书籍 id（整数）');

export const QUERY_PROPS: Record<string, AiToolProperty> = { 'query': prop('string', '书名或关键词') };
export const BOOK_ID_PROPS: Record<string, AiToolProperty> = { 'book_id': BOOK_ID_PROP };

export const TOOL_SEARCH_BOOKS: AiToolDefinition = defineTool('search_books',
  '在用户的在线书架（MyBooks/Talebook 服务器）中按关键词搜书，返回最多 8 条 {id, 书名, 作者}。' +
    '用户问“书架上有没有/想找某本书”时使用。', QUERY_PROPS, ['query']);
export const TOOL_BOOK_DETAIL: AiToolDefinition = defineTool('book_detail',
  '按书籍 id（先由 search_books 得到）返回该书的作者、评分、标签、出版社/ISBN/丛书、可下载格式与截断后的简介。',
  BOOK_ID_PROPS, ['book_id']);
export const TOOL_BOOK_NOTES: AiToolDefinition = defineTool('book_notes',
  '按书籍 id 返回当前用户在该书下的私有标注（高亮/笔记/书签），最多 20 条。', BOOK_ID_PROPS, ['book_id']);
export const TOOL_READING_HISTORY: AiToolDefinition = defineTool('reading_history',
  '返回用户本机最近的阅读记录（最多 10 条）：书名、当前章节、进度百分比、最近阅读时间。无需参数。',
  EMPTY_PROPS, NO_REQUIRED);

export const SONOVEL_LIMIT: number = 8;
export const TASK_LIST_LIMIT: number = 10;
export const BOOKLIST_DEFAULT_COLOR: string = '#1890ff';

export const BOOKLIST_CREATE_PROPS: Record<string, AiToolProperty> = {
  'name': prop('string', '书单名称'),
  'description': prop('string', '书单简介，可留空'),
};
export const BOOKLIST_ADD_PROPS: Record<string, AiToolProperty> = {
  'booklist_id': prop('number', '书单 id（create_booklist 返回）'),
  'book_ids': prop('string', '逗号分隔的书籍 id，如 "12,44"（来自 search_books 的 id）'),
};
export const SONOVEL_TASK_PROPS: Record<string, AiToolProperty> = {
  'book_name': prop('string', '小说名'),
  'url': prop('string', '书源站详情页 url（来自 search_sonovel）'),
  'author': prop('string', '作者（来自 search_sonovel），可留空'),
  'cover': prop('string', '封面图 url（先调 get_novel_meta 拿封面），可留空；缺失时系统入库前自动抓取补全'),
  'source_id': prop('number', '书源 id（来自 search_sonovel）'),
  'source_name': prop('string', '书源名（来自 search_sonovel）'),
  'format': prop('string', '生成格式 epub 或 txt，默认 epub'),
};
export const BOOKLIST_CREATE_REQUIRED: string[] = ['name'];
export const BOOKLIST_ADD_REQUIRED: string[] = ['booklist_id', 'book_ids'];
export const SONOVEL_TASK_REQUIRED: string[] = ['book_name', 'url'];

export const TOOL_SEARCH_SONOVEL: AiToolDefinition = defineTool('search_sonovel',
  '在 so-novel 书源站聚合搜索网络小说，返回最多 8 条 {书名, 作者, 书源, 类别, 状态, 字数, url, 最新章节}。' +
    '用户想下载书架上没有的网络小说时使用；url 是后续 add_sonovel_task 的必需参数，' +
    '也是 get_novel_meta 取简介/封面的入参。',
  QUERY_PROPS, ['query']);
export const TOOL_ADD_SONOVEL_TASK: AiToolDefinition = defineTool('add_sonovel_task',
  '把一本 so-novel 网络小说加入服务器下载任务队列（参数来自 search_sonovel 的返回）。' +
    '下载与转换都在服务器（云端）执行，不是用手机的流量/存储下载；' +
    '服务器完成后应用在线时会自动把成品拉取到本地书架，完成前成品只在服务器。',
  SONOVEL_TASK_PROPS, SONOVEL_TASK_REQUIRED);
export const TOOL_LIST_DOWNLOAD_TASKS: AiToolDefinition = defineTool('list_download_tasks',
  '查看当前下载任务队列：每条任务的状态（等待/下载中/完成/失败）、进度与错误原因。无需参数。',
  EMPTY_PROPS, NO_REQUIRED);
export const ADD_TO_SHELF_PROPS: Record<string, AiToolProperty> = {
  'book_id': BOOK_ID_PROP,
  'format': prop('string', '下载格式（如 epub/azw3/mobi/pdf，取自 book_detail 返回的可下载格式）；留空默认 epub'),
};
export const TOOL_ADD_TO_SHELF: AiToolDefinition = defineTool('add_to_shelf',
  '把在线书库里的一本书（书籍 id 来自 search_books）下载到本机书架：先查可下载格式，' +
    '再加入本机下载队列并立即开始，完成后出现在书架。用户说「把某本书加到书架/存到本机」时使用。' +
    '与 add_sonovel_task 不同：这本是服务器上已有的成品书。',
  ADD_TO_SHELF_PROPS, ['book_id']);

export const BOOKLIST_ID_PROP: AiToolProperty = prop('number', '书单 id（来自 list_booklists 返回）');
export const BOOKLIST_REMOVE_BOOK_PROPS: Record<string, AiToolProperty> = {
  'booklist_id': BOOKLIST_ID_PROP,
  'book_id': BOOK_ID_PROP,
};
export const BOOKLIST_UPDATE_PROPS: Record<string, AiToolProperty> = {
  'booklist_id': BOOKLIST_ID_PROP,
  'name': prop('string', '新书单名；留空不改'),
  'description': prop('string', '新书单简介；留空不改'),
  'is_public': prop('string', '公开传 true、私有传 false；留空不改'),
};
export const BOOKLIST_DELETE_PROPS: Record<string, AiToolProperty> = { 'booklist_id': BOOKLIST_ID_PROP };
export const PUSH_DEVICE_PROPS: Record<string, AiToolProperty> = {
  'book_id': BOOK_ID_PROP,
  'device_type': prop('string', '设备类型：kindle/duokan/ireader/hanwang/boox/dangdang/purelibro/koreader'),
  'target': prop('string', 'kindle 填 Kindle 邮箱；其他填设备地址（如 http://192.168.1.5:2222）；留空自动按类型匹配服务器已登记设备'),
};
export const TOOL_LIST_BOOKLISTS: AiToolDefinition = defineTool('list_booklists',
  '列出当前用户创建的所有书单：{id, 书名数, 公开/私有, 名称}。需要对书单增删改查但不知道书单 id 时先查它，' +
    '不要凭空猜 id，也不要为加一本书而重复新建书单。',
  EMPTY_PROPS, NO_REQUIRED);
export const TOOL_UPDATE_BOOKLIST: AiToolDefinition = defineTool('update_booklist',
  '重命名书单、改简介或切换公开/私有。只改传入的字段，其余保持原值。书单 id 来自 list_booklists。',
  BOOKLIST_UPDATE_PROPS, ['booklist_id']);
export const TOOL_DELETE_BOOKLIST: AiToolDefinition = defineTool('delete_booklist',
  '删除用户自己创建的书单（只删书单，书本身不受影响）。执行前向用户复述书单名称与书本数确认。id 来自 list_booklists。',
  BOOKLIST_DELETE_PROPS, ['booklist_id']);
export const TOOL_REMOVE_BOOK_FROM_BOOKLIST: AiToolDefinition = defineTool('remove_book_from_booklist',
  '把一本书从指定书单移出（书库里的书不受影响）。两个 id 分别来自 list_booklists 与 search_books。',
  BOOKLIST_REMOVE_BOOK_PROPS, ['booklist_id', 'book_id']);
export const TOOL_PUSH_TO_DEVICE: AiToolDefinition = defineTool('push_to_device',
  '把服务器书库里的一本书推送到用户的电子阅读器或阅读 App（kindle/duokan/ireader/hanwang/boox/' +
    'dangdang/purelibro/koreader）。kindle 的 target 是 Kindle 邮箱；其他设备 target 是设备地址，' +
    '留空则自动匹配服务器「发送到设备」里已登记的同类型设备。FTP 推送不支持，请引导用户到书籍详情页操作。',
  PUSH_DEVICE_PROPS, ['book_id', 'device_type']);
export const SHELF_LIST_PROPS: Record<string, AiToolProperty> = {
  'kind': prop('string', "'reading'=在读（默认）、'favorites'=收藏"),
  'limit': prop('number', '最多返回几本（默认 20，上限 50）'),
  'keyword': prop('string', '可选：按书名/作者关键词过滤（服务端结果内过滤）'),
};
export const TOOL_SHELF_LIST: AiToolDefinition = defineTool('shelf_list',
  '按状态列出书架里的书：在读 / 收藏，可按关键词过滤。' +
    '回答「我在读哪些书」「我的收藏有哪些」时用它；找某本具体的书用 search_books。',
  SHELF_LIST_PROPS, []);

export const BOOK_PROGRESS_PROPS: Record<string, AiToolProperty> = {
  'book_id': prop('number', '书籍 id（可先用 search_books 查到）'),
};
export const TOOL_BOOK_PROGRESS: AiToolDefinition = defineTool('book_progress',
  '查看某本书的阅读进度：本机记录里的当前章节与百分比（没有本机记录时说明未在本机读过）。' +
    '回答「这本书我读到哪了」时用它；需要全书目录结构用 book_notes 或 book_detail。',
  BOOK_PROGRESS_PROPS, ['book_id']);

export const TOOL_LIST_AI_TOOLS: AiToolDefinition = defineTool('list_ai_tools',
  '列出你当前可用的全部工具（按用途分组，含一句话说明与是否写操作）。' +
    '不确定该用哪个工具、或用户问「你能做什么/有哪些工具」时先调它，避免盲猜工具名。',
  EMPTY_PROPS, NO_REQUIRED);

export const TOOL_READING_STATS: AiToolDefinition = defineTool('reading_stats',
  '返回用户的阅读统计：累计在读/累计读完/本月在读/本月读完的书数，并列出当前在读的书。' +
    '回答「我最近读了多少书/这个月读完几本」类问题时使用。无需参数。',
  EMPTY_PROPS, NO_REQUIRED);
export const TOOL_CREATE_BOOKLIST: AiToolDefinition = defineTool('create_booklist',
  '在 MyBooks 服务器上创建一个新书单。返回新书单 id，可用于 add_books_to_booklist。',
  BOOKLIST_CREATE_PROPS, BOOKLIST_CREATE_REQUIRED);
export const TOOL_ADD_BOOKS_TO_BOOKLIST: AiToolDefinition = defineTool('add_books_to_booklist',
  '把若干本书（书籍 id 来自 search_books）加入指定书单。',
  BOOKLIST_ADD_PROPS, BOOKLIST_ADD_REQUIRED);

export const BOOK_META_PROPS: Record<string, AiToolProperty> = {
  'book_id': BOOK_ID_PROP,
  'title': prop('string', '新书名；留空不改'),
  'authors': prop('string', '作者，多个用逗号分隔；留空不改'),
  'tags': prop('string', '标签，逗号分隔；留空不改'),
  'category': prop('string', '分类（单值）；留空不改。优先从 list_categories 返回的现有分类中选；' +
    '写新名字服务器会自动创建该分类，但需管理员加入分类设置才在网站导航显示'),
  'publisher': prop('string', '出版社；留空不改'),
  'isbn': prop('string', 'ISBN；留空不改'),
  'series': prop('string', '丛书名；留空不改'),
  'comment': prop('string', '书籍简介全文；留空不改'),
  'rating': prop('number', '评分 0-10；0 表示不改'),
};
export const BOOK_META_REQUIRED: string[] = ['book_id'];

export const TOOL_UPDATE_BOOK_META: AiToolDefinition = defineTool('update_book_meta',
  '更新服务器上某本书的元数据（书籍 id 来自 search_books）。只传要修改的字段，未传字段保持原值。' +
    '改前先 book_detail 核对现值并向用户复述目标改动。更换封面图片用 search_cover + set_cover。' +
    '分类(category)与标签(tags)是两套体系：分类单选、标签可多个，动分类前先用 list_categories 看现有分类。',
  BOOK_META_PROPS, BOOK_META_REQUIRED);

export const TOOL_LIST_CATEGORIES: AiToolDefinition = defineTool('list_categories',
  '列出在线书库（Talebook）的分类体系：每个分类及其子标签。' +
    '给书籍设置/归类、向用户推荐分类之前先查它，避免凭空发明分类名。',
  {}, []);

export const COVER_SEARCH_PROPS: Record<string, AiToolProperty> = {
  'book_id': BOOK_ID_PROP,
  'title': prop('string', '检索书名；留空用该书现书名'),
  'isbn': prop('string', 'ISBN；有则优先，命中更准'),
  'publisher': prop('string', '出版社，可留空'),
};
export const COVER_SET_PROPS: Record<string, AiToolProperty> = {
  'book_id': BOOK_ID_PROP,
  'index': prop('number', '选第几条候选（1 起，来自 search_cover 返回）'),
};
export const COVER_SEARCH_REQUIRED: string[] = ['book_id'];
export const COVER_SET_REQUIRED: string[] = ['book_id', 'index'];

export const TOOL_SEARCH_COVER: AiToolDefinition = defineTool('search_cover',
  '在互联网元数据源中按 ISBN/书名检索某本书的候选条目，返回每条的书名/作者/出版社/来源/封面图 url。' +
    '更换封面（set_cover）前必须先对同一本书调用本工具。',
  COVER_SEARCH_PROPS, COVER_SEARCH_REQUIRED);
export const TOOL_SET_COVER: AiToolDefinition = defineTool('set_cover',
  '把某本书的封面图片换成 search_cover 返回的第 index 条候选（只改封面，其余元数据不动）。' +
    '候选须来自对同一 book_id 的最近一次 search_cover。',
  COVER_SET_PROPS, COVER_SET_REQUIRED);

export const MEMORY_SAVE_PROPS: Record<string, AiToolProperty> = {
  'content': prop('string', '要记住的一句话事实，如「用户偏好刘慈欣的长篇」「用户正在读《三体》，计划两周读完」'),
};
export const MEMORY_FORGET_PROPS: Record<string, AiToolProperty> = {
  'index': prop('number', '要删除的记忆序号（1 起，来自系统提示中的记忆列表编号）'),
};
export const TOOL_SAVE_MEMORY: AiToolDefinition = defineTool('save_memory',
  '把关于用户的一条长期事实记进跨对话记忆：阅读偏好、正在读的书、明确说过的约定、身份/称呼等。' +
    '只记值得跨对话保留的信息，一次性提问和闲聊不要记；已有相同记忆时不要重复记。',
  MEMORY_SAVE_PROPS, ['content']);
export const TOOL_FORGET_MEMORY: AiToolDefinition = defineTool('forget_memory',
  '按序号删除一条用户记忆（用户说「别记得/忘掉第 N 条」时用）。序号来自系统提示记忆列表的编号。',
  MEMORY_FORGET_PROPS, ['index']);

export const MCP_ADD_PROPS: Record<string, AiToolProperty> = {
  'label': prop('string', 'MCP 服务名称（用户可见），如「我的搜索服务」'),
  'url': prop('string', 'MCP 端点 URL（Streamable HTTP，通常以 /mcp 结尾）'),
  'api_key': prop('string', '该服务的 API Key（需要鉴权时给；不需要则留空）'),
};
export const TOOL_MCP_ADD_SERVER: AiToolDefinition = defineTool('add_mcp_server',
  '为用户新增一个 MCP 服务（模型上下文协议服务），添加后其工具在下一轮对话自动可用。' +
    '用户说「帮我加个 MCP 服务」「配置这个 MCP 地址」时用；名称与 URL 必填，需要鉴权就把 Key 一起给。' +
    'URL/Key 不确定时先用 ask_user 问清楚，不要猜。',
  MCP_ADD_PROPS, ['label', 'url']);

export const META_SEARCH_PROPS: Record<string, AiToolProperty> = {
  'query': prop('string', '书名或「书名 作者」关键词；也用于网文源检索'),
  'isbn': prop('string', 'ISBN（10/13 位），比书名更准'),
  'subject_id': prop('string', '豆瓣条目 id（来自本工具 suggest 结果），返回评分/出版社/ISBN/页数/简介'),
  'book_id': prop('number', '本地书籍 id；给出时同时拉服务端多源候选（豆瓣/百度/亚马逊/新华，可用于 set_cover）'),
};
export const TOOL_SEARCH_META: AiToolDefinition = defineTool('search_meta',
  '多站元数据搜索：豆瓣直连检索（书名/ISBN→subject_id+封面）、豆瓣条目详情（评分/出版社/ISBN/出版年/页数/简介）、' +
    '服务端 refer 多源候选（传 book_id）、网文源含类别/状态/字数（传 query）。' +
    '豆瓣查不到的网文：用网文通道的 url 再调 get_novel_meta 补简介/封面。' +
    '补元数据（update_book_meta）或核对书目信息前先用它查真实数据。',
  META_SEARCH_PROPS, []);

export const NOVEL_META_PROPS: Record<string, AiToolProperty> = {
  'url': prop('string', '书源站详情页 url（来自 search_sonovel / search_meta 的网文通道）'),
};
export const TOOL_GET_NOVEL_META: AiToolDefinition = defineTool('get_novel_meta',
  '抓书源站详情页补全网络小说元数据：简介、封面、类别、连载状态（url 来自 search_sonovel 结果）。' +
    '豆瓣查不到的网文就靠它；对 17K小说网详情页解析最全。失败时换另一条书源候选的 url 重试。',
  NOVEL_META_PROPS, ['url']);

export const ENCYCLOPEDIA_PROPS: Record<string, AiToolProperty> = {
  'query': prop('string', '百科词条名（如「刘慈欣」「三体」），只给名词本身，不要带「是谁/什么是」等整句问话'),
};
export const TOOL_SEARCH_ENCYCLOPEDIA: AiToolDefinition = defineTool('search_encyclopedia',
  '搜百科词条（百度百科+维基百科双通道）：回答「这位作者是谁/这本书什么背景/某地某概念」类问题，' +
    '返回词条标题、摘要与链接。query 传词条名而非整句问话。一个通道不可达会如实标注并仍给另一通道结果。',
  ENCYCLOPEDIA_PROPS, ['query']);

export const WEB_SEARCH_PROPS: Record<string, AiToolProperty> = {
  'query': prop('string', '搜索关键词（书名、人名、事件、规格参数等任意信息），尽量精炼，不要整句问话'),
};
export const TOOL_SEARCH_WEB: AiToolDefinition = defineTool('search_web',
  '通用网页搜索（百度/Bing/360 三引擎并行聚合）：查书籍之外的任意信息——作者近况、作品改编、价格评测、' +
    '新闻事件、名词解释等。返回若干条结果的来源、标题、链接与摘要（已跨引擎去重）。' +
    '百科类词条优先用 search_encyclopedia；摘要不够时可把候选链接讲给用户自行查看。',
  WEB_SEARCH_PROPS, ['query']);

export const FETCH_URL_PROPS: Record<string, AiToolProperty> = {
  'url': prop('string', '要访问的完整网页地址（http:// 或 https:// 开头），可取自 search_web 结果的链接'),
};
export const TOOL_FETCH_URL: AiToolDefinition = defineTool('fetch_url',
  '访问一个具体网页并读取正文：给定 URL 直连抓取，返回页面标题与正文纯文本（过长会截断）。' +
    '当 search_web 的摘要不够、需要看某条结果的完整内容时用它；一次抓一个链接，需要多篇就分多次调用。' +
    '不能登录、不执行 JS，纯脚本渲染的页面可能取不到正文。',
  FETCH_URL_PROPS, ['url']);

export const AI_SEARCH_PROPS: Record<string, AiToolProperty> = {
  'query': prop('string', '要联网查证的问题（自然语言整句即可，AI 搜索引擎会直接针对问题作答）'),
};
export const TOOL_AI_SEARCH: AiToolDefinition = defineTool('ai_search',
  'AI 联网搜索引擎问答（通义系 enable_search 强制联网）：直接返回针对问题的整合答案＋引用网页，' +
    '适合时效性/综合性问题（「XX 最近怎么样」「XX 和 YY 哪个更适合…」）。' +
    '需要逐条链接清单用 search_web，百科词条用 search_encyclopedia；' +
    '当前服务商不是通义系（阿里云域名）时本工具会明确告知不可用。',
  AI_SEARCH_PROPS, ['query']);

export const ASK_USER_PROPS: Record<string, AiToolProperty> = {
  'question': prop('string', '要向用户确认的问题，一句话'),
  'options': prop('string', '候选项，用顿号「、」分隔，2-6 个，每项尽量短'),
};
export const TOOL_ASK_USER: AiToolDefinition = defineTool('ask_user',
  '信息不足以安全执行、或存在多个合理候选需要用户拍板时，向用户提出一个带选项的问题并等待其选择；' +
    '用户的答复会作为本工具的结果返回，收到后再继续。不要用它闲聊或问与当前任务无关的信息。',
  ASK_USER_PROPS, ['question', 'options']);

export const SET_VOICE_PROPS: Record<string, AiToolProperty> = {
  'voice': prop('string', '目标音色 id：longanqian（女·默认）、longanlingxin（女·知心温暖）、' +
    'longanlingxi（女·可爱甜美）、longanxiaoxin（女·亲切活泼）、longanlufeng（男·明亮开朗）'),
};
export const TOOL_SET_VOICE: AiToolDefinition = defineTool('set_voice',
  '更换你在实时语音通话中的音色（声线）。适合场景明显需要另一种声音时调用：' +
    '给孩子讲故事、用户点名要男声/甜美声/温柔声、角色扮演等。' +
    '调用后当前会话会短暂重连（约一秒），新音色从下一句生效；语气变化不需要本工具，直接调整表达方式即可。',
  SET_VOICE_PROPS, ['voice']);

// 顺序有坑：OpenCode 网关实测会丢 tools 数组最后一项（2026-11-20 板上取证：模型枚举
// 恰缺末位 get_novel_meta，报「最后一个工具是 search_meta」）。末位放最低频工具，
// 新增工具一律插在中间，别放最后。
export const TOOL_DEFS: AiToolDefinition[] = [
  TOOL_SEARCH_BOOKS, TOOL_BOOK_DETAIL, TOOL_BOOK_NOTES, TOOL_READING_HISTORY,
  TOOL_SEARCH_SONOVEL, TOOL_ADD_SONOVEL_TASK, TOOL_LIST_DOWNLOAD_TASKS, TOOL_ADD_TO_SHELF,
  TOOL_PUSH_TO_DEVICE, TOOL_READING_STATS, TOOL_SHELF_LIST, TOOL_BOOK_PROGRESS, TOOL_LIST_AI_TOOLS,
  TOOL_CREATE_BOOKLIST, TOOL_ADD_BOOKS_TO_BOOKLIST, TOOL_LIST_BOOKLISTS, TOOL_UPDATE_BOOKLIST,
  TOOL_DELETE_BOOKLIST, TOOL_REMOVE_BOOK_FROM_BOOKLIST,
  TOOL_UPDATE_BOOK_META, TOOL_LIST_CATEGORIES,
  TOOL_SEARCH_COVER, TOOL_SET_COVER,
  TOOL_SAVE_MEMORY, TOOL_SEARCH_META, TOOL_GET_NOVEL_META, TOOL_SEARCH_ENCYCLOPEDIA,
  TOOL_SEARCH_WEB, TOOL_FETCH_URL, TOOL_AI_SEARCH, TOOL_MCP_ADD_SERVER, TOOL_ASK_USER, TOOL_FORGET_MEMORY,
];

