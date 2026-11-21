/**
 * TalebookApi 书籍详情与用户域域（拆分自 TalebookApi.ets，800 行门禁）：nav/上传/编辑/refer 元数据/音频/书评社交/阅读统计/心愿单/留言/设备/转换/分类元表。
 */
import { BookNavResponse } from '../common/Models';
import { AudioInfoResponse, AudioConversionResponse, AudioCollectionResponse, AudioPurchaseResponse, EditBookRequest, ReferBook } from '../common/ApiTypes';
import { BookItem } from './BookModels';
import { BookReviewItem, BookSocialStats, parseBookReview, parseBookReviews, parseSocialStats } from '../models/BookReviewModels';
import { HomeBook, ReadingDashboard, ReadingStatsSummary, parseHomeBooks, parseReadingDashboard, parseReadingStatsSummary } from '../models/HomeModels';
import { ExpectedItemModel, UserMemoItem, parseExpectedItems, parseUserMemos } from '../models/UserModels';
import { FormatReadingStat, ReadingDevice, parseFormatStats, parseReadingDevices } from '../models/DeviceModels';
import { TalebookCoreService } from './TalebookCoreService';
import { ServerRegistry } from './ServerProfile';
import { ApiMessageResult, ApiResult, BatchCategoryOpts, BatchCategoryResponse, BatchTagUpdateResponse, BookFilePathResponse, ClearRareTagsResponse, TxtParserResponse, TxtReadResponse, UploadBookResponse } from './TalebookApiTypes';
import { parseJsonOrOk, appendQuery, buildPagePath, parseJsonAsync, parseList, AvatarUploadResponse, UserUpdatePayload, MemoCreatePayload, ExpectedCreatePayload, ExpectedDeletePayload, MemoDataPayload, DevicesPayload, FormatStatsPayload, SendDevicePayload, SendMailPayload, WantsPayload, FormatPayload, CropCoverPayload, CropCoverIdsPayload, CropCoverResult, BatchRemoveStatePayload, PinPayload, CategoryPayload, CategoriesPayload, AuthorsPayload, TagsPayload, MetaListResponse, AuthorInfoResponse, ReferListPayload, ReferSearchOpts, ReferSearchResponse, MetaNameCount, parseNameCounts, fetchStateList, ReadStatePayload, ReviewPayload, ReviewsPayload, OwnReviewPayload, ReadingStatsPayload, IndexHomeData } from './TalebookApiUtil';

export class TalebookApiBooks {
  static async getBookNav(): Promise<BookNavResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/book/nav');
    return JSON.parse(raw) as BookNavResponse;
  }

  /** 元数据下的书籍（GET /api/{meta}/{name}；meta 键按 ServerProfile 归一化，如 language↔format）。 */
  static async getBooksByMeta(metaType: string, name: string, page: number, limit: number): Promise<BookItem[]> {
    const raw = await TalebookCoreService.talebookGet(
      buildPagePath(`/api/${ServerRegistry.resolveMetaType(metaType)}/${encodeURIComponent(name)}`, page, limit));
    return parseList(raw);
  }

  /** 上传本地书籍文件到服务器（multipart，字段 ebook）；bookId 非空时表示向已有书籍追加格式 */
  static async uploadBookFile(filePath: string, fileName: string, bookId: number = 0):
    Promise<UploadBookResponse> {
    const raw = await TalebookCoreService.talebookUploadBook(filePath, fileName, bookId > 0 ? `${bookId}` : '');
    return JSON.parse(raw) as UploadBookResponse;
  }

  static async editBook(bookId: number, data: EditBookRequest): Promise<void> {    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/edit`, JSON.stringify(data));
    const resp = JSON.parse(raw) as ApiResult;
    if (resp.err !== undefined && resp.err !== 'ok') {
      throw new Error(resp.err);
    }
  }

  static async searchRefer(bookId: number, opts?: ReferSearchOpts): Promise<ReferSearchResponse> {
    let path = `/api/book/${bookId}/refer`;
    if (opts !== undefined) {
      if (opts.title !== undefined && opts.title.length > 0) {
        path = appendQuery(path, 'title', opts.title);
      }
      if (opts.isbn !== undefined && opts.isbn.length > 0) {
        path = appendQuery(path, 'isbn', opts.isbn);
      }
      if (opts.publisher !== undefined && opts.publisher.length > 0) {
        path = appendQuery(path, 'publisher', opts.publisher);
      }
    }
    const raw = await TalebookCoreService.talebookGet(path);
    const resp = JSON.parse(raw) as ReferListPayload;
    const books = resp.books ?? [];
    const result: ReferBook[] = [];
    for (let i = 0; i < books.length; i++) {
      const item = books[i];
      result.push({
        cover_url: String(item['cover_url'] ?? ''),
        source: String(item['source'] ?? ''),
        website: String(item['website'] ?? ''),
        title: String(item['title'] ?? ''),
        author_sort: String(item['author_sort'] ?? ''),
        authors: (item['authors'] as string[] | undefined) ?? [],
        comments: String(item['comments'] ?? ''),
        isbn: String(item['isbn'] ?? ''),
        isbn13: String(item['isbn13'] ?? ''),
        publisher: String(item['publisher'] ?? ''),
        language: String(item['language'] ?? ''),
        identifiers: item['identifiers'] as Record<string, Object> | undefined,
        tags: (item['tags'] as string[] | undefined) ?? [],
        series: String(item['series'] ?? ''),
        pubdate: String(item['pubdate'] ?? ''),
        pubyear: String(item['pubyear'] ?? ''),
        provider_key: String(item['provider_key'] ?? ''),
        provider_value: String(item['provider_value'] ?? ''),
        rating: Number(item['rating'] ?? 0),
      });
    }
    const out: ReferSearchResponse = {
      books: result,
    };
    if (resp.err !== undefined) {
      out.err = resp.err;
    }
    if (resp.msg !== undefined) {
      out.msg = resp.msg;
    }
    if (resp.cached !== undefined) {
      out.cached = resp.cached;
    }
    return out;
  }

  /** 应用引用元数据（POST /api/book/:id/refer，form：provider_key/provider_value/metadata）。 */
  static async applyRefer(bookId: number, data: ReferBook, onlyMeta: boolean = false,
    onlyCover: boolean = false): Promise<ApiMessageResult> {
    let path = `/api/book/${bookId}/refer`;
    if (onlyMeta) {
      path = appendQuery(path, 'only_meta', 'yes');
    } else if (onlyCover) {
      path = appendQuery(path, 'only_cover', 'yes');
    }
    const form = `provider_key=${encodeURIComponent(data.provider_key ?? '')}` +
      `&provider_value=${encodeURIComponent(data.provider_value ?? '')}` +
      `&metadata=${encodeURIComponent(JSON.stringify(data))}`;
    const raw = await TalebookCoreService.talebookPostForm(path, form);
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 重置引用（用本地信息覆盖，POST /api/book/:id/refer?reset=yes）。 */
  static async resetRefer(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/refer?reset=yes`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async getAudioList(bookId: number): Promise<AudioInfoResponse> {
    const raw = await TalebookCoreService.talebookGet(`/api/audio/${bookId}`);
    return JSON.parse(raw) as AudioInfoResponse;
  }
  /** 有声书列表（mybooks `/api/audiobooks`；talebook `/api/audios`，均 start/size 分页）。 */
  static async getAudiobooks(page: number = 1, size: number = 60): Promise<BookItem[]> {
    const path = `${ServerRegistry.audiobooksPath()}?${ServerRegistry.listQuery(page, size)}`;
    const raw = await TalebookCoreService.talebookGet(path);
    return parseList(raw);
  }

  /** 查询有声转换进度（GET /api/audio/:id/conversion）。 */
  static async getAudioConversionStatus(bookId: number): Promise<AudioConversionResponse> {
    const raw = await TalebookCoreService.talebookGet(`/api/audio/${bookId}/conversion`);
    return JSON.parse(raw) as AudioConversionResponse;
  }

  /** 启动有声转换（POST /api/audio/:id/conversion，管理员；默认云健 Neural）。 */
  static async startAudioConversion(
    bookId: number,
    voice: string = 'zh-CN-YunjianNeural',
    language: string = 'zh-CN',
  ): Promise<AudioConversionResponse> {
    const body: Record<string, Object> = { 'voice': voice, 'language': language };
    const raw = await TalebookCoreService.talebookPost(`/api/audio/${bookId}/conversion`,
      JSON.stringify(body));
    return JSON.parse(raw) as AudioConversionResponse;
  }

  /** 取消有声转换（POST /api/audio/:id/cancel，管理员）。 */
  static async cancelAudioConversion(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/audio/${bookId}/cancel`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 删除书籍音频文件（POST /api/audio/:id/delete，管理员）。 */
  static async deleteAudio(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/audio/${bookId}/delete`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 购买有声书（POST /api/audio/:id/purchase）。 */
  static async purchaseAudio(bookId: number): Promise<AudioPurchaseResponse> {
    const raw = await TalebookCoreService.talebookPost(`/api/audio/${bookId}/purchase`, '{}');
    return JSON.parse(raw) as AudioPurchaseResponse;
  }

  /** 生成合集下载链接（GET /api/audios/:id/collection）。 */
  static async createAudioCollectionDownload(bookId: number): Promise<AudioCollectionResponse> {
    const raw = await TalebookCoreService.talebookGet(`/api/audios/${bookId}/collection`);
    return JSON.parse(raw) as AudioCollectionResponse;
  }

  /** 单章音频相对路径（GET /api/audio/:id/:filename，二进制流）。 */
  static audioFilePath(bookId: number, filename: string): string {
    return `/api/audio/${bookId}/${encodeURIComponent(filename)}`;
  }

  /** 合集 zip 相对路径（GET /api/audios/:id/collection/download?key=）。 */
  static audioCollectionDownloadPath(bookId: number, key: string): string {
    return `/api/audios/${bookId}/collection/download?key=${encodeURIComponent(key)}`;
  }

  /** 设置阅读状态：0 未读 / 1 在读 / 2 已读完（POST /api/book/:id/readstate）。 */
  static async setReadState(bookId: number, readState: number): Promise<ApiMessageResult> {
    const payload: ReadStatePayload = { read_state: readState };
    const raw = await TalebookCoreService.talebookPost(
      `/api/book/${bookId}/readstate`, JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 在读/读完/收藏/推荐人数（游客可访问）。 */
  static async getSocialStats(bookId: number): Promise<BookSocialStats | null> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/social-stats`);
    const resp = JSON.parse(raw) as ApiResult;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return null;
    }
    return parseSocialStats(resp as Record<string, Object>);
  }

  /** 书籍书评列表（最近最多 50 条，当前用户置顶）。 */
  static async getBookReviews(bookId: number): Promise<BookReviewItem[]> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/reviews`);
    const resp = JSON.parse(raw) as ReviewsPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseBookReviews(resp.reviews);
  }

  /** 取当前用户对该书的评价（未评价时返回 null）。 */
  static async getOwnReview(bookId: number): Promise<BookReviewItem | null> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/review`);
    const resp = JSON.parse(raw) as OwnReviewPayload;
    if (resp.err !== undefined && resp.err !== 'ok' || resp.review === undefined || resp.review === null) {
      return null;
    }
    return parseBookReview(resp.review as Record<string, Object>);
  }

  /** 提交/更新当前用户评价（rating 0-10）。 */
  static async submitReview(bookId: number, rating: number, comment: string):
    Promise<ApiMessageResult> {
    const payload: ReviewPayload = { rating: rating, comment: comment };
    const raw = await TalebookCoreService.talebookPost(
      `/api/book/${bookId}/review`, JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 删除当前用户评价。 */
  static async deleteReview(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookDelete(`/api/book/${bookId}/review`);
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 当前用户阅读统计（/api/reading/stats，需登录）。 */
  static async getReadingStats(): Promise<ReadingStatsSummary | null> {
    const raw = await TalebookCoreService.talebookGet('/api/reading/stats');
    const resp = JSON.parse(raw) as ReadingStatsPayload;
    if (resp.err !== undefined && resp.err !== 'ok' || resp.stats === undefined) {
      return null;
    }
    return parseReadingStatsSummary(resp.stats as Record<string, Object>);
  }

  /** 当前用户在读书籍（/api/reading/stats 内嵌列表）。 */
  static async getCurrentReadingBooks(): Promise<HomeBook[]> {
    const raw = await TalebookCoreService.talebookGet('/api/reading/stats');
    const resp = JSON.parse(raw) as ReadingStatsPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseHomeBooks(resp.current_reading_books);
  }

  /** 首页阅读时长横幅（/api/user/reading_stats，未启用/未登录返回 null）。 */
  static async getReadingDashboard(): Promise<ReadingDashboard | null> {
    const raw = await TalebookCoreService.talebookGet('/api/user/reading_stats');
    const resp = JSON.parse(raw) as Record<string, Object>;
    if (resp['err'] !== 'ok' || resp['enabled'] !== true) {
      return null;
    }
    return parseReadingDashboard(resp);
  }

  /** 首页随机推荐 + 社交推荐 + 新书推荐（/api/index）。 */
  static async getIndexHome(): Promise<IndexHomeData> {
    const raw = await TalebookCoreService.talebookGet('/api/index');
    const resp = await parseJsonAsync(raw) as Record<string, Object>;
    return {
      randomBooks: parseHomeBooks(resp['random_books']),
      socialBooks: parseHomeBooks(resp['social_recommend_books']),
      newBooks: parseHomeBooks(resp['new_books']),
    };
  }

  /** 想读清单（/api/wants，需登录，start/size 分页）。 */
  static async getWantsBooks(page: number, size: number): Promise<BookItem[]> {
    return fetchStateList('/api/wants', page, size);
  }

  /** 已读完书籍（/api/read-done，需登录）。 */
  static async getReadDoneBooks(page: number, size: number): Promise<BookItem[]> {
    return fetchStateList('/api/read-done', page, size);
  }

  /** 私有范围书籍（mybooks `/api/soledbooks`；talebook `/api/scopedbooks`，均需登录）。 */
  static async getScopedBooks(page: number, size: number): Promise<BookItem[]> {
    return fetchStateList(ServerRegistry.profile().scopedBooksPath, page, size);
  }

  /** 保存个人设置（POST /api/user/update）。 */
  static async updateUserSettings(payload: UserUpdatePayload): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/user/update',
      JSON.stringify(payload as Record<string, Object>));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 当前用户留言列表（GET /api/user/memo）。 */
  static async getUserMemos(page: number, pageSize: number): Promise<UserMemoItem[]> {
    const raw = await TalebookCoreService.talebookGet(
      `/api/user/memo?page=${page}&page_size=${pageSize}`);
    const resp = JSON.parse(raw) as MemoDataPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    const data = (resp.data as Record<string, Object> | undefined) ?? {};
    return parseUserMemos(data['items']);
  }

  /** 新建留言（memo_type：0 建议 / 1 求书 / 2 求助）。 */
  static async createMemo(memo: string, memoType: number): Promise<ApiMessageResult> {
    const payload: MemoCreatePayload = { memo: memo, memo_type: memoType };
    const raw = await TalebookCoreService.talebookPost('/api/user/memo', JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 求书期望列表（GET /api/user/expected）。 */
  static async getExpectedItems(): Promise<ExpectedItemModel[]> {
    const raw = await TalebookCoreService.talebookGet('/api/user/expected');
    const resp = JSON.parse(raw) as MemoDataPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    const data = (resp.data as Record<string, Object> | undefined) ?? {};
    return parseExpectedItems(data['items']);
  }

  /** 新建求书期望。 */
  static async createExpectedItem(title: string, author: string, publisher: string):
    Promise<ApiMessageResult> {
    const payload: ExpectedCreatePayload = {
      title: title,
      author: author,
      publisher: publisher,
    };
    const raw = await TalebookCoreService.talebookPost('/api/user/expected', JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 删除求书期望。 */
  static async deleteExpectedItem(id: number): Promise<ApiMessageResult> {
    const payload: ExpectedDeletePayload = { id: id };
    const raw = await TalebookCoreService.talebookDeleteWithBody('/api/user/expected',
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 上传头像（POST /api/user/avatar，multipart 字段 avatar）。 */
  static async uploadAvatar(localPath: string, fileName: string): Promise<AvatarUploadResponse> {
    const raw = await TalebookCoreService.talebookUploadFile('/api/user/avatar', localPath,
      'avatar', fileName);
    return JSON.parse(raw) as AvatarUploadResponse;
  }

  /** 服务端版本更新说明（/api/admin/release/notes，无更新时 msg 为空）。 */
  static async getReleaseNotes(): Promise<string> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/release/notes');
    const resp = JSON.parse(raw) as ApiMessageResult;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return '';
    }
    return resp.msg !== undefined ? resp.msg : '';
  }

  /** 当前用户阅读设备列表（GET /api/user/devices）。 */
  static async getUserDevices(): Promise<ReadingDevice[]> {
    const raw = await TalebookCoreService.talebookGet('/api/user/devices');
    const resp = JSON.parse(raw) as DevicesPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseReadingDevices(resp.devices);
  }

  /** 推送书籍到设备（POST /api/book/:id/send_to_device）。 */
  static async sendToDevice(bookId: number, deviceType: string, deviceUrl: string,
    mailbox: string, ftpUsername: string, ftpPassword: string, ftpPath: string):
    Promise<ApiMessageResult> {
    const payload: SendDevicePayload = {
      device_type: deviceType,
      device_url: deviceUrl,
      mailbox: mailbox,
      ftp_username: ftpUsername,
      ftp_password: ftpPassword,
      ftp_path: ftpPath,
    };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/send_to_device`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 邮件分享书籍（POST /api/book/:id/mailto）。 */
  static async sendToMail(bookId: number, email: string, format: string):
    Promise<ApiMessageResult> {
    const payload: SendMailPayload = { email: email, format: format };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/mailto`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** AI 补全单本元数据（POST /api/book/:id/aifill）。 */
  static async aiFillBook(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/aifill`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 设置/取消想读（POST /api/book/:id/wants）。 */
  static async setWants(bookId: number, wants: boolean): Promise<ApiMessageResult> {
    const payload: WantsPayload = { wants: wants };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/wants`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 每格式阅读统计（GET /api/book/:id/reading_stats）。 */
  static async getFormatReadingStats(bookId: number): Promise<FormatReadingStat[]> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/reading_stats`);
    const resp = JSON.parse(raw) as FormatStatsPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseFormatStats(resp.stats);
  }

  /** 同类推荐图书（GET /api/book/:id/suggestion）。 */
  static async getBookSuggestions(bookId: number): Promise<BookItem[]> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/suggestion`);
    return parseList(raw);
  }

  /** 同名图书（GET /api/search?title=&exclude=）。 */
  static async searchSameTitleBooks(title: string, excludeId: number): Promise<BookItem[]> {
    const path = `/api/search?title=${encodeURIComponent(title)}&exclude=${excludeId}`;
    const raw = await TalebookCoreService.talebookGet(path);
    return parseList(raw);
  }

  /** 服务端在线阅读历史（GET /api/user/history，最多 12 本）。 */
  static async getOnlineReadingHistory(): Promise<BookItem[]> {
    const raw = await TalebookCoreService.talebookGet('/api/user/history');
    return parseList(raw);
  }

  /** 清空服务端在线阅读历史（POST /api/user/history/clear）。 */
  static async clearOnlineReadingHistory(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/user/history/clear', '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 转换书籍格式（POST /api/book/:id/convert，EPUB/Kindle 互转）。 */
  static async convertBook(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/convert`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 转换为 PDF（POST /api/book/:id/topdf）。 */
  static async convertBookToPdf(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/topdf`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 将指定格式分离为新书籍（POST /api/book/:id/separate）。 */
  static async separateFormat(bookId: number, format: string): Promise<ApiMessageResult> {
    const payload: FormatPayload = { format: format };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/separate`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 删除书籍的指定格式（POST /api/book/:id/delete_format）。 */
  static async deleteFormat(bookId: number, format: string): Promise<ApiMessageResult> {
    const payload: FormatPayload = { format: format };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/delete_format`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }
  /** 删除整本书（POST /api/book/:id/delete）。需编辑/删除权限或书籍所有者。 */
  static async deleteBook(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/delete`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 上传封面（POST /api/book/:id/cover，multipart 字段 cover_data）。 */
  static async uploadCover(bookId: number, localPath: string, fileName: string):
    Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookUploadFile(`/api/book/${bookId}/cover`,
      localPath, 'cover_data', fileName);
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 生成默认封面（POST /api/book/:id/cover，无文件时服务端自动生成）。 */
  static async generateDefaultCover(bookId: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/cover`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 裁剪封面白边（POST /api/book/crop_cover）。 */
  static async cropCover(bookId: number): Promise<CropCoverResult> {
    const payload: CropCoverPayload = { id: bookId };
    const raw = await TalebookCoreService.talebookPost('/api/book/crop_cover',
      JSON.stringify(payload));
    return JSON.parse(raw) as CropCoverResult;
  }

  /** 批量裁剪封面白边（POST /api/book/crop_cover）。 */
  static async cropCovers(bookIds: number[]): Promise<CropCoverResult> {
    const payload: CropCoverIdsPayload = { ids: bookIds };
    const raw = await TalebookCoreService.talebookPost('/api/book/crop_cover',
      JSON.stringify(payload));
    return JSON.parse(raw) as CropCoverResult;
  }

  /** 分类列表（GET /api/categories）。 */
  static async getCategories(): Promise<MetaNameCount[]> {
    const raw = await TalebookCoreService.talebookGet('/api/categories');
    const resp = JSON.parse(raw) as CategoriesPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseNameCounts(resp.categories);
  }

  /** 作者联想（GET /api/authors/search?q=）。 */
  static async searchAuthors(query: string): Promise<MetaNameCount[]> {
    const path = appendQuery('/api/authors/search', 'q', query);
    const raw = await TalebookCoreService.talebookGet(path);
    const resp = JSON.parse(raw) as AuthorsPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseNameCounts(resp.authors);
  }
  /** 标签联想（GET /api/tags/search?q=&limit=）。 */
  static async searchTags(query: string, limit: number = 20): Promise<MetaNameCount[]> {
    let path = appendQuery('/api/tags/search', 'q', query);
    path = appendQuery(path, 'limit', limit);
    const raw = await TalebookCoreService.talebookGet(path);
    const resp = JSON.parse(raw) as TagsPayload;
    if (resp.err !== undefined && resp.err !== 'ok') {
      return [];
    }
    return parseNameCounts(resp.tags);
  }

  /**
   * 元数据列表（GET /api/{meta}?show=all）。
   * meta 键按 ServerProfile 归一化：mybooks 为 author|publisher|tag|rating|series|language，
   * talebook 为 author|publisher|tag|rating|series|format。
   */
  static async getMetaList(metaType: string, showAll: boolean = false): Promise<MetaListResponse> {
    let path = `/api/${ServerRegistry.resolveMetaType(metaType)}`;
    if (showAll) {
      path = `${path}?show=all`;
    }
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as MetaListResponse;
  }

  /** 作者扩展信息（GET /api/author/info?name=）：bio/avatar/region 等。 */
  static async getAuthorInfo(name: string): Promise<AuthorInfoResponse> {
    const path = appendQuery('/api/author/info', 'name', name);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as AuthorInfoResponse;
  }

  /** 保存作者简介（POST /api/author/bio，管理员）。 */
  static async updateAuthorBio(name: string, bio: string): Promise<AuthorInfoResponse> {
    const body: Record<string, Object> = { 'name': name, 'bio': bio };
    const raw = await TalebookCoreService.talebookPost('/api/author/bio', JSON.stringify(body));
    return JSON.parse(raw) as AuthorInfoResponse;
  }

  /** 更新作者名下书籍元数据（POST /api/author/:name/update；服务端可能 302 重定向）。 */
  static async updateAuthorBooks(authorName: string): Promise<ApiMessageResult> {
    const path = `/api/author/${encodeURIComponent(authorName)}/update`;
    const raw = await TalebookCoreService.talebookPost(path, '{}');
    return parseJsonOrOk(raw);
  }

  /** 更新出版社名下书籍元数据（POST /api/publisher/:name/update；服务端可能 302 重定向）。 */
  static async updatePublisherBooks(publisherName: string): Promise<ApiMessageResult> {
    const path = `/api/publisher/${encodeURIComponent(publisherName)}/update`;
    const raw = await TalebookCoreService.talebookPost(path, '{}');
    return parseJsonOrOk(raw);
  }

  /** 上传作者头像（POST /api/author_avatar，multipart 字段 avatar_data；author 走 query）。 */
  static async uploadAuthorAvatar(authorName: string, localPath: string, fileName: string):
    Promise<ApiMessageResult> {
    const path = `/api/author_avatar?author=${encodeURIComponent(authorName)}`;
    const raw = await TalebookCoreService.talebookUploadFile(path, localPath, 'avatar_data', fileName);
    return parseJsonOrOk(raw);
  }


  /** 置顶作者/标签（POST /api/user/pin，itemType 0=作者 1=标签）。 */
  static async pinItem(itemType: number, value: string): Promise<ApiMessageResult> {
    const payload: PinPayload = { item_type: itemType, value: value };
    const raw = await TalebookCoreService.talebookPost('/api/user/pin', JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 取消置顶（POST /api/user/unpin）。 */
  static async unpinItem(itemType: number, value: string): Promise<ApiMessageResult> {
    const payload: PinPayload = { item_type: itemType, value: value };
    const raw = await TalebookCoreService.talebookPost('/api/user/unpin', JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 批量移除阅读状态（POST /api/books/batch-remove-state，action: favorite/wants/reading/read-done）。 */
  static async batchRemoveState(bookIds: number[], action: string): Promise<ApiMessageResult> {
    const payload: BatchRemoveStatePayload = { book_ids: bookIds, action: action };
    const raw = await TalebookCoreService.talebookPost('/api/books/batch-remove-state',
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 设置书籍分类（POST /api/book/:id/category）。 */
  static async setBookCategory(bookId: number, category: string): Promise<ApiMessageResult> {
    const payload: CategoryPayload = { category: category };
    const raw = await TalebookCoreService.talebookPost(`/api/book/${bookId}/category`,
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 查询书籍文件路径（GET /api/book/:id/filepath?format=epub|pdf）。 */
  static async getBookFilePath(bookId: number, format: string): Promise<BookFilePathResponse> {
    const path = appendQuery(`/api/book/${bookId}/filepath`, 'format', format);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as BookFilePathResponse;
  }

  /** 读取 TXT 内容片段（GET /api/read/txt/:id?start=&end=）。 */
  static async readTxtContent(bookId: number, start: number = 0, end: number = -1): Promise<TxtReadResponse> {
    let path = `/api/read/txt/${bookId}`;
    path = appendQuery(path, 'start', start);
    path = appendQuery(path, 'end', end);
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as TxtReadResponse;
  }

  /** TXT 书籍解析（GET /api/book/txt/parser?id=&test=）。 */
  static async parseTxtBook(bookId: number, testReady: boolean = true): Promise<TxtParserResponse> {
    let path = '/api/book/txt/parser';
    path = appendQuery(path, 'id', bookId);
    path = appendQuery(path, 'test', testReady ? '1' : '0');
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as TxtParserResponse;
  }

  /** 按标签名批量刷新书籍标签（POST /api/book/update_tags?tag=，body 为空）。 */
  static async updateBooksTagsByTag(tag: string): Promise<BatchTagUpdateResponse> {
    const path = appendQuery('/api/book/update_tags', 'tag', tag);
    const raw = await TalebookCoreService.talebookPost(path, '{}');
    return JSON.parse(raw) as BatchTagUpdateResponse;
  }

  /** 按作者/标签/系列批量设置分类（POST /api/book/category；与单本 setBookCategory 不同）。 */
  static async batchSetBookCategory(category: string, opts?: BatchCategoryOpts): Promise<BatchCategoryResponse> {
    const options: BatchCategoryOpts = opts !== undefined ? opts : {};
    const body: Record<string, Object> = { 'category': category };
    if (options.author !== undefined && options.author.length > 0) {
      body['author'] = options.author;
    }
    if (options.tag !== undefined && options.tag.length > 0) {
      body['tag'] = options.tag;
    }
    if (options.series !== undefined && options.series.length > 0) {
      body['series'] = options.series;
    }
    const raw = await TalebookCoreService.talebookPost('/api/book/category', JSON.stringify(body));
    return JSON.parse(raw) as BatchCategoryResponse;
  }

  /** 清理稀有标签（POST /api/clear_rare_tags）。 */
  static async clearRareTags(): Promise<ClearRareTagsResponse> {
    const raw = await TalebookCoreService.talebookPost('/api/clear_rare_tags', '{}');
    return JSON.parse(raw) as ClearRareTagsResponse;
  }

  /** 书籍下载路径（GET /api/book/:id.:format；二进制，供下载器/WebView）。 */
}

