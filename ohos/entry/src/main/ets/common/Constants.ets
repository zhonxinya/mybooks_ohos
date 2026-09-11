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
}

/** Pagination constants aligned with Flutter PaginationConstants. */
export class PaginationConstants {
  static readonly LOAD_MORE_SCROLL_THRESHOLD: number = 500;
  static readonly LOAD_MORE_DEBOUNCE_MS: number = 500;
  static readonly DEFAULT_PAGE_SIZE: number = 20;
}
