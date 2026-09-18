/**
 * 书库列表页的刷新广播：书架（BookshelfPage）与小说导航页（BooksTabPage）各监听一个 tick。
 *
 * 为什么分成两个 tick：小说页签在 Tabs 里常驻（第一次进入后就不再销毁），整页重取要清空列表、
 * 会闪一下骨架屏，所以只在「书库确实变了」（删除/上传/元数据变更）时通知它；书架页沿用原有语义
 * （切回书架时也重取），保持不动。
 */
export class BookshelfRefresh {
  private static readonly SHELF_KEY: string = 'bookshelfRefreshTick';
  private static readonly BOOKS_TAB_KEY: string = 'booksTabRefreshTick';

  static init(): void {
    AppStorage.setOrCreate(BookshelfRefresh.SHELF_KEY, 0);
    AppStorage.setOrCreate(BookshelfRefresh.BOOKS_TAB_KEY, 0);
  }

  /** 通知书架页重取（原有语义） */
  static notify(): void {
    AppStorage.setOrCreate(BookshelfRefresh.SHELF_KEY, Date.now());
  }

  /** 通知小说导航页重取：删除图书、上传入库、应用引用信息等改变书库内容的操作后调用 */
  static notifyBooksTab(): void {
    AppStorage.setOrCreate(BookshelfRefresh.BOOKS_TAB_KEY, Date.now());
  }
}
