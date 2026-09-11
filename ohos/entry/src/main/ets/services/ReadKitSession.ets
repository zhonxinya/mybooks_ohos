import { DownloadRecord, ReadingHistoryItem, ReadingProgress, TalebookService } from './TalebookService';
import { ReadKitBookmarkPayload } from '../models/ReadKitTypes';
import { BookshelfRefresh } from '../utils/BookshelfRefresh';

export class ReadKitSession {
  private static readonly PROGRESS_DEBOUNCE_MS: number = 2500;
  private static readonly HISTORY_MAX: number = 200;
  private static progressTimer: number = -1;
  private static dirty: boolean = false;

  static handleProgress(bookId: string, title: string, filePath: string, format: string,
    chapterName: string, currentPage: number, location: string): void {
    const now = Date.now();
    const historyKey = bookId.length > 0 ? bookId : filePath;
    const item: ReadingHistoryItem = {
      bookId: historyKey,
      title: title,
      filePath: filePath,
      format: format,
      chapterName: chapterName,
      currentPage: currentPage,
      lastReadTime: now,
      location: location,
    };
    // 翻页只改内存；落盘与书架刷新防抖，避免越读越卡
    TalebookService.upsertHistoryItem(item, false);
    const history = TalebookService.getReadingHistory();
    if (history.length > ReadKitSession.HISTORY_MAX) {
      TalebookService.replaceReadingHistory(history.slice(0, ReadKitSession.HISTORY_MAX), false);
    }
    ReadKitSession.dirty = true;
    if (historyKey.length === 0) {
      ReadKitSession.scheduleProgressFlush();
      return;
    }
    const progress: ReadingProgress = {
      lastReadTime: now,
      chapterName: chapterName,
      currentPage: currentPage,
      location: location,
    };
    const records = TalebookService.getDownloads();
    let index = records.findIndex((record) => record.bookId === bookId && bookId.length > 0);
    if (index < 0 && filePath.length > 0) {
      index = records.findIndex((record) => record.filePath === filePath);
    }
    if (index >= 0) {
      const updated: DownloadRecord = {
        bookId: records[index].bookId,
        title: records[index].title,
        author: records[index].author,
        coverUrl: records[index].coverUrl,
        filePath: records[index].filePath,
        format: records[index].format,
        downloadTime: records[index].downloadTime,
        progress: progress,
      };
      records[index] = updated;
      TalebookService.saveDownloads(records, false, false);
    }
    ReadKitSession.scheduleProgressFlush();
  }

  static flushProgress(notifyBookshelf: boolean = true): void {
    if (ReadKitSession.progressTimer >= 0) {
      clearTimeout(ReadKitSession.progressTimer);
      ReadKitSession.progressTimer = -1;
    }
    if (!ReadKitSession.dirty) {
      return;
    }
    TalebookService.persistLocalCaches();
    ReadKitSession.dirty = false;
    if (notifyBookshelf) {
      BookshelfRefresh.notify();
    }
  }

  private static scheduleProgressFlush(): void {
    if (ReadKitSession.progressTimer >= 0) {
      return;
    }
    ReadKitSession.progressTimer = setTimeout(() => {
      ReadKitSession.progressTimer = -1;
      // 阅读中只落盘，退出阅读器时再刷书架
      if (ReadKitSession.dirty) {
        TalebookService.persistLocalCaches();
        ReadKitSession.dirty = false;
      }
    }, ReadKitSession.PROGRESS_DEBOUNCE_MS);
  }

  static handleBookmarkAdded(bookId: string, bookmark: ReadKitBookmarkPayload): void {
    const bookmarks = TalebookService.getBookmarks();
    const record: Record<string, Object> = {
      'bookId': bookId,
      'id': bookmark.id,
      'title': bookmark.title,
      'location': bookmark.location,
    };
    bookmarks.unshift(record);
    if (bookmarks.length > 500) {
      bookmarks.length = 500;
    }
    TalebookService.saveBookmarks(bookmarks);
  }

  static handleBookmarkRemoved(bookId: string, bookmarkId: string): void {
    const bookmarks = TalebookService.getBookmarks().filter((item) =>
      !(String(item['bookId'] ?? '') === bookId && String(item['id'] ?? '') === bookmarkId));
    TalebookService.saveBookmarks(bookmarks);
  }
}
