export class PaginationConstants {
  static readonly PAGE_SIZE: number = 20;
  static readonly LOAD_MORE_THRESHOLD: number = 500;
  static readonly DEBOUNCE_MS: number = 500;
}

export class PaginationHelper {
  static shouldLoadMore(offset: number, scrollRange: number, threshold: number = PaginationConstants.LOAD_MORE_THRESHOLD): boolean {
    return offset + threshold >= scrollRange;
  }

  static canLoadMore(lastLoadTime: number, loadingMore: boolean, hasMore: boolean): boolean {
    if (loadingMore || !hasMore) {
      return false;
    }
    return Date.now() - lastLoadTime >= PaginationConstants.DEBOUNCE_MS;
  }

  static computeHasMore(fetchedCount: number, pageSize: number = PaginationConstants.PAGE_SIZE): boolean {
    return fetchedCount >= pageSize;
  }
}
