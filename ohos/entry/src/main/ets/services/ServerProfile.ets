import { PaginationConstants } from '../common/Constants';

/**
 * 服务端差异抽象层（继承 + 差异表驱动）。
 *
 * 约定：
 * - ArkTS 层一律使用抽象名（`Server*`），不绑定任何具体服务端；
 * - 具体服务端差异集中在 `ServerProfile` 子类里，新增服务端 = 新增一个子类；
 * - native 模块使用具体名（当前：`mybooks_core`）。
 *
 * 当前支持的两套服务端：
 * - MyBooks（PoxenStudio/mybooks）参考源码：`docs/mybooks/`
 * - Talebook（talebook/talebook）参考源码：`docs/talebook/`
 *
 * 差异依据（逐项核对上游 handler，勿凭印象改动）：
 * - 列表分页：两端的 ListHandler 系最终都读 `start`（偏移）+ `size`（每页），
 *   不识别 `page`/`num`/`limit`。
 *   - mybooks `webserver/handlers/base.py::get_argument_start` + `ListHandler.get_book_list`
 *   - talebook `webserver/handlers/base.py::get_argument_start` + `ListHandler.render_book_list`
 * - 「全部书籍」端点：mybooks `/api/all`，talebook `/api/library`。
 * - 元数据键：mybooks 末位是 `language`，talebook 末位是 `format`。
 */
export enum ServerKind {
  MYBOOKS = 'mybooks',
  TALEBOOK = 'talebook',
}

/** 服务端能力开关。驱动入口显隐与降级提示，避免在缺少该能力的服务端上发起必然失败的请求。 */
export enum ServerFeature {
  // 用户与认证
  ACCESS_CODE = 'access_code',
  USER_VIP = 'user_vip',
  USER_AVATAR = 'user_avatar',
  USER_EXPECTED = 'user_expected',
  USER_MEMO = 'user_memo',
  /** 服务端在线阅读历史（mybooks `/api/user/history`）。 */
  USER_ONLINE_HISTORY = 'user_online_history',
  /** 作者/标签置顶（mybooks `/api/user/pin|unpin`）。 */
  USER_PIN = 'user_pin',
  READING_DASHBOARD = 'reading_dashboard',
  // 书单与社交
  BOOKLISTS = 'booklists',
  BOOK_REVIEWS = 'book_reviews',
  BOOK_SOCIAL_STATS = 'book_social_stats',
  // 书籍扩展动作
  BOOK_WANTS = 'book_wants',
  BOOK_LOCATION = 'book_location',
  BOOK_FILE_PATH = 'book_file_path',
  BOOK_FORMAT_STATS = 'book_format_stats',
  BOOK_ADD_STAMP = 'book_add_stamp',
  BOOK_SET_SOLE = 'book_set_sole',
  BOOK_ISBN_ADD = 'book_isbn_add',
  BOOK_CROP_COVER = 'book_crop_cover',
  BOOK_TAGS_EDIT = 'book_tags_edit',
  BOOK_CATEGORY = 'book_category',
  BOOK_AIFILL = 'book_aifill',
  BOOK_SUGGESTION = 'book_suggestion',
  BOOK_SHELF = 'book_shelf',
  BOOK_PROGRESS = 'book_progress',
  /** 书籍可见范围（talebook `/api/book/{id}/setscope`）。 */
  BOOK_SCOPE = 'book_scope',
  /** 书籍媒体类型（talebook `/api/book/{id}/media_type`，电子书/漫画等）。 */
  BOOK_MEDIA_TYPE = 'book_media_type',
  /** TXT 在线阅读与解析（mybooks `/api/read/txt/{id}`、`/api/book/txt/parser`）。 */
  BOOK_TXT = 'book_txt',
  DOWNLOAD_QUOTA = 'download_quota',
  /** 作者/出版商元数据维护（mybooks `/api/author/info|bio`、`/api/author_avatar`、`/api/author|publisher/{name}/update`）。 */
  AUTHOR_META_EDIT = 'author_meta_edit',
  // 列表扩展
  PRINT_BOOKS = 'print_books',
  SOLED_BOOKS = 'soled_books',
  STATE_BATCH_REMOVE = 'state_batch_remove',
  BATCH_UPLOAD = 'batch_upload',
  // 检索
  CATEGORIES = 'categories',
  TAG_SEARCH = 'tag_search',
  AUTHOR_SEARCH = 'author_search',
  CLEAR_RARE_TAGS = 'clear_rare_tags',
  // 同步与工具箱
  SYNC = 'sync',
  TOOLBOX = 'toolbox',
  // 音频
  AUDIOBOOKS = 'audiobooks',
  // talebook 上游独有
  ANNOTATIONS = 'annotations',
  COMIC = 'comic',
  NETWORK_LIBRARY = 'network_library',
  /** 书源管理（talebook `/api/book-sources/*`，Legado 风格书源）。 */
  BOOK_SOURCES = 'book_sources',
  /** 在线书库（talebook `/api/library/online`）。 */
  LIBRARY_ONLINE = 'library_online',
  CAPTCHA = 'captcha',
  THEMES = 'themes',
  // 管理端
  ADMIN_TRASH = 'admin_trash',
  ADMIN_BOOK_REVIEWS = 'admin_book_reviews',
  ADMIN_RESOURCES = 'admin_resources',
  ADMIN_SYSLOG = 'admin_syslog',
  ADMIN_STAMP = 'admin_stamp',
  ADMIN_THANKS_NOTES = 'admin_thanks_notes',
  ADMIN_TOKEN = 'admin_token',
  ADMIN_BOOKBARN = 'admin_bookbarn',
  ADMIN_AUDIO_IMPORT = 'admin_audio_import',
  ADMIN_BATCH_ADD = 'admin_batch_add',
  ADMIN_BARCODE = 'admin_barcode',
  ADMIN_AI_TEST = 'admin_ai_test',
  /**
   * 管理端导入（扫描 → 导入工作流）。
   * mybooks：按文件路径导入（`/api/admin/import/{list,run,cancel,delete}`，`filelist` + `force`）。
   * talebook：扫描记录按 hash 导入（`/api/admin/scan/*`、`/api/admin/import/run`，`hashlist` + `import_mode`），
   * 两者工作流与请求体不兼容，客户端尚未做 UI 层重写，故 talebook 不声明该能力。
   */
  ADMIN_IMPORT = 'admin_import',
  ADMIN_TOOLBOX = 'admin_toolbox',
  ADMIN_LIBRARY_STATS = 'admin_library_stats',
  ADMIN_SYSINFO = 'admin_sysinfo',
  ADMIN_RELEASE_NOTES = 'admin_release_notes',
  ADMIN_TASKS_RUNNING = 'admin_tasks_running',
  ADMIN_INSTALL = 'admin_install',
  ADMIN_USERS = 'admin_users',
  /** 客户端新增用户（mybooks `/api/user/new`；talebook 无此接口）。 */
  ADMIN_USER_CREATE = 'admin_user_create',
  /** 管理端批量删除书籍（mybooks `/api/admin/books/delete`）。 */
  ADMIN_BOOK_DELETE = 'admin_book_delete',
  /**
   * 管理端书籍批量操作（删除/刷新元数据/AI 更新/EPUB 转换/类型互转/批量裁剪封面等）。
   * mybooks 提供全套 `/api/admin/books/*` 与 `/api/admin/book/*`；talebook 上游无对应接口，
   * 故不声明该能力，相关入口整组隐藏。
   */
  ADMIN_BOOK_BATCH = 'admin_book_batch',
  ADMIN_SETTINGS = 'admin_settings',
  ADMIN_BOOKS = 'admin_books',
  ADMIN_MEMOS = 'admin_memos',
  /** 插件体系（talebook `/api/admin/plugins/*`）。 */
  ADMIN_PLUGINS = 'admin_plugins',
  /** 目录扫描记录管理（talebook `/api/admin/scan/*`）。 */
  ADMIN_SCAN = 'admin_scan',
  /** OPDS 源浏览与导入（talebook `/api/admin/opds/*`）。 */
  ADMIN_OPDS = 'admin_opds',
  /** 服务端维护（talebook `/api/admin/update|ssl|testdb|migratedb|audio-stats|podcast-audits|book/kindleconvert`）。 */
  ADMIN_MAINTENANCE = 'admin_maintenance',
}

/** 端点调用约定（method + path）。 */
export interface ServerEndpoint {
  method: string;
  path: string;
}

/**
 * 服务端差异的唯一出口。
 *
 * 抽象成员是「必须按服务端给出答案」的差异；非抽象成员提供两端一致的默认行为，
 * 子类仅在有差异时覆盖（当前分页契约两端一致，因此不覆盖）。
 */
export abstract class ServerProfile {
  abstract readonly kind: ServerKind;

  /** 展示名，用于设置页下拉与错误提示。 */
  abstract readonly displayName: string;

  /** 「全部书籍」列表端点。 */
  abstract readonly allBooksPath: string;

  /** 有声书列表端点（mybooks `/api/audiobooks`；talebook `/api/audios`）。 */
  abstract readonly audiobooksPath: string;

  /** 管理端书籍列表端点（mybooks `/api/admin/books`；talebook `/api/admin/book/list`）。 */
  abstract readonly adminBooksPath: string;

  /** 系统日志端点（mybooks `/api/admin/syslog`；talebook `/api/admin/log`）。 */
  abstract readonly adminSyslogPath: string;

  /** 回收站书籍列表端点（mybooks `/api/admin/trash/books`；talebook `/api/admin/trash`）。 */
  abstract readonly trashBooksPath: string;

  /** 恢复回收站书籍（mybooks POST .../books/restore；talebook PATCH /api/admin/trash）。 */
  abstract readonly trashRestore: ServerEndpoint;

  /** 永久删除回收站书籍（mybooks POST .../books/purge；talebook DELETE /api/admin/trash）。 */
  abstract readonly trashPurge: ServerEndpoint;

  /** 回收站列表响应中的书籍数组键（mybooks `books`；talebook `items`）。 */
  abstract readonly trashItemsKey: string;

  /** 回收站请求体中的 id 数组键（mybooks `book_ids`；talebook `idlist`）。 */
  abstract readonly trashIdKey: string;

  /** 永久删除是否必须携带 `confirm: true`（talebook 要求，mybooks 不需要）。 */
  abstract readonly trashPurgeNeedsConfirm: boolean;

  /** 元数据列表/详情的类型键，对应服务端 `MetaList`/`MetaBooks` 的捕获组。 */
  abstract readonly metaTypes: string[];

  protected readonly features: Set<ServerFeature> = new Set<ServerFeature>();

  /**
   * 管理端书籍列表的分页查询串。
   * mybooks 走 `ListHandler` 系（start/size）；talebook 的 `AdminBookList` 自己解析 page/num。
   */
  abstract adminBooksQuery(page: number, limit: number): string;

  /**
   * 列表分页查询串。
   * 两端的 ListHandler 系只识别 `start`（偏移）+ `size`（每页条数），传 `page`/`num`/`limit`
   * 会被忽略而恒返回首页（历史事故：`/api/all` 曾因此翻页重复）。
   */
  listQuery(page: number, limit: number): string {
    const size: number = limit > 0 ? limit : PaginationConstants.DEFAULT_PAGE_SIZE;
    const start: number = page > 1 ? (page - 1) * size : 0;
    return `start=${start}&size=${size}`;
  }

  /**
   * 元数据键归一化：mybooks 末位是 `language`，talebook 末位是 `format`，其余键两者一致。
   * 用于把 UI 上的「语言」入口映射到当前服务端真实存在的键。
   */
  resolveMetaType(type: string): string {
    if (type === 'language' && this.metaTypes.indexOf('language') < 0) {
      return 'format';
    }
    if (type === 'format' && this.metaTypes.indexOf('format') < 0) {
      return 'language';
    }
    return type;
  }

  supports(feature: ServerFeature): boolean {
    return this.features.has(feature);
  }

  protected enable(features: ServerFeature[]): void {
    for (let i = 0; i < features.length; i++) {
      this.features.add(features[i]);
    }
  }
}

/** MyBooks（PoxenStudio/mybooks）服务端差异。 */
export class MyBooksProfile extends ServerProfile {
  readonly kind: ServerKind = ServerKind.MYBOOKS;
  readonly displayName: string = 'MyBooks';
  readonly allBooksPath: string = '/api/all';
  readonly audiobooksPath: string = '/api/audiobooks';
  readonly adminBooksPath: string = '/api/admin/books';
  readonly adminSyslogPath: string = '/api/admin/syslog';
  readonly metaTypes: string[] = ['author', 'publisher', 'tag', 'rating', 'series', 'language'];
  readonly trashBooksPath: string = '/api/admin/trash/books';
  readonly trashRestore: ServerEndpoint = { method: 'POST', path: '/api/admin/trash/books/restore' };
  readonly trashPurge: ServerEndpoint = { method: 'POST', path: '/api/admin/trash/books/purge' };
  readonly trashItemsKey: string = 'books';
  readonly trashIdKey: string = 'book_ids';
  readonly trashPurgeNeedsConfirm: boolean = false;

  adminBooksQuery(page: number, limit: number): string {
    return this.listQuery(page, limit);
  }

  constructor() {
    super();
    this.enable([
      ServerFeature.ACCESS_CODE,
      ServerFeature.USER_VIP,
      ServerFeature.USER_AVATAR,
      ServerFeature.USER_EXPECTED,
      ServerFeature.USER_MEMO,
      ServerFeature.USER_ONLINE_HISTORY,
      ServerFeature.USER_PIN,
      ServerFeature.READING_DASHBOARD,
      ServerFeature.BOOKLISTS,
      ServerFeature.BOOK_REVIEWS,
      ServerFeature.BOOK_SOCIAL_STATS,
      ServerFeature.BOOK_WANTS,
      ServerFeature.BOOK_LOCATION,
      ServerFeature.BOOK_FILE_PATH,
      ServerFeature.BOOK_FORMAT_STATS,
      ServerFeature.BOOK_ADD_STAMP,
      ServerFeature.BOOK_SET_SOLE,
      ServerFeature.BOOK_ISBN_ADD,
      ServerFeature.BOOK_CROP_COVER,
      ServerFeature.BOOK_TAGS_EDIT,
      ServerFeature.BOOK_CATEGORY,
      ServerFeature.BOOK_AIFILL,
      ServerFeature.BOOK_SUGGESTION,
      ServerFeature.BOOK_TXT,
      ServerFeature.AUTHOR_META_EDIT,
      ServerFeature.DOWNLOAD_QUOTA,
      ServerFeature.PRINT_BOOKS,
      ServerFeature.SOLED_BOOKS,
      ServerFeature.STATE_BATCH_REMOVE,
      ServerFeature.BATCH_UPLOAD,
      ServerFeature.CATEGORIES,
      ServerFeature.TAG_SEARCH,
      ServerFeature.AUTHOR_SEARCH,
      ServerFeature.CLEAR_RARE_TAGS,
      ServerFeature.SYNC,
      ServerFeature.TOOLBOX,
      ServerFeature.AUDIOBOOKS,
      ServerFeature.ADMIN_TRASH,
      ServerFeature.ADMIN_BOOK_REVIEWS,
      ServerFeature.ADMIN_RESOURCES,
      ServerFeature.ADMIN_SYSLOG,
      ServerFeature.ADMIN_STAMP,
      ServerFeature.ADMIN_THANKS_NOTES,
      ServerFeature.ADMIN_TOKEN,
      ServerFeature.ADMIN_BOOKBARN,
      ServerFeature.ADMIN_AUDIO_IMPORT,
      ServerFeature.ADMIN_BATCH_ADD,
      ServerFeature.ADMIN_BARCODE,
      ServerFeature.ADMIN_AI_TEST,
      ServerFeature.ADMIN_IMPORT,
      ServerFeature.ADMIN_TOOLBOX,
      ServerFeature.ADMIN_LIBRARY_STATS,
      ServerFeature.ADMIN_SYSINFO,
      ServerFeature.ADMIN_RELEASE_NOTES,
      ServerFeature.ADMIN_TASKS_RUNNING,
      ServerFeature.ADMIN_INSTALL,
      ServerFeature.ADMIN_USERS,
      ServerFeature.ADMIN_USER_CREATE,
      ServerFeature.ADMIN_BOOK_DELETE,
      ServerFeature.ADMIN_BOOK_BATCH,
      ServerFeature.ADMIN_SETTINGS,
      ServerFeature.ADMIN_BOOKS,
      ServerFeature.ADMIN_MEMOS,
    ]);
  }
}

/** Talebook（talebook/talebook）服务端差异。 */
export class TalebookProfile extends ServerProfile {
  readonly kind: ServerKind = ServerKind.TALEBOOK;
  readonly displayName: string = 'Talebook';
  readonly allBooksPath: string = '/api/library';
  readonly audiobooksPath: string = '/api/audios';
  readonly adminBooksPath: string = '/api/admin/book/list';
  readonly adminSyslogPath: string = '/api/admin/log';
  readonly metaTypes: string[] = ['author', 'publisher', 'tag', 'rating', 'series', 'format'];
  readonly trashBooksPath: string = '/api/admin/trash';
  readonly trashRestore: ServerEndpoint = { method: 'PATCH', path: '/api/admin/trash' };
  readonly trashPurge: ServerEndpoint = { method: 'DELETE', path: '/api/admin/trash' };
  readonly trashItemsKey: string = 'items';
  readonly trashIdKey: string = 'idlist';
  readonly trashPurgeNeedsConfirm: boolean = true;

  adminBooksQuery(page: number, limit: number): string {
    return `page=${page > 0 ? page : 1}&num=${limit > 0 ? limit : PaginationConstants.DEFAULT_PAGE_SIZE}`;
  }

  constructor() {
    super();
    this.enable([
      ServerFeature.BOOK_SHELF,
      ServerFeature.BOOK_PROGRESS,
      ServerFeature.BOOK_SCOPE,
      ServerFeature.BOOK_MEDIA_TYPE,
      ServerFeature.BOOK_SOURCES,
      ServerFeature.LIBRARY_ONLINE,
      ServerFeature.ANNOTATIONS,
      ServerFeature.COMIC,
      ServerFeature.NETWORK_LIBRARY,
      ServerFeature.CAPTCHA,
      ServerFeature.THEMES,
      ServerFeature.ADMIN_TRASH,
      ServerFeature.ADMIN_SYSLOG,
      ServerFeature.ADMIN_USERS,
      ServerFeature.ADMIN_BOOKS,
      ServerFeature.ADMIN_PLUGINS,
      ServerFeature.ADMIN_SCAN,
      ServerFeature.ADMIN_OPDS,
      ServerFeature.ADMIN_MAINTENANCE,
    ]);
  }
}

/** 当前服务端的解析入口。ArkTS 层其余部分只依赖本类，不直接依赖具体 Profile。 */
export class ServerRegistry {
  /** 持久化偏好键（与 native 的 baseUrl 通道名 `ServerKind` 值区分开）。 */
  static readonly PREF_KEY: string = 'server_kind';

  private static current: ServerProfile = new MyBooksProfile();

  static profile(): ServerProfile {
    return ServerRegistry.current;
  }

  static kind(): ServerKind {
    return ServerRegistry.current.kind;
  }

  /** 持久化值 → 枚举；未知/空值回退 MyBooks（既有客户端行为）。 */
  static parse(value: string): ServerKind {
    for (const candidate of [ServerKind.MYBOOKS, ServerKind.TALEBOOK]) {
      if (candidate === value) {
        return candidate;
      }
    }
    return ServerKind.MYBOOKS;
  }

  static setKind(kind: ServerKind): ServerProfile {
    switch (kind) {
      case ServerKind.TALEBOOK:
        ServerRegistry.current = new TalebookProfile();
        break;
      default:
        ServerRegistry.current = new MyBooksProfile();
        break;
    }
    return ServerRegistry.current;
  }

  static supports(feature: ServerFeature): boolean {
    return ServerRegistry.current.supports(feature);
  }

  static listQuery(page: number, limit: number): string {
    return ServerRegistry.current.listQuery(page, limit);
  }

  static allBooksPath(): string {
    return ServerRegistry.current.allBooksPath;
  }

  static audiobooksPath(): string {
    return ServerRegistry.current.audiobooksPath;
  }

  static adminBooksPath(): string {
    return ServerRegistry.current.adminBooksPath;
  }

  static adminBooksQuery(page: number, limit: number): string {
    return ServerRegistry.current.adminBooksQuery(page, limit);
  }

  static resolveMetaType(type: string): string {
    return ServerRegistry.current.resolveMetaType(type);
  }

  static trashBooksPath(): string {
    return ServerRegistry.current.trashBooksPath;
  }

  static adminSyslogPath(): string {
    return ServerRegistry.current.adminSyslogPath;
  }

  static trashRestore(): ServerEndpoint {
    return ServerRegistry.current.trashRestore;
  }

  static trashPurge(): ServerEndpoint {
    return ServerRegistry.current.trashPurge;
  }

  static trashItemsKey(): string {
    return ServerRegistry.current.trashItemsKey;
  }

  static trashIdKey(): string {
    return ServerRegistry.current.trashIdKey;
  }

  static trashPurgeNeedsConfirm(): boolean {
    return ServerRegistry.current.trashPurgeNeedsConfirm;
  }

  static metaTypes(): string[] {
    return ServerRegistry.current.metaTypes;
  }
}
