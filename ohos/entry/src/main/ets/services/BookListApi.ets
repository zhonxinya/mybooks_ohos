/** 书单 REST API（/api/booklists/*、/api/booklist/*、/api/book/:id/booklists）。 */
import { TalebookCoreService } from './TalebookCoreService';
import { TalebookService } from './TalebookService';
import { ApiMessageResult } from './TalebookApi';
import {
  BookListDetailData, BookListQuickItem, BookListSummary,
  parseBookListDetail, parseBookListQuickItems, parseBookListSummaries,
} from '../models/BookListModels';

export interface BookListsPageResponse extends ApiMessageResult {
  booklists?: Object;
  total?: number;
  page?: number;
  page_size?: number;
}

export interface BookListsResponse extends ApiMessageResult {
  booklists?: Object;
}

export interface BookListMutationResponse extends ApiMessageResult {
  booklist?: Object;
}

export interface BookListLikeResponse extends ApiMessageResult {
  liked?: boolean;
}

export interface BookListAddResponse extends ApiMessageResult {
  added?: number;
  book_count?: number;
}

export interface BookListDetailResponse extends ApiMessageResult {
  booklist?: Object;
}

export interface BookBookListsResponse extends ApiMessageResult {
  booklists?: Object;
}

export interface BookListUpdatePayload {
  name?: string;
  description?: string;
  color?: string;
  is_public?: boolean;
}

interface CreateBooklistPayload {
  name: string;
  description: string;
  color: string;
  is_public: boolean;
}

interface StickyPayload {
  is_sticky: boolean;
}

interface AddBooksPayload {
  book_ids: number[];
}

interface RemoveBookPayload {
  book_id: number;
}

export class BookListApi {
  /**
   * 需要登录的书单接口统一走这里。
   *
   * 为什么需要：服务端 `auth` 对未登录请求返回 `{"err":"user.need_login","msg":"请先登录"}`。
   * 客户端本地存有凭据 ≠ 服务端会话有效（服务端重启会换掉 secure cookie 签名密钥，
   * 本地 `cookies.txt` 随之失效）。这类请求原先直接把服务端原文弹给用户，
   * 表现为「加入书单报错：请先登录」且无任何恢复动作。
   *
   * 处理：先确保登录态；若服务端仍回未登录，则强制重新登录一次并重试**一次**；
   * 依旧失败则把该结果原样返回，由调用方提示（不再静默或重复弹错）。
   */
  private static async authed<T extends ApiMessageResult>(run: () => Promise<T>,
    retried: boolean = false): Promise<T> {
    let loggedIn = false;
    if (TalebookService.hasAuthCredentials()) {
      loggedIn = await TalebookService.ensureAuthenticated();
    }
    const rsp = await run();
    if (!retried && TalebookService.isLoginRequiredResult(rsp)) {
      // 会话失效：重新登录后重试一次
      if (!loggedIn) {
        loggedIn = await TalebookService.ensureAuthenticated();
      }
      if (loggedIn) {
        return BookListApi.authed(run, true);
      }
    }
    return rsp;
  }

  static async getPublicBooklists(page: number, pageSize: number): Promise<BookListsPageResponse> {
    const raw = await TalebookCoreService.talebookGet(
      `/api/booklists/public?page=${page}&page_size=${pageSize}`);
    return JSON.parse(raw) as BookListsPageResponse;
  }

  static async getMyBooklists(): Promise<BookListsResponse> {
    return BookListApi.authed<BookListsResponse>(async (): Promise<BookListsResponse> => {
      const raw = await TalebookCoreService.talebookGet('/api/booklists/mine');
      return JSON.parse(raw) as BookListsResponse;
    });
  }

  static async getLikedBooklists(): Promise<BookListsResponse> {
    return BookListApi.authed<BookListsResponse>(async (): Promise<BookListsResponse> => {
      const raw = await TalebookCoreService.talebookGet('/api/booklists/liked');
      return JSON.parse(raw) as BookListsResponse;
    });
  }

  /** 首页书单推荐（最多 2 个，游客可访问）。 */
  static async getHomepageBooklists(): Promise<BookListsResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/booklists/homepage');
    return JSON.parse(raw) as BookListsResponse;
  }

  static async createBooklist(name: string, description: string, color: string,
    isPublic: boolean): Promise<BookListMutationResponse> {
    return BookListApi.authed<BookListMutationResponse>(async (): Promise<BookListMutationResponse> => {
      const payload: CreateBooklistPayload = {
        name: name,
        description: description,
        color: color,
        is_public: isPublic,
      };
      const raw = await TalebookCoreService.talebookPost('/api/booklist/create',
        JSON.stringify(payload));
      return JSON.parse(raw) as BookListMutationResponse;
    });
  }

  static async updateBooklist(id: number, payload: BookListUpdatePayload):
    Promise<BookListMutationResponse> {
    return BookListApi.authed<BookListMutationResponse>(async (): Promise<BookListMutationResponse> => {
      const raw = await TalebookCoreService.talebookPost(
        `/api/booklist/${id}/update`, JSON.stringify(payload as Record<string, Object>));
      return JSON.parse(raw) as BookListMutationResponse;
    });
  }

  static async deleteBooklist(id: number): Promise<ApiMessageResult> {
    return BookListApi.authed<ApiMessageResult>(async (): Promise<ApiMessageResult> => {
      const raw = await TalebookCoreService.talebookPost(`/api/booklist/${id}/delete`, '{}');
      return JSON.parse(raw) as ApiMessageResult;
    });
  }

  static async setSticky(id: number, isSticky: boolean): Promise<BookListMutationResponse> {
    return BookListApi.authed<BookListMutationResponse>(async (): Promise<BookListMutationResponse> => {
      const payload: StickyPayload = { is_sticky: isSticky };
      const raw = await TalebookCoreService.talebookPost(
        `/api/booklist/${id}/sticky`, JSON.stringify(payload));
      return JSON.parse(raw) as BookListMutationResponse;
    });
  }

  static async toggleLike(id: number): Promise<BookListLikeResponse> {
    return BookListApi.authed<BookListLikeResponse>(async (): Promise<BookListLikeResponse> => {
      const raw = await TalebookCoreService.talebookPost(`/api/booklist/${id}/like`, '{}');
      return JSON.parse(raw) as BookListLikeResponse;
    });
  }

  static async bumpView(id: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/booklist/${id}/view`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async getBooklistDetail(id: number, page: number, pageSize: number, order: string):
    Promise<BookListDetailResponse> {
    const raw = await TalebookCoreService.talebookGet(
      `/api/booklist/${id}?page=${page}&page_size=${pageSize}&order=${order}`);
    return JSON.parse(raw) as BookListDetailResponse;
  }

  static async addBooks(id: number, bookIds: number[]): Promise<BookListAddResponse> {
    return BookListApi.authed<BookListAddResponse>(async (): Promise<BookListAddResponse> => {
      const payload: AddBooksPayload = { book_ids: bookIds };
      const raw = await TalebookCoreService.talebookPost(
        `/api/booklist/${id}/books/add`, JSON.stringify(payload));
      return JSON.parse(raw) as BookListAddResponse;
    });
  }

  static async removeBook(id: number, bookId: number): Promise<ApiMessageResult> {
    return BookListApi.authed<ApiMessageResult>(async (): Promise<ApiMessageResult> => {
      const payload: RemoveBookPayload = { book_id: bookId };
      const raw = await TalebookCoreService.talebookPost(
        `/api/booklist/${id}/books/remove`, JSON.stringify(payload));
      return JSON.parse(raw) as ApiMessageResult;
    });
  }

  static async getBookBooklists(bookId: number): Promise<BookBookListsResponse> {
    return BookListApi.authed<BookBookListsResponse>(async (): Promise<BookBookListsResponse> => {
      const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/booklists`);
      return JSON.parse(raw) as BookBookListsResponse;
    });
  }

  static parseSummaries(payload: BookListsResponse | BookListsPageResponse): BookListSummary[] {
    return parseBookListSummaries(payload.booklists);
  }

  static parseDetail(payload: BookListDetailResponse): BookListDetailData | null {
    if (payload.booklist === undefined || payload.booklist === null) {
      return null;
    }
    return parseBookListDetail(payload.booklist as Record<string, Object>);
  }

  static parseQuickItems(payload: BookBookListsResponse): BookListQuickItem[] {
    return parseBookListQuickItems(payload.booklists);
  }
}
