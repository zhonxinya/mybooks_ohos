export interface BookFile {
  format: string;
  size: number;
  href: string;
}

export interface BookState {
  favorite?: boolean;
  favorite_date?: string;
  wants?: boolean;
  wants_date?: string;
  read_state?: number;
  read_date?: string;
  online_read?: boolean;
  download?: boolean;
}

export interface Book {
  id: number;
  title: string;
  authors?: string[];
  author?: string;
  tags?: string[];
  publisher?: string;
  isbn?: string;
  series?: string;
  series_index?: string;
  rating?: number;
  languages?: string[];
  pubdate?: string;
  comments?: string;
  cover_url?: string;
  img?: string;
  thumb?: string;
  collector?: string;
  count_visit?: number;
  count_download?: number;
  sole?: boolean;
  has_audio?: boolean;
  files?: BookFile[];
  state?: BookState;
  category?: string;
  total_chapters?: number;
  page_count?: number;
  copyright?: string;
  source_url?: string;
  audios?: ESObject[];
  book_id?: string;
  has_audio_conversion?: boolean;
  audio_conversion_in_progress?: boolean;
  audio_conversion_progress?: number;
  timestamp?: string;
  book_type?: number;
  book_count?: number;
  dynamic_cover?: boolean;
  ext_link?: string;
  author_url?: string;
  publisher_url?: string;
  is_public?: boolean;
  is_owner?: boolean;
}

export interface BookListResponse {
  err?: string;
  total?: number;
  books?: Book[];
}

export interface IndexResponse {
  random_books?: Book[];
  new_books?: Book[];
}

export interface BookDetailResponse {
  err?: string;
  book?: Book;
}

export interface NavTag {
  name: string;
  count: number;
}

export interface NavCategory {
  legend: string;
  tags?: NavTag[];
}

export interface BookNavResponse {
  navs?: NavCategory[];
}

export interface ApiResponse {
  err?: string;
  msg?: string;
}

export interface UserInfo {
  avatar?: string;
  is_login?: boolean;
  is_admin?: boolean;
  nickname?: string;
  email?: string;
}

export interface SystemInfo {
  books?: number;
  tags?: number;
  authors?: number;
  audiobooks?: number;
  version?: string;
  title?: string;
  language?: string;
  theme?: string;
  aiEnabled?: boolean;
}

export interface UserInfoResponse {
  err?: string;
  cdn?: string;
  sys?: SystemInfo;
  user?: UserInfo;
}

export interface ReadingProgress {
  book_id?: string;
  chapter_index?: number;
  current_page?: number;
  total_pages?: number;
  progress_percent?: number;
  last_read_time?: number;
  chapter_id?: string;
  chapter_name?: string;
  cfi?: string;
  dom_pos?: string;
}

export interface BookMetadata {
  authors?: string[];
  rating?: number;
  tags?: string[];
  publisher?: string;
  description?: string;
  cover_url?: string;
  img?: string;
  thumb?: string;
  local_cover_path?: string;
  total_chapters?: number;
  download_url?: string;
}

export interface DownloadRecord {
  book_id: string;
  book_title: string;
  file_path: string;
  format?: string;
  source_label?: string;
  download_time?: number;
  metadata?: BookMetadata;
  progress?: ReadingProgress;
}

export interface ReadingHistoryItem {
  book_id: string;
  book_title?: string;
  file_path?: string;
  format?: string;
  download_url?: string;
  chapter_name?: string;
  chapter_index?: number;
  current_page?: number;
  total_pages?: number;
  progress_percent?: number;
  last_read_time?: number;
  location?: string;
}

export interface SoNovelSearchResult {
  sourceId: number;
  sourceName: string;
  url: string;
  bookName: string;
  author: string;
  category?: string;
  latestChapter?: string;
  lastUpdateTime?: string;
  status?: string;
}

export interface ReadKitLocation {
  resourceIndex: number;
  domPos: string;
}

export interface ReadKitProgress {
  location: ReadKitLocation;
  resourceIndex: number;
  currentPage: number;
  totalPages: number;
  progression: number;
  chapterName: string;
}

export interface ReadKitBookmark {
  id: string;
  title: string;
  location: ReadKitLocation;
}

export interface ReadKitSettings {
  themeName?: string;
  fontName?: string;
  fontPath?: string;
  fontSize?: number;
  fontWeight?: number;
  lineHeight?: number;
  themeColor?: string;
  fontColor?: string;
  flipMode?: string;
  nightMode?: boolean;
}

export interface ReadKitOpenParams {
  filePath: string;
  sessionId?: string;
  bookId?: string;
  format?: string;
  bookTitle?: string;
  downloadUrl?: string;
  resourceIndex?: number;
  domPos?: string;
  bookmarks?: ReadKitBookmark[];
}

export interface ReadKitEventPayload {
  version: number;
  sessionId: string;
  bookId: string;
  type: string;
  progress?: ReadKitProgress;
  bookmark?: ReadKitBookmark;
  settings?: ReadKitSettings;
  errorCode?: string;
  errorMessage?: string;
}
