export class BookshelfRefresh {
  private static readonly STORAGE_KEY: string = 'bookshelfRefreshTick';

  static init(): void {
    AppStorage.setOrCreate(BookshelfRefresh.STORAGE_KEY, 0);
  }

  static notify(): void {
    AppStorage.set(BookshelfRefresh.STORAGE_KEY, Date.now());
  }
}
