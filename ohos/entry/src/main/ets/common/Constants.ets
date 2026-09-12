/** Shared storage keys aligned with Flutter AppConfig / SecureStorage. */
export class StorageKeys {
  static readonly TALEBOOK_URL: string = 'talebook_url';
  static readonly SONOVEL_URL: string = 'sonovel_url';
  static readonly SONOVEL_KEY: string = 'sonovel_key';
  static readonly READER_CONFIG: string = 'reader_config';
  static readonly INDEPENDENT_PROGRESS: string = 'independent_progress';
  static readonly DOWNLOAD_RECORDS: string = 'download_records';
  static readonly THEME_MODE: string = 'theme_mode';
  static readonly SHOW_BACK_BUTTON: string = 'show_back_button';
  static readonly BOOKSHELF_LIST_MODE: string = 'bookshelf_list_mode';
  static readonly NOVELS_GRID_MODE: string = 'novels_grid_mode';
  static readonly READING_HISTORY: string = 'reading_history';
  static readonly READING_BOOKMARKS: string = 'reading_bookmarks';
  /** 客户端自更新检查：最近一次成功结果的缓存（ReleaseInfo JSON）。 */
  static readonly UPDATE_RELEASE_CACHE: string = 'update_release_cache';
  /** 客户端自更新检查：最近一次成功检查的时间戳（毫秒）。 */
  static readonly UPDATE_CHECKED_AT: string = 'update_checked_at';
  /** 客户端自更新检查：用户选择「忽略此版本」的 tag。 */
  static readonly UPDATE_SKIPPED_TAG: string = 'update_skipped_tag';
  /** 客户端自更新检查：已弹过启动提示的 tag。 */
  static readonly UPDATE_PROMPTED_TAG: string = 'update_prompted_tag';
  /** 客户端自更新检查：可升级版本号提示（AppStorage 键，空串表示无提示）。 */
  static readonly UPDATE_HINT_VERSION: string = 'update_hint_version';
}

/** Pagination constants aligned with Flutter PaginationConstants. */
export class PaginationConstants {
  static readonly LOAD_MORE_SCROLL_THRESHOLD: number = 500;
  static readonly LOAD_MORE_DEBOUNCE_MS: number = 500;
  static readonly DEFAULT_PAGE_SIZE: number = 20;
}
