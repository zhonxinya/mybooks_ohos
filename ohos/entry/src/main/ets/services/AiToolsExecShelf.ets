/**
 * 书架/书单/下载/推送类工具执行器（拆分自 AiTools.ets）：搜索书库、详情、标注、
 * 阅读历史、so-novel 检索与任务、加书架、书单全生命周期、推送设备、阅读统计。
 */
import { ApiMessageResult, TalebookApi } from './TalebookApi';
import { TalebookApiBooks } from './TalebookApiBooks';
import { AnnotationApi, annotationTypeLabel, ANNOTATION_SCOPE_MINE } from './AnnotationApi';
import { SoNovelBookPayload, DownloadRecord, DownloadTask, TalebookService } from './TalebookService';
import { SoNovelService } from './SoNovelService';
import { SoNovelMerge, SoNovelSearchItem } from '../utils/SoNovelMerge';
import { DownloadTaskService } from './DownloadTaskService';
import { BookListAddResponse, BookListApi, BookListDetailResponse, BookListMutationResponse, BookListUpdatePayload, BookListsResponse } from './BookListApi';
import { BookListSummary, parseBookListSummary, parseBookListSummaries } from '../models/BookListModels';
import { ReadingDevice, deviceTypeLabel } from '../models/DeviceModels';
import { HomeBook, ReadingStatsSummary } from '../models/HomeModels';
import { BookDetail, BookItem } from './BookModels';
import { ServerFeature, ServerRegistry } from './ServerProfile';
import { AccountManager } from './AccountManager';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AiToolsCore } from './AiToolsCore';
import { SEARCH_LIMIT, NOTE_LIMIT, HISTORY_LIMIT, INTRO_MAX, SONOVEL_LIMIT, TASK_LIST_LIMIT, SHELF_SYNC_LIMIT, BOOKLIST_DEFAULT_COLOR, ToolBookLine } from './AiToolsDefs';

export class AiToolsExecShelf {
  static async searchBooks(query: string, callId: string = ''): Promise<string> {
    if (query.length === 0) {
      return '参数 query 为空，请提供书名或关键词。';
    }
    const books = await TalebookApi.search(query, 1, SEARCH_LIMIT);
    if (books.length === 0) {
      return `书架中没有找到与「${query}」相关的书。`;
    }
    const lines: string[] = [];
    const structured: ToolBookLine[] = [];
    for (const b of books) {
      lines.push(`- 《${b.title}》（${b.authors.join('、')}） id=${b.id}`);
      structured.push({
        title: `《${b.title}》`,
        subtitle: b.authors.join('、'),
        cover: b.coverUrl,
      });
    }
    AiToolsCore.lastBooks = structured;
    if (callId.length > 0) {
      // 并行路径：同同步段登记进配对槽，UI 按 callId 取回（静态槽会被后完成者覆盖）
      AiToolsCore.booksByCall.set(callId, structured);
    }
    return `找到 ${books.length} 本：\n${lines.join('\n')}`;
  }

  static async bookDetail(bookId: number): Promise<string> {
    if (bookId <= 0) {
      return '参数 book_id 需要是正整数（可先用 search_books 查到 id）。';
    }
    const detail = await TalebookApi.getBookDetail(bookId);
    if (detail === null) {
      return `没有找到 id=${bookId} 的书籍。`;
    }
    const lines: string[] = [
      `《${detail.title}》（${detail.authors.join('、')}），评分 ${detail.rating}`,
    ];
    if (detail.tags.length > 0) {
      lines.push(`标签：${detail.tags.join('、')}`);
    }
    const meta: string[] = [];
    if (detail.publisher.length > 0) {
      meta.push(`出版社：${detail.publisher}`);
    }
    if (detail.isbn.length > 0) {
      meta.push(`ISBN：${detail.isbn}`);
    }
    if (detail.series.length > 0) {
      meta.push(`丛书：${detail.series}`);
    }
    if (meta.length > 0) {
      lines.push(meta.join('　'));
    }
    const formats: string[] = [];
    for (const f of detail.files) {
      formats.push(f.format);
    }
    if (formats.length > 0) {
      lines.push(`可下载格式：${formats.join('、')}`);
    }
    if (detail.comments.length > 0) {
      lines.push(`简介：${AiToolsCore.clip(detail.comments, INTRO_MAX)}`);
    }
    return lines.join('\n');
  }

  static async bookNotes(bookId: number): Promise<string> {
    if (bookId <= 0) {
      return '参数 book_id 需要是正整数（可先用 search_books 查到 id）。';
    }
    const items = await AnnotationApi.listBookAnnotations(bookId, ANNOTATION_SCOPE_MINE);
    if (items.length === 0) {
      return '这本书还没有你的标注记录。';
    }
    const cap: number = Math.min(items.length, NOTE_LIMIT);
    const lines: string[] = [];
    for (let i = 0; i < cap; i++) {
      const it = items[i];
      let line: string = `[${annotationTypeLabel(it.annotationType)}]`;
      if (it.chapter.length > 0) {
        line += ` 章节：${AiToolsCore.clip(it.chapter, 40)}`;
      }
      if (it.quoteText.length > 0) {
        line += ` 原文「${AiToolsCore.clip(it.quoteText, 60)}」`;
      }
      if (it.content.length > 0) {
        line += ` 备注：${AiToolsCore.clip(it.content, 100)}`;
      }
      lines.push(line);
    }
    const more: string = items.length > cap ? `\n（共 ${items.length} 条，仅显示前 ${cap} 条）` : '';
    return `${lines.join('\n')}${more}`;
  }

  static readingHistory(): string {
    const items = TalebookService.getReadingHistory().slice();
    items.sort((a, b): number => b.lastReadTime - a.lastReadTime);
    const cap: number = Math.min(items.length, HISTORY_LIMIT);
    if (cap === 0) {
      return '还没有阅读记录。';
    }
    const lines: string[] = [];
    for (let i = 0; i < cap; i++) {
      const it = items[i];
      let line: string = `《${it.title}》`;
      if (it.author !== undefined && it.author.length > 0) {
        line += `（${it.author}）`;
      }
      if (it.chapterName !== undefined && it.chapterName.length > 0) {
        line += ` 读到：${AiToolsCore.clip(it.chapterName, 30)}`;
      }
      if (it.progressPercent !== undefined) {
        line += `，进度 ${Math.round(it.progressPercent)}%`;
      }
      line += `，最近阅读 ${AiToolsCore.formatDate(it.lastReadTime)}`;
      lines.push(line);
    }
    return `最近阅读 ${cap} 本：\n${lines.join('\n')}`;
  }

  /** 按状态列书架（在读/收藏），可按关键词过滤。 */
  static async shelfList(kind: string, limit: number, keyword: string): Promise<string> {
    const mode: string = kind.length > 0 ? kind : 'reading';
    const cap: number = Math.min(50, Math.max(1, limit > 0 ? limit : 20));
    let books: BookItem[];
    let label: string;
    if (mode === 'favorites') {
      books = await TalebookApi.getFavorites(cap);
      label = '收藏';
    } else {
      books = await TalebookApi.getReadingBooks(cap);
      label = '在读';
    }
    const kw: string = keyword.trim().toLowerCase();
    if (kw.length > 0) {
      books = books.filter((b: BookItem): boolean =>
        b.title.toLowerCase().indexOf(kw) >= 0 ||
        b.authors.join('、').toLowerCase().indexOf(kw) >= 0);
    }
    if (books.length === 0) {
      const suffix: string = kw.length > 0 ? `（关键词「${keyword}」）` : '';
      return `书架${label}里没有${suffix}书。`;
    }
    const lines: string[] = [];
    for (let i = 0; i < books.length; i++) {
      const b: BookItem = books[i];
      lines.push(`- 《${b.title}》（${b.authors.length > 0 ? b.authors.join('、') : '佚名'}） id=${b.id}`);
    }
    const more: string = books.length >= cap ? `\n（已按上限 ${cap} 本截断，可调 limit）` : '';
    return `书架${label}共 ${books.length} 本：\n${lines.join('\n')}${more}`;
  }

  /** 某本书的本机阅读进度（本机记录为准）。 */
  static bookProgress(bookId: number): string {
    if (bookId <= 0) {
      return '参数 book_id 需要是正整数（可先用 search_books 查到 id）。';
    }
    const items = TalebookService.getReadingHistory();
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      if (String(it.bookId) !== `${bookId}`) {
        continue;
      }
      const parts: string[] = [];
      if (it.chapterName !== undefined && it.chapterName.length > 0) {
        parts.push(`读到「${it.chapterName}」`);
      }
      if (it.progressPercent !== undefined) {
        parts.push(`进度 ${Math.round(it.progressPercent)}%`);
      }
      if (it.currentPage !== undefined && it.totalPages !== undefined && it.totalPages > 0) {
        parts.push(`第 ${it.currentPage}/${it.totalPages} 页`);
      }
      if (it.lastReadTime !== undefined) {
        parts.push(`最近阅读 ${AiToolsCore.formatDate(it.lastReadTime)}`);
      }
      return parts.length > 0
        ? `id=${bookId} 的阅读进度：${parts.join('，')}`
        : `id=${bookId} 有阅读记录但没有进度信息。`;
    }
    return `本机没有 id=${bookId} 的阅读记录（可能还没在本机打开过，或已清除记录）。`;
  }

  static async searchSoNovel(query: string): Promise<string> {
    if (query.length === 0) {
      return '参数 query 为空，请提供小说名关键词。';
    }
    const envelope = await SoNovelService.search(query);
    if (envelope.error.length > 0) {
      return `so-novel 搜索失败：${envelope.error}`;
    }
    const body: Record<string, Object> | null = envelope.body as Record<string, Object> | null;
    const data: Object | undefined = body !== null ? body['data'] : undefined;
    if (data === undefined || !Array.isArray(data) || data.length === 0) {
      return `各书源没有找到与「${query}」相关的小说。`;
    }
    const cap: number = Math.min(data.length, SONOVEL_LIMIT);
    const lines: string[] = [];
    for (let i = 0; i < cap; i++) {
      const item: SoNovelSearchItem = SoNovelMerge.fromRecord(data[i] as Record<string, Object>);
      let line: string = `- 《${item.bookName}》（${item.author.length > 0 ? item.author : '佚名'}）` +
        ` 书源：${item.sourceName}(id=${item.sourceId})`;
      if (item.category.length > 0) {
        line += `，类别：${item.category}`;
      }
      if (item.status.length > 0) {
        line += `，${item.status}`;
      }
      if (item.wordCount.length > 0) {
        line += `，字数：${item.wordCount}`;
      }
      if (item.latestChapter.length > 0) {
        line += `，最新章节：${AiToolsCore.clip(item.latestChapter, 30)}`;
      }
      line += `，url：${item.url}`;
      lines.push(line);
    }
    return `书源站找到 ${cap} 条，要下载需调 add_sonovel_task（带上 url 与书源信息）；` +
      `要简介/封面拿该 url 调 get_novel_meta：\n${lines.join('\n')}`;
  }

  static addSonovelTask(args: Record<string, Object>): string {
    const bookName: string = AiToolsCore.argString(args, 'book_name');
    const url: string = AiToolsCore.argString(args, 'url');
    if (bookName.length === 0 || url.length === 0) {
      return '参数 book_name 与 url 必填（都来自 search_sonovel 的结果）。';
    }
    const formatRaw: string = AiToolsCore.argString(args, 'format').toLowerCase();
    const format: string = formatRaw === 'txt' ? 'txt' : 'epub';
    const payload: SoNovelBookPayload = {
      sourceId: AiToolsCore.argNumber(args, 'source_id'),
      sourceName: AiToolsCore.argString(args, 'source_name'),
      url: url,
      bookName: bookName,
      author: AiToolsCore.argString(args, 'author'),
      cover: AiToolsCore.argString(args, 'cover'),
      format: format,
      language: 'zh-CN',
    };
    const dup: DownloadTask | undefined = DownloadTaskService.getTasks().find((t: DownloadTask) =>
      t.kind === 'sonovel' && t.payload !== undefined && t.payload.url === url &&
        (t.status === 'pending' || t.status === 'downloading'));
    if (dup !== undefined) {
      return `《${bookName}》已在下载队列中（状态：${DownloadTaskService.statusLabel(dup.status)}），无需重复添加。`;
    }
    DownloadTaskService.enqueue(payload);
    DownloadTaskService.processQueue();
    return `已加入云端下载任务：《${bookName}》（书源：${payload.sourceName.length > 0 ? payload.sourceName : '未知'}，` +
      `格式 ${format}）。下载与转换在服务器进行，完成后应用会自动拉取到本地书架；进度可随时让我用 list_download_tasks 查。`;
  }

  static listDownloadTasks(): string {
    const tasks: DownloadTask[] = DownloadTaskService.getTasks();
    if (tasks.length === 0) {
      return '还没有下载任务。';
    }
    const cap: number = Math.min(tasks.length, TASK_LIST_LIMIT);
    const lines: string[] = [];
    for (let i = 0; i < cap; i++) {
      const t: DownloadTask = tasks[i];
      let line: string = `- [${DownloadTaskService.statusLabel(t.status)}] 《${t.title}》` +
        `（${t.author.length > 0 ? t.author : '佚名'}）`;
      if (t.status === 'downloading') {
        line += ` 进度 ${t.progress}% ${AiToolsCore.clip(t.message, 30)}`;
      }
      if (t.status === 'failed' && t.error.length > 0) {
        line += ` 错误：${AiToolsCore.clip(t.error, 40)}`;
      }
      if (t.status === 'completed' && t.filePath.length > 0) {
        line += '，已存入本地书架';
      }
      lines.push(line);
    }
    const more: string = tasks.length > cap ? `\n（共 ${tasks.length} 条，仅列最近 ${cap} 条）` : '';
    return `下载任务：\n${lines.join('\n')}${more}`;
  }

  /**
   * 书库书加入本机书架：与书籍详情页下载按钮同链路
   * （登录 → 队列去重 → 选格式 → 配额检查 → 建目录 → 入队 → 立即调度）。
   */
  static async addToShelf(args: Record<string, Object>): Promise<string> {
    const bookId: number = AiToolsCore.argNumber(args, 'book_id');
    if (bookId <= 0) {
      return '参数 book_id 无效，请先用 search_books 拿到书籍 id。';
    }
    const authenticated: boolean = await TalebookService.ensureAuthenticated();
    if (!authenticated) {
      return '尚未登录 MyBooks 服务器，无法加入书架。请先登录后再让我重试。';
    }
    const pending: DownloadTask | undefined = DownloadTaskService.getTasks().find((t: DownloadTask) =>
      t.kind === 'talebook' && t.talebookPayload !== undefined && t.talebookPayload.bookId === bookId &&
        (t.status === 'pending' || t.status === 'downloading'));
    if (pending !== undefined) {
      return `《${pending.title}》已在下载队列中（状态：${DownloadTaskService.statusLabel(pending.status)}），无需重复入队。`;
    }
    const done: DownloadTask | undefined = DownloadTaskService.getTasks().find((t: DownloadTask) =>
      t.kind === 'talebook' && t.talebookPayload !== undefined && t.talebookPayload.bookId === bookId &&
        t.status === 'completed');
    if (done !== undefined) {
      return `《${done.title}》之前已下载到本机书架，无需重复添加。`;
    }
    const detail: BookDetail | null = await TalebookApi.getBookDetail(bookId);
    if (detail === null) {
      return `书库里找不到 id=${bookId} 的书，请确认 id 来自 search_books 的结果。`;
    }
    const formats: string[] = [];
    for (let i = 0; i < detail.files.length; i++) {
      formats.push(detail.files[i].format.toLowerCase());
    }
    if (formats.length === 0) {
      return `《${detail.title}》在服务器上没有任何可下载文件。`;
    }
    const want: string = AiToolsCore.argString(args, 'format').toLowerCase();
    let format: string = '';
    if (want.length === 0) {
      format = formats.indexOf('epub') >= 0 ? 'epub' : formats[0];
    } else if (formats.indexOf(want) >= 0) {
      format = want;
    } else {
      return `《${detail.title}》没有 ${want} 格式，可下载格式：${formats.join('、')}。`;
    }
    if (ServerRegistry.supports(ServerFeature.DOWNLOAD_QUOTA)) {
      // 与页面同语义：配额查询本身失败不拦入队（fail-open），只拦明确的「配额用完」
      try {
        const quota = await TalebookApi.getDownloadQuota();
        if (quota.allowed === false) {
          return `今日下载配额已用完（${quota.used ?? 0}/${quota.quota ?? 0}），明天再试吧`;
        }
      } catch (_error) {
      }
    }
    const booksDir = AccountManager.booksDir(TalebookService.dataDir());
    try {
      if (!fs.accessSync(booksDir)) {
        fs.mkdirSync(booksDir, true);
      }
    } catch (_error) {
      fs.mkdirSync(booksDir, true);
    }
    DownloadTaskService.enqueueTalebook({
      bookId: bookId,
      bookName: detail.title,
      author: detail.authors.length > 0 ? detail.authors.join(', ') : '',
      cover: TalebookService.resolveCoverUrl(detail.coverUrl),
      format: format,
      destPath: `${booksDir}/${bookId}.${format}`,
    });
    DownloadTaskService.processQueue();
    return `《${detail.title}》已加入下载队列（格式 ${format}），下载完成后会自动出现在书架；` +
      '进度可随时调 list_download_tasks 查看。';
  }

  /**
   * 刷新本地书架元数据快照（#1651 修「更新本地书架会下载」）：只重取服务端 detail
   * 并同步已有本地记录的字段，本地无记录=跳过，全程不入队任何下载。
   */
  static async syncLocalShelf(args: Record<string, Object>): Promise<string> {
    const bookId: number = AiToolsCore.argNumber(args, 'book_id');
    const records: DownloadRecord[] = TalebookService.getDownloads();
    if (bookId > 0) {
      const hit: DownloadRecord | undefined =
        records.find((r: DownloadRecord) => r.bookId === `${bookId}`);
      if (hit === undefined) {
        return `id=${bookId} 的书不在本地书架，已跳过（本工具不下载书；要下载请另调 add_to_shelf）。`;
      }
      const ok: boolean = await AiToolsExecShelf.syncOneLocal(bookId);
      return ok ? `已按服务器数据刷新本地书架的《${hit.title}》（仅字段，未下载文件）。` :
        `刷新失败：《${hit.title}》的服务端信息未能同步。`;
    }
    const targets: DownloadRecord[] =
      records.filter((r: DownloadRecord) => /^[0-9]+$/.test(r.bookId));
    const skippedLocal: number = records.length - targets.length;
    if (targets.length === 0) {
      return '本地书架没有可同步的书（空书架，或只有本机导入/网文成品，服务器无对应元数据）。';
    }
    const cap: number = Math.min(targets.length, SHELF_SYNC_LIMIT);
    let done: number = 0;
    let failed: number = 0;
    for (let i = 0; i < cap; i++) {
      const id: number = Number(targets[i].bookId);
      try {
        if (await AiToolsExecShelf.syncOneLocal(id)) {
          done++;
        } else {
          failed++;
        }
      } catch (_error) {
        failed++;
      }
    }
    let text: string = `已同步本地书架 ${done} 本的元数据（仅更新已有记录字段，未下载任何文件）`;
    if (failed > 0) {
      text += `；${failed} 本服务端信息获取失败，保持原值`;
    }
    if (targets.length > cap) {
      text += `；另有 ${targets.length - cap} 本未处理（单次上限 ${SHELF_SYNC_LIMIT}，可按 book_id 指定）`;
    }
    if (skippedLocal > 0) {
      text += `；${skippedLocal} 条本机导入/网文记录无服务器元数据，跳过`;
    }
    return text + '。';
  }

  /** 单本：重取服务端 detail → 同步本地记录字段；返回是否成功同步到本地记录。 */
  private static async syncOneLocal(bookId: number): Promise<boolean> {
    const envelope = await TalebookService.getBookDetailAsync(bookId);
    // 非 2xx 时 detail 字段全空，写下去等于假同步——判失败保持原值
    if (envelope.status < 200 || envelope.status >= 300) {
      return false;
    }
    const body: Record<string, Object> = envelope.body ?? {};
    const book: Record<string, Object> = (body['book'] as Record<string, Object> | undefined) ?? body;
    const title: string = String(book['title'] ?? '');
    const authors: string[] = Array.isArray(book['authors']) ? (book['authors'] as string[]) : [];
    const cover: string = String(book['cover'] ?? '');
    return TalebookService.syncDownloadMeta(`${bookId}`, title, authors.length > 0 ? authors[0] : '', cover);
  }

  /** 推送工具支持的设备类型（ftp 需凭据走页面，不开放给模型）。 */
  static readonly PUSH_TOOL_TYPES: string[] =
    ['kindle', 'duokan', 'ireader', 'hanwang', 'boox', 'dangdang', 'purelibro', 'koreader'];

  static async listBooklists(): Promise<string> {
    const rsp: BookListsResponse = await BookListApi.getMyBooklists();
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      return `书单查询失败：${rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err}`;
    }
    const lists: BookListSummary[] = parseBookListSummaries(rsp.booklists);
    if (lists.length === 0) {
      return '你还没有创建过书单。要新建可调 create_booklist。';
    }
    const cap: number = Math.min(lists.length, 20);
    const lines: string[] = [];
    for (let i = 0; i < cap; i++) {
      const b: BookListSummary = lists[i];
      lines.push(`- 书单「${b.name}」（id=${b.id}，${b.bookCount} 本，${b.isPublic ? '公开' : '私有'}）`);
    }
    const more: string = lists.length > cap ? `\n（共 ${lists.length} 个，仅列前 ${cap} 个）` : '';
    return `我的书单：\n${lines.join('\n')}${more}`;
  }

  /** 取用户自己拥有的书单摘要；不存在或非本人创建返回 null（增删改共用前置校验）。 */
  static async ownBooklist(id: number): Promise<BookListSummary | null> {
    const rsp: BookListDetailResponse = await BookListApi.getBooklistDetail(id, 1, 1, 'asc');
    if (rsp.err !== undefined && rsp.err !== 'ok' || rsp.booklist === undefined) {
      return null;
    }
    const summary: BookListSummary = parseBookListSummary(rsp.booklist as Record<string, Object>);
    return summary.isOwner ? summary : null;
  }

  static async updateBooklist(args: Record<string, Object>): Promise<string> {
    const id: number = AiToolsCore.argNumber(args, 'booklist_id');
    if (id <= 0) {
      return '参数 booklist_id 无效，请先用 list_booklists 查询。';
    }
    const name: string = AiToolsCore.argString(args, 'name');
    const description: string = AiToolsCore.argString(args, 'description');
    const pubRaw: string = AiToolsCore.argString(args, 'is_public').toLowerCase();
    if (name.length === 0 && description.length === 0 && pubRaw.length === 0) {
      return '请至少给出 name、description、is_public 之一。';
    }
    if (pubRaw.length > 0 && pubRaw !== 'true' && pubRaw !== 'false') {
      return 'is_public 只接受 true 或 false。';
    }
    const cur: BookListSummary | null = await AiToolsExecShelf.ownBooklist(id);
    if (cur === null) {
      return `找不到你创建的书单 id=${id}，先用 list_booklists 核对。`;
    }
    // update 接口为全量覆盖：未改字段必须回填原值（书籍 edit 接口同款教训）
    const payload: BookListUpdatePayload = {
      name: name.length > 0 ? name : cur.name,
      description: description.length > 0 ? description : cur.description,
      color: cur.color,
      is_public: pubRaw.length > 0 ? pubRaw === 'true' : cur.isPublic,
    };
    const rsp: BookListMutationResponse = await BookListApi.updateBooklist(id, payload);
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      return `书单更新失败：${rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err}`;
    }
    const changes: string[] = [];
    if (name.length > 0 && name !== cur.name) {
      changes.push(`名称「${cur.name}」→「${name}」`);
    }
    if (description.length > 0 && description !== cur.description) {
      changes.push('简介已更新');
    }
    if (pubRaw.length > 0 && (pubRaw === 'true') !== cur.isPublic) {
      changes.push(pubRaw === 'true' ? '已设为公开' : '已设为私有');
    }
    if (changes.length === 0) {
      return `书单「${cur.name}」各字段与现值相同，未做改动。`;
    }
    return `书单已更新：${changes.join('；')}。`;
  }

  static async deleteBooklist(args: Record<string, Object>): Promise<string> {
    const id: number = AiToolsCore.argNumber(args, 'booklist_id');
    if (id <= 0) {
      return '参数 booklist_id 无效，请先用 list_booklists 查询。';
    }
    const cur: BookListSummary | null = await AiToolsExecShelf.ownBooklist(id);
    if (cur === null) {
      return `找不到你创建的书单 id=${id}，先用 list_booklists 核对。`;
    }
    const rsp: ApiMessageResult = await BookListApi.deleteBooklist(id);
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      return `书单删除失败：${rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err}`;
    }
    return `书单「${cur.name}」（${cur.bookCount} 本）已删除，书库里的书不受影响。`;
  }

  static async removeBookFromBooklist(args: Record<string, Object>): Promise<string> {
    const id: number = AiToolsCore.argNumber(args, 'booklist_id');
    const bookId: number = AiToolsCore.argNumber(args, 'book_id');
    if (id <= 0 || bookId <= 0) {
      return 'booklist_id 与 book_id 都要给出（分别来自 list_booklists 与 search_books）。';
    }
    const cur: BookListSummary | null = await AiToolsExecShelf.ownBooklist(id);
    if (cur === null) {
      return `找不到你创建的书单 id=${id}，先用 list_booklists 核对。`;
    }
    const rsp: ApiMessageResult = await BookListApi.removeBook(id, bookId);
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      return `移出失败：${rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err}`;
    }
    const detail: BookDetail | null = await TalebookApi.getBookDetail(bookId);
    const title: string = detail !== null ? detail.title : `id=${bookId}`;
    return `已把《${title}》从书单「${cur.name}」移出，书本身不受影响。`;
  }

  static async pushToDevice(args: Record<string, Object>): Promise<string> {
    const bookId: number = AiToolsCore.argNumber(args, 'book_id');
    const type: string = AiToolsCore.argString(args, 'device_type').toLowerCase();
    if (bookId <= 0) {
      return '参数 book_id 无效，请先用 search_books 拿到书籍 id。';
    }
    if (type === 'ftp') {
      return 'FTP 推送需要账号凭据，请在书籍详情页「发送到设备」中操作。';
    }
    if (AiToolsExecShelf.PUSH_TOOL_TYPES.indexOf(type) < 0) {
      return `不支持的设备类型「${type}」，可选：${AiToolsExecShelf.PUSH_TOOL_TYPES.join('/')}。`;
    }
    const authenticated: boolean = await TalebookService.ensureAuthenticated();
    if (!authenticated) {
      return '尚未登录 MyBooks 服务器，无法推送。请先登录后再让我重试。';
    }
    const target: string = AiToolsCore.argString(args, 'target').trim();
    let url: string = '';
    let mailbox: string = '';
    if (type === 'kindle') {
      mailbox = target;
      if (mailbox.length === 0) {
        const devices: ReadingDevice[] = await TalebookApiBooks.getUserDevices();
        for (let i = 0; i < devices.length; i++) {
          if (devices[i].type === 'kindle' && devices[i].mailbox.length > 0) {
            mailbox = devices[i].mailbox;
            break;
          }
        }
      }
      if (mailbox.length === 0) {
        return '请提供 Kindle 邮箱（target 参数），或先在服务器「发送到设备」登记 Kindle 邮箱。';
      }
    } else {
      url = target;
      if (url.length === 0) {
        const devices: ReadingDevice[] = await TalebookApiBooks.getUserDevices();
        for (let i = 0; i < devices.length; i++) {
          if (devices[i].type === type) {
            url = `${devices[i].schema === 'https' ? 'https' : 'http'}://${devices[i].ip}:${devices[i].port}`;
            break;
          }
        }
      }
      if (url.length === 0) {
        return `服务器没有登记${deviceTypeLabel(type)}设备，请在 target 里给出设备地址（如 http://ip:端口）。`;
      }
    }
    const rsp: ApiMessageResult = await TalebookApiBooks.sendToDevice(bookId, type, url, mailbox, '', '', '');
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      return `推送失败：${rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err}`;
    }
    const detail: BookDetail | null = await TalebookApi.getBookDetail(bookId);
    const title: string = detail !== null ? detail.title : `id=${bookId}`;
    const dest: string = mailbox.length > 0 ? mailbox : url;
    return `已把《${title}》推送到${deviceTypeLabel(type)}（${dest}）。`;
  }

  static async readingStats(): Promise<string> {
    const stats: ReadingStatsSummary | null = await TalebookApiBooks.getReadingStats();
    if (stats === null) {
      return '服务器未返回阅读统计（可能未启用该功能或未登录）。';
    }
    let text: string = `阅读统计：累计在读 ${stats.totalReading} 本、累计读完 ${stats.totalReadDone} 本；` +
      `本月在读 ${stats.monthReading} 本、本月读完 ${stats.monthReadDone} 本。`;
    const reading: HomeBook[] = await TalebookApiBooks.getCurrentReadingBooks();
    if (reading.length === 0) {
      return `${text}\n当前没有在读的书记录。`;
    }
    const cap: number = Math.min(reading.length, 8);
    const lines: string[] = [];
    for (let i = 0; i < cap; i++) {
      lines.push(`- 《${reading[i].title}》（${reading[i].author.length > 0 ? reading[i].author : '佚名'}）`);
    }
    const more: string = reading.length > cap ? `\n（共 ${reading.length} 本，仅列 ${cap} 本）` : '';
    return `${text}\n当前在读：\n${lines.join('\n')}${more}`;
  }

  static async createBooklist(args: Record<string, Object>): Promise<string> {
    const name: string = AiToolsCore.argString(args, 'name');
    if (name.length === 0) {
      return '参数 name 为空，请给书单起个名字。';
    }
    const description: string = AiToolsCore.argString(args, 'description');
    const res: BookListMutationResponse =
      await BookListApi.createBooklist(name, description, BOOKLIST_DEFAULT_COLOR, true);
    if (res.err !== undefined && res.err !== 'ok') {
      return `创建书单失败：${res.msg !== undefined && res.msg.length > 0 ? res.msg : res.err}`;
    }
    const booklist: Record<string, Object> | undefined = res.booklist as Record<string, Object> | undefined;
    const id: number = booklist !== undefined ? Number(booklist['id'] ?? 0) : 0;
    return `已创建书单「${name}」${id > 0 ? `（id=${id}）` : ''}。` +
      '接下来可用 add_books_to_booklist 把 search_books 查到的书 id 加进来。';
  }

  static async addBooksToBooklist(args: Record<string, Object>): Promise<string> {
    const booklistId: number = AiToolsCore.argNumber(args, 'booklist_id');
    const raw: string = AiToolsCore.argString(args, 'book_ids');
    if (booklistId <= 0 || raw.length === 0) {
      return '参数 booklist_id 与 book_ids（逗号分隔的书籍 id）必填。';
    }
    const ids: number[] = [];
    for (const part of raw.split(',')) {
      const num: number = Number(part.trim());
      if (Number.isFinite(num) && num > 0) {
        ids.push(num);
      }
    }
    if (ids.length === 0) {
      return 'book_ids 没解析出任何有效 id。';
    }
    const res: BookListAddResponse = await BookListApi.addBooks(booklistId, ids);
    if (res.err !== undefined && res.err !== 'ok') {
      return `书单加书失败：${res.msg !== undefined && res.msg.length > 0 ? res.msg : res.err}`;
    }
    return `已把 ${res.added !== undefined ? res.added : ids.length} 本书加入书单` +
      `${res.book_count !== undefined ? `，书单现有 ${res.book_count} 本` : ''}。`;
  }

}

