/** 书单 REST API（/api/booklists/*、/api/booklist/*、/api/book/:id/booklists）。 */
import { TalebookCoreService } from './TalebookCoreService';
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
  static async getPublicBooklists(page: number, pageSize: number): Promise<BookListsPageResponse> {
    const raw = await TalebookCoreService.talebookGet(
      `/api/booklists/public?page=${page}&page_size=${pageSize}`);
    return JSON.parse(raw) as BookListsPageResponse;
  }

  static async getMyBooklists(): Promise<BookListsResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/booklists/mine');
    return JSON.parse(raw) as BookListsResponse;
  }

  static async getLikedBooklists(): Promise<BookListsResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/booklists/liked');
    return JSON.parse(raw) as BookListsResponse;
  }

  /** 首页书单推荐（最多 2 个，游客可访问）。 */
  static async getHomepageBooklists(): Promise<BookListsResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/booklists/homepage');
    return JSON.parse(raw) as BookListsResponse;
  }

  static async createBooklist(name: string, description: string, color: string,
    isPublic: boolean): Promise<BookListMutationResponse> {
    const payload: CreateBooklistPayload = {
      name: name,
      description: description,
      color: color,
      is_public: isPublic,
    };
    const raw = await TalebookCoreService.talebookPost('/api/booklist/create',
      JSON.stringify(payload));
    return JSON.parse(raw) as BookListMutationResponse;
  }

  static async updateBooklist(id: number, payload: BookListUpdatePayload):
    Promise<BookListMutationResponse> {
    const raw = await TalebookCoreService.talebookPost(
      `/api/booklist/${id}/update`, JSON.stringify(payload as Record<string, Object>));
    return JSON.parse(raw) as BookListMutationResponse;
  }

  static async deleteBooklist(id: number): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/booklist/${id}/delete`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async setSticky(id: number, isSticky: boolean): Promise<BookListMutationResponse> {
    const payload: StickyPayload = { is_sticky: isSticky };
    const raw = await TalebookCoreService.talebookPost(
      `/api/booklist/${id}/sticky`, JSON.stringify(payload));
    return JSON.parse(raw) as BookListMutationResponse;
  }

  static async toggleLike(id: number): Promise<BookListLikeResponse> {
    const raw = await TalebookCoreService.talebookPost(`/api/booklist/${id}/like`, '{}');
    return JSON.parse(raw) as BookListLikeResponse;
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
    const payload: AddBooksPayload = { book_ids: bookIds };
    const raw = await TalebookCoreService.talebookPost(
      `/api/booklist/${id}/books/add`, JSON.stringify(payload));
    return JSON.parse(raw) as BookListAddResponse;
  }

  static async removeBook(id: number, bookId: number): Promise<ApiMessageResult> {
    const payload: RemoveBookPayload = { book_id: bookId };
    const raw = await TalebookCoreService.talebookPost(
      `/api/booklist/${id}/books/remove`, JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async getBookBooklists(bookId: number): Promise<BookBookListsResponse> {
    const raw = await TalebookCoreService.talebookGet(`/api/book/${bookId}/booklists`);
    return JSON.parse(raw) as BookBookListsResponse;
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
