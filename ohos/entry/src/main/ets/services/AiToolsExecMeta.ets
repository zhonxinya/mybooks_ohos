/**
 * 元数据/检索类工具执行器（拆分自 AiTools.ets）：分类、元数据写改、封面、
 * search_meta/get_novel_meta、百科、网页搜索、AI 联网问答。
 * 失败处理契约在门面 AiTools.execute；共享缓存一律走 AiToolsCore。
 */
import { ReferBook, ReferSearchOpts, ReferSearchResponse, TalebookApi } from './TalebookApi';
import { TalebookApiBooks } from './TalebookApiBooks';
import { TalebookService } from './TalebookService';
import { DoubanDetail, DoubanHit, MetaSearchService } from './MetaSearchService';
import { NovelMeta, NovelMetaService } from './NovelMetaService';
import { EncyclopediaHit, EncyclopediaService, WebSearchResult } from './EncyclopediaService';
import { WebSearchHit } from './WebSearchChannels';
import { WebFetchResult, WebFetchService } from './WebFetchService';
import { BrowserRenderService } from './BrowserRenderService';
import { AiService, AiConfig, LlmSearchResult, LlmSearchSource } from './AiService';
import { AiToolsCore } from './AiToolsCore';
import { AiToolsExecShelf } from './AiToolsExecShelf';

export class AiToolsExecMeta {
  /**
   * 更新书籍元数据。服务端 /api/book/:id/edit 是全量表单提交（BookEditPage 同款 payload），
   * 因此先读现值、只覆盖用户点名要改的字段，再整体提交，避免未传字段被清空。
   */
  /** 书库分类体系（/api/book/nav 的 legend+tags），update_book_meta 归类前的查询依据。 */
  static async listCategories(): Promise<string> {
    const envelope = await TalebookService.getBookNavCachedAsync();
    const body: Record<string, Object> = envelope.body ?? {};
    const navs: Object | undefined = body['navs'];
    if (!Array.isArray(navs) || navs.length === 0) {
      return '没有读到分类列表（服务器可能尚未配置分类，或书库接口不可用）。';
    }
    const lines: string[] = [];
    for (let i = 0; i < navs.length; i++) {
      const nav = navs[i] as Record<string, Object>;
      const legend: string = String(nav['legend'] ?? '');
      if (legend.length === 0) {
        continue;
      }
      const tags: Object | undefined = nav['tags'];
      const tagNames: string[] = [];
      if (Array.isArray(tags)) {
        for (let j = 0; j < tags.length; j++) {
          const tag = tags[j] as Record<string, Object>;
          const tagName: string = String(tag['name'] ?? '');
          if (tagName.length > 0) {
            tagNames.push(tagName);
          }
        }
      }
      lines.push(tagNames.length > 0 ? `· ${legend}：${tagNames.join('/')}` : `· ${legend}`);
    }
    return `在线书库现有 ${lines.length} 个分类（给书设 category 时优先从中选择；也可用其中的子标签作为 tags）：\n${lines.join('\n')}`;
  }

  static async updateBookMeta(args: Record<string, Object>): Promise<string> {
    const bookId: number = AiToolsCore.argNumber(args, 'book_id');
    if (bookId <= 0) {
      return '参数 book_id 需要是正整数（可先用 search_books 查到 id）。';
    }
    const envelope = await TalebookService.getBookDetailAsync(bookId);
    const body: Record<string, Object> = envelope.body ?? {};
    const book: Record<string, Object> = (body['book'] as Record<string, Object> | undefined) ?? body;
    const oldTitle: string = String(book['title'] ?? '');
    if (oldTitle.length === 0) {
      return `没有找到 id=${bookId} 的书。`;
    }
    const oldAuthors: string[] = Array.isArray(book['authors']) ? (book['authors'] as string[]) : [];
    const oldTags: string[] = Array.isArray(book['tags']) ? (book['tags'] as string[]) : [];
    const oldCategory: string = String(book['category'] ?? '');
    const changes: string[] = [];
    const newTitle: string = AiToolsCore.argString(args, 'title').length > 0
      ? AiToolsCore.argString(args, 'title').trim() : oldTitle;
    if (newTitle !== oldTitle) {
      changes.push(`书名「${oldTitle}」→「${newTitle}」`);
    }
    let authors: string[] = oldAuthors;
    if (AiToolsCore.argString(args, 'authors').length > 0) {
      authors = AiToolsCore.argString(args, 'authors').split(',').map((s: string) => s.trim()).filter((s: string) => s.length > 0);
      changes.push(`作者 →「${authors.join('、')}」`);
    }
    let tags: string[] = oldTags;
    if (AiToolsCore.argString(args, 'tags').length > 0) {
      tags = AiToolsCore.argString(args, 'tags').split(',').map((s: string) => s.trim()).filter((s: string) => s.length > 0);
      changes.push(`标签 →「${tags.join('、')}」`);
    }
    // 分类：单值字符串（edit 接口实测字段名 category；categories 会被服务端忽略）
    let category: string = oldCategory;
    if (AiToolsCore.argString(args, 'category').length > 0 && AiToolsCore.argString(args, 'category').trim() !== oldCategory) {
      category = AiToolsCore.argString(args, 'category').trim();
      changes.push(oldCategory.length > 0 ? `分类「${oldCategory}」→「${category}」` : `分类 →「${category}」`);
    }
    const publisher: string = AiToolsCore.argString(args, 'publisher').length > 0
      ? AiToolsCore.argString(args, 'publisher').trim() : String(book['publisher'] ?? '');
    if (publisher !== String(book['publisher'] ?? '')) {
      changes.push(`出版社 →「${publisher}」`);
    }
    const isbn: string = AiToolsCore.argString(args, 'isbn').length > 0
      ? AiToolsCore.argString(args, 'isbn').trim() : String(book['isbn'] ?? '');
    if (isbn !== String(book['isbn'] ?? '')) {
      changes.push(`ISBN →「${isbn}」`);
    }
    const series: string = AiToolsCore.argString(args, 'series').length > 0
      ? AiToolsCore.argString(args, 'series').trim() : String(book['series'] ?? '');
    if (series !== String(book['series'] ?? '')) {
      changes.push(`丛书 →「${series}」`);
    }
    const comments: string = AiToolsCore.argString(args, 'comment').length > 0
      ? AiToolsCore.argString(args, 'comment') : String(book['comments'] ?? '');
    if (comments !== String(book['comments'] ?? '')) {
      changes.push('简介已更新');
    }
    const rating: number = AiToolsCore.argNumber(args, 'rating');
    if (changes.length === 0 && rating <= 0) {
      return '没有要修改的字段（所有参数都留空了）。';
    }
    const payload: Record<string, Object> = {
      'title': newTitle,
      'authors': authors,
      'publisher': publisher,
      'comments': comments,
      'tags': tags,
      'category': category,
      'isbn': isbn,
      'series': series,
      'languages': Array.isArray(book['languages']) ? (book['languages'] as string[]) : [],
      'translators': Array.isArray(book['translators']) ? (book['translators'] as string[]) : [],
    };
    const oldSeriesIndex: Object = book['series_index'];
    if (oldSeriesIndex !== undefined && oldSeriesIndex !== null) {
      payload['series_index'] = Number(oldSeriesIndex);
    }
    if (rating > 0) {
      payload['rating'] = Math.min(10, Math.round(rating));
      changes.push(`评分 →${payload['rating']}`);
    }
    const rsp = await TalebookService.editBookAsync(bookId, payload);
    if (rsp.status < 200 || rsp.status >= 300) {
      return `更新失败（${rsp.error.length > 0 ? rsp.error : `HTTP ${rsp.status}`}）。`;
    }
    // #1638：同步本地书架快照——更新元数据不再需要重新下载整本书才生效
    TalebookService.syncDownloadMeta(`${bookId}`, newTitle, authors.length > 0 ? authors[0] : '', '');
    return `已更新《${newTitle}》：${changes.join('；')}`;
  }

  static async searchCover(args: Record<string, Object>): Promise<string> {
    const bookId: number = AiToolsCore.argNumber(args, 'book_id');
    if (bookId <= 0) {
      return '参数 book_id 需要是正整数（可先用 search_books 查到 id）。';
    }
    const opts: ReferSearchOpts = {};
    if (AiToolsCore.argString(args, 'title').length > 0) {
      opts.title = AiToolsCore.argString(args, 'title').trim();
    }
    if (AiToolsCore.argString(args, 'isbn').length > 0) {
      opts.isbn = AiToolsCore.argString(args, 'isbn').trim();
    }
    if (AiToolsCore.argString(args, 'publisher').length > 0) {
      opts.publisher = AiToolsCore.argString(args, 'publisher').trim();
    }
    const rsp: ReferSearchResponse = await TalebookApiBooks.searchRefer(bookId, opts);
    if (rsp.books.length === 0) {
      return '互联网上没有检索到该书的元数据候选。可尝试补充更准确的 ISBN 再查。';
    }
    AiToolsCore.lastCoverCandidates = rsp.books;
    AiToolsCore.lastCoverBookId = bookId;
    const lines: string[] = [];
    for (let i = 0; i < rsp.books.length; i++) {
      const b: ReferBook = rsp.books[i];
      const authors: string[] = b.authors ?? [];
      lines.push(`- 候选${i + 1}：《${b.title ?? ''}》（${authors.join('、')}）` +
        `出版社：${b.publisher ?? '未知'}　来源：${b.source}　封面：${b.cover_url ?? ''}`);
    }
    return `找到 ${rsp.books.length} 条候选（换封面用 set_cover 传 index）：\n${lines.join('\n')}`;
  }

  /**
   * 多通道元数据搜索聚合：豆瓣直连（suggest/detail）、服务端 refer（book_id）、
   * 网文源（query，复用 searchSoNovel）。各通道独立降级，单站失败不影响其余。
   */
  static async searchMeta(args: Record<string, Object>): Promise<string> {
    const query: string = AiToolsCore.argString(args, 'query').trim();
    const isbn: string = AiToolsCore.argString(args, 'isbn').trim();
    const subjectId: string = AiToolsCore.argString(args, 'subject_id').trim();
    const bookId: number = AiToolsCore.argNumber(args, 'book_id');
    // 详情模式：只要豆瓣 subject 详情，一次把评分/出版社/ISBN 给全
    if (subjectId.length > 0) {
      const d: DoubanDetail = await MetaSearchService.detail(subjectId);
      if (!d.ok) {
        return `豆瓣详情获取失败：${d.error}`;
      }
      const fields: string[] = [`《${d.title}》${d.author.length > 0 ? `（${d.author}）` : ''}`];
      if (d.rating.length > 0) {
        fields.push(`豆瓣评分：${d.rating}`);
      }
      if (d.publisher.length > 0) {
        fields.push(`出版社：${d.publisher}`);
      }
      if (d.publishYear.length > 0) {
        fields.push(`出版时间：${d.publishYear}`);
      }
      if (d.isbn.length > 0) {
        fields.push(`ISBN：${d.isbn}`);
      }
      if (d.pages.length > 0) {
        fields.push(`页数：${d.pages}`);
      }
      if (d.binding.length > 0) {
        fields.push(`装帧：${d.binding}`);
      }
      if (d.price.length > 0) {
        fields.push(`定价：${d.price}`);
      }
      let out: string = `豆瓣详情：\n${fields.join('\n')}`;
      if (d.intro.length > 0) {
        out += `\n简介：\n${d.intro}`;
      }
      return out;
    }
    const sections: string[] = [];
    if (bookId > 0) {
      const opts: ReferSearchOpts = {};
      if (query.length > 0) {
        opts.title = query;
      }
      if (isbn.length > 0) {
        opts.isbn = isbn;
      }
      const rsp: ReferSearchResponse = await TalebookApiBooks.searchRefer(bookId, opts);
      // 候选同时缓存给 set_cover 复用（与 search_cover 同一约定）
      AiToolsCore.lastCoverCandidates = rsp.books;
      AiToolsCore.lastCoverBookId = bookId;
      const lines: string[] = [];
      for (let i = 0; i < rsp.books.length && i < 12; i++) {
        const b: ReferBook = rsp.books[i];
        const authors: string[] = b.authors ?? [];
        lines.push(`- 候选${i + 1}：《${b.title ?? ''}》（${authors.join('、')}）` +
          `出版社：${b.publisher ?? '未知'}　ISBN：${b.isbn ?? ''}　来源：${b.source}　封面：${b.cover_url ?? ''}`);
      }
      sections.push(lines.length > 0
        ? `服务端多源候选（id=${bookId}，换封面可直接 set_cover 传 index）：\n${lines.join('\n')}`
        : `服务端多源没有 id=${bookId} 的候选。`);
    }
    const kw: string = isbn.length > 0 ? isbn : query;
    if (kw.length > 0) {
      try {
        const hits: DoubanHit[] = await MetaSearchService.suggest(kw);
        if (hits.length > 0) {
          const lines: string[] = [];
          for (let i = 0; i < hits.length; i++) {
            const h: DoubanHit = hits[i];
            lines.push(`- 《${h.title}》（${h.author}）${h.year}　subject_id=${h.subjectId}　封面：${h.cover}`);
          }
          sections.push(`豆瓣检索「${kw}」（要评分/出版社就用 subject_id 再查）：\n${lines.join('\n')}`);
        } else {
          sections.push(`豆瓣没有「${kw}」的匹配。`);
        }
      } catch (error) {
        sections.push(`豆瓣检索失败：${error instanceof Error ? error.message : String(error)}`);
      }
    }
    if (query.length > 0) {
      sections.push(await AiToolsExecShelf.searchSoNovel(query));
    }
    if (sections.length === 0) {
      return '请至少提供 query（书名）/ isbn / subject_id / book_id 之一。';
    }
    return sections.join('\n\n');
  }

  /**
   * 网文元数据补全：抓书源站详情页解析简介/封面（so-novel 聚合搜索不提供这两样的补丁通道）。
   */
  static async getNovelMeta(args: Record<string, Object>): Promise<string> {
    const url: string = AiToolsCore.argString(args, 'url').trim();
    if (url.length === 0) {
      return '参数 url 必填（search_sonovel 结果里的书源站详情页地址）。';
    }
    const meta: NovelMeta = await NovelMetaService.fetchDetail(url);
    if (!meta.ok) {
      return `网文元数据获取失败：${meta.error}\nurl：${url}`;
    }
    const head: string[] = [];
    if (meta.title.length > 0) {
      head.push(`书名：${meta.title}`);
    }
    if (meta.author.length > 0) {
      head.push(`作者：${meta.author}`);
    }
    if (meta.category.length > 0) {
      head.push(`类别：${meta.category}`);
    }
    if (meta.status.length > 0) {
      head.push(`状态：${meta.status}`);
    }
    let out: string = `网文元数据（规则：${meta.rule}，来源 ${url}）：\n${head.join('　')}`;
    if (meta.cover.length > 0) {
      out += `\n封面：${meta.cover}`;
    }
    if (meta.intro.length > 0) {
      out += `\n简介：\n${meta.intro}`;
    }
    out += '\n要把简介写进书架用 update_book_meta 的 comment 字段。';
    return out;
  }

  /**
   * 百科双通道聚合：各通道独立容错（EncyclopediaService 已把网络失败转成 ok=false），
   * 全失败才回失败文案——不抛错，避免 execute 层对「被墙」这类确定性失败做无意义重试。
   */
  static async searchEncyclopedia(query: string): Promise<string> {
    const trimmed: string = query.trim();
    if (trimmed.length === 0) {
      return '参数 query 为空，请提供百科词条关键词。';
    }
    const bk: EncyclopediaHit = await EncyclopediaService.searchBaike(trimmed);
    const wk: EncyclopediaHit = await EncyclopediaService.searchWikipedia(trimmed);
    if (!bk.ok && !wk.ok) {
      return `百科检索失败：百度百科（${bk.error}）；维基百科（${wk.error}）`;
    }
    const parts: string[] = [];
    if (bk.ok) {
      parts.push(`【百度百科】${bk.title}\n${bk.abstract}\n链接：${bk.url}`);
    } else {
      parts.push(`【百度百科】未获取到：${bk.error}`);
    }
    if (wk.ok) {
      parts.push(`【维基百科】${wk.title}\n${wk.abstract}\n链接：${wk.url}`);
    } else {
      parts.push(`【维基百科】未获取到：${wk.error}`);
    }
    return parts.join('\n\n');
  }

  /** 通用网页搜索：编号列出标题/链接/摘要；失败如实回文案（同百科通道风格，不抛错）。 */
  static async searchWeb(query: string): Promise<string> {
    const trimmed: string = query.trim();
    if (trimmed.length === 0) {
      return '参数 query 为空，请提供搜索关键词。';
    }
    const res: WebSearchResult = await EncyclopediaService.searchWeb(trimmed);
    if (!res.ok) {
      return `网页搜索失败：${res.error}`;
    }
    const parts: string[] = [];
    for (let i = 0; i < res.items.length; i++) {
      const it: WebSearchHit = res.items[i];
      let line: string = `${i + 1}. [${it.source}] ${it.title}\n链接：${it.url}`;
      if (it.summary.length > 0) {
        line = `${line}\n${it.summary}`;
      }
      parts.push(line);
    }
    // #1633：逐引擎命中数回传，某引擎恒 0 即改版/反爬信号，不再静默
    return `${parts.join('\n\n')}\n\n[通道统计] ${res.stats}`;
  }

  /** 访问具体网页：标题 + 来源 + 正文纯文本；HTTP 拿不到正文时自动走 ArkWeb 渲染降级。 */
  static async fetchUrl(url: string): Promise<string> {
    const trimmed: string = url.trim();
    if (trimmed.length === 0) {
      return '参数 url 为空，请提供要访问的网页地址。';
    }
    const res: WebFetchResult = await WebFetchService.fetch(trimmed);
    if (res.ok) {
      const head: string = res.title.length > 0 ? `《${res.title}》\n` : '';
      return `${head}来源：${trimmed}\n———— 正文 ————\n${res.text}`;
    }
    // 类浏览器降级：JS 空壳/反爬拦截页交给隐藏渲染器真渲染后取 innerText
    if (res.hint === 'render' && BrowserRenderService.isReady()) {
      const rendered: string = await BrowserRenderService.render(trimmed);
      if (rendered.length > 0) {
        return `来源：${trimmed}\n———— 正文（浏览器渲染提取） ————\n${rendered}`;
      }
      return `网页抓取失败：${res.error}（已尝试浏览器渲染，仍未取得正文，页面可能需登录或已失效）`;
    }
    return `网页抓取失败：${res.error}`;
  }

  /** AI 联网问答：通义系 enable_search 直出整合答案＋引用；非通义服务商回明确提示（模型可改用 search_web）。 */
  static async aiSearch(query: string): Promise<string> {
    const trimmed: string = query.trim();
    if (trimmed.length === 0) {
      return '参数 query 为空，请提供要联网查证的问题。';
    }
    const cfg: AiConfig = AiService.loadConfig();
    if (!AiService.supportsNativeOnlineSearch(cfg.baseUrl)) {
      return '当前服务商不支持 AI 联网搜索（仅通义千问/阿里云 DashScope 系可用），请改用 search_web 获取链接清单。';
    }
    const res: LlmSearchResult = await AiService.aiSearchOnline(trimmed);
    if (!res.ok) {
      return `AI 联网搜索失败：${res.error}`;
    }
    let out: string = res.answer.trim();
    if (res.sources.length > 0) {
      const refs: string[] = [];
      for (let i = 0; i < res.sources.length; i++) {
        const s: LlmSearchSource = res.sources[i];
        refs.push(`${i + 1}. ${s.title} ${s.url}`);
      }
      out = `${out}\n\n引用来源：\n${refs.join('\n')}`;
    }
    return out;
  }

  static async setCover(args: Record<string, Object>): Promise<string> {
    const bookId: number = AiToolsCore.argNumber(args, 'book_id');
    if (bookId <= 0) {
      return '参数 book_id 需要是正整数（可先用 search_books 查到 id）。';
    }
    if (AiToolsCore.lastCoverBookId !== bookId || AiToolsCore.lastCoverCandidates.length === 0) {
      return `id=${bookId} 没有可引用的封面候选，请先对该书调用 search_cover。`;
    }
    const index: number = AiToolsCore.argNumber(args, 'index');
    if (index < 1 || index > AiToolsCore.lastCoverCandidates.length) {
      return `候选序号 ${index} 超出范围（当前有效 1-${AiToolsCore.lastCoverCandidates.length}）。`;
    }
    const entry: ReferBook = AiToolsCore.lastCoverCandidates[index - 1];
    if ((entry.cover_url ?? '').length === 0) {
      return `候选${index}没有封面图片 url，请换一条候选。`;
    }
    const rsp = await TalebookApiBooks.applyRefer(bookId, entry, false, true);
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      return `换封面失败：${(rsp.msg ?? '').length > 0 ? rsp.msg : rsp.err}`;
    }
    return `已将 id=${bookId} 的封面换成候选${index}（来源 ${entry.source}），其余元数据未动。`;
  }

}

