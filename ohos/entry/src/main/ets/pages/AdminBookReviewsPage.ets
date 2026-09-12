import { PageScaffold, LoadingState, EmptyState, FilterChips, FilterChipItem } from '../components';
import { TalebookApi, ApiMessageResult } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';
import { PaginationHelper } from '../utils/PaginationHelper';

interface StatusOption {
  label: string;
  value: number;
  key: string;
}

const STATUS_OPTIONS: StatusOption[] = [
  { label: '全部', value: 0, key: '' },
  { label: '待审核', value: 1, key: 'pending' },
  { label: '已通过', value: 2, key: 'approved' },
  { label: '已屏蔽', value: 3, key: 'hidden' },
];

const REVIEW_PAGE_SIZE: number = 20;

@Entry
@Component
struct AdminBookReviewsPage {
  @State reviews: Record<string, Object>[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State totalCount: number = 0;
  @State selectedStatus: number = 0;
  private lastLoadTime: number = 0;

  aboutToAppear(): void {
    void this.loadReviews(true);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private statusKey(value: number): string {
    for (let i = 0; i < STATUS_OPTIONS.length; i++) {
      if (STATUS_OPTIONS[i].value === value) {
        return STATUS_OPTIONS[i].key;
      }
    }
    return '';
  }

  private statusLabel(status: string): string {
    if (status === 'pending') {
      return '待审核';
    }
    if (status === 'hidden') {
      return '已屏蔽';
    }
    return '已通过';
  }

  private statusColor(status: string): ResourceColor {
    if (status === 'pending') {
      return $r('app.color.error');
    }
    if (status === 'hidden') {
      return $r('app.color.text_tertiary');
    }
    return $r('app.color.on_brand');
  }

  private async loadReviews(reset: boolean = true): Promise<void> {
    if (reset) {
      this.currentPage = 1;
      this.hasMore = true;
      this.reviews = [];
      this.loading = true;
    } else {
      this.loadingMore = true;
    }
    const page = this.currentPage;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.getAdminReviews(this.statusKey(this.selectedStatus), page,
        REVIEW_PAGE_SIZE);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        if (!reset) {
          this.currentPage = Math.max(1, this.currentPage - 1);
        }
        return;
      }
      const fetched = rsp.reviews ?? [];
      this.reviews = reset ? fetched : this.reviews.concat(fetched);
      this.totalCount = rsp.total !== undefined ? rsp.total : this.reviews.length;
      this.hasMore = PaginationHelper.computeHasMore(fetched.length, REVIEW_PAGE_SIZE);
    } catch (e) {
      this.toast(`加载失败：${e}`);
      if (!reset) {
        this.currentPage = Math.max(1, this.currentPage - 1);
      }
    } finally {
      this.loading = false;
      this.loadingMore = false;
      this.lastLoadTime = Date.now();
    }
  }

  private loadMore(): void {
    if (Date.now() - this.lastLoadTime < 500 || this.loadingMore || !this.hasMore) {
      return;
    }
    this.currentPage += 1;
    void this.loadReviews(false);
  }

  private onStatusChange(value: number): void {
    this.selectedStatus = value;
    void this.loadReviews(true);
  }

  private doModerate(review: Record<string, Object>, action: string): void {
    TalebookApi.moderateAdminReview(Number(review['id'] ?? 0), action)
      .then((rsp: ApiMessageResult) => {
        if (rsp.err === undefined || rsp.err === 'ok') {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '操作成功');
          void this.loadReviews(true);
        } else {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        }
      })
      .catch((e: Object) => this.toast(`操作失败：${e}`));
  }

  private showReviewActions(review: Record<string, Object>): void {
    const status = String(review['status'] ?? 'approved');
    if (status === 'pending') {
      this.getUIContext().getPromptAction().showActionMenu({
        title: String(review['book_title'] ?? ''),
        buttons: [
          { text: '通过', color: '#007DFF' },
          { text: '屏蔽', color: '#E84026' },
        ],
      }).then((result) => {
        if (result.index === 0) {
          this.doModerate(review, 'approve');
        } else if (result.index === 1) {
          this.doModerate(review, 'hide');
        }
      }).catch(() => {});
    } else if (status === 'approved') {
      this.getUIContext().getPromptAction().showActionMenu({
        title: String(review['book_title'] ?? ''),
        buttons: [{ text: '屏蔽', color: '#E84026' }],
      }).then((result) => {
        if (result.index === 0) {
          this.doModerate(review, 'hide');
        }
      }).catch(() => {});
    } else {
      this.getUIContext().getPromptAction().showActionMenu({
        title: String(review['book_title'] ?? ''),
        buttons: [{ text: '恢复显示', color: '#007DFF' }],
      }).then((result) => {
        if (result.index === 0) {
          this.doModerate(review, 'restore');
        }
      }).catch(() => {});
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '评论审核',
        showBack: true,
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  pageContent() {
    Column() {
      FilterChips({
        items: STATUS_OPTIONS.map((option: StatusOption): FilterChipItem => {
          return { label: option.label, value: option.value };
        }),
        selected: $selectedStatus,
        onChange: (value: number) => this.onStatusChange(value),
      });
      if (this.loading) {
        LoadingState({});
      } else if (this.reviews.length === 0) {
        EmptyState({ message: '暂无评论' });
      } else {
        List({ space: 8 }) {
          ForEach(this.reviews, (review: Record<string, Object>) => {
            ListItem() {
              this.reviewRow(review);
            }
          }, (review: Record<string, Object>) => `review-${Number(review['id'] ?? 0)}`);
          if (this.loadingMore) {
            ListItem() {
              LoadingState({ hint: '加载更多...' });
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .onReachEnd(() => this.loadMore());
      }
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  reviewRow(review: Record<string, Object>) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(String(review['book_title'] ?? ''))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Text(this.statusLabel(String(review['status'] ?? '')))
          .fontSize(11)
          .fontColor(this.statusColor(String(review['status'] ?? '')))
          .backgroundColor($r('app.color.page_background'))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 });
      }
      .width('100%');

      Row({ space: 8 }) {
        Text(`${String(review['username'] ?? '')} · ★${Number(review['rating'] ?? 0)}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
        Blank().layoutWeight(1);
        Text(String(review['update_time'] ?? ''))
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'));
      }
      .width('100%');

      Text(String(review['comment'] ?? ''))
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => this.showReviewActions(review));
  }
}
