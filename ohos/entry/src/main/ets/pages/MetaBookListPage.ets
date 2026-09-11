import { router } from '@kit.ArkUI';
import { PageScaffold, FilterChips, FilterChipItem, SettingCell, LoadingState, EmptyState, ChipButton, LazyDataSource } from '../components';
import { TalebookService } from '../services/TalebookService';
import { TalebookApi, MetaNameCount } from '../services/TalebookApi';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';

interface MetaItem {
  name: string;
  count: number;
}

@Entry
@Component
struct MetaBookListPage {
  @State metaType: string = 'tag';
  @State selectedTab: number = 0;
  @State @Watch('onItemsChanged') items: MetaItem[] = [];
  @State pins: MetaItem[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State errorMessage: string = '';
  private filterItems: FilterChipItem[] = [
    { label: '标签', value: 0 },
    { label: '作者', value: 1 },
    { label: '丛书', value: 2 },
    { label: '出版社', value: 3 },
    { label: '评分', value: 4 },
    { label: '语言', value: 5 },
    { label: '分类', value: 6 },
  ];
  private metaTypes: string[] = ['tag', 'author', 'series', 'publisher', 'rating', 'language', 'category'];
  private scrollController: Scroller = new Scroller();
  private lastLoadTime: number = 0;
  private itemsSource: LazyDataSource<MetaItem> = new LazyDataSource<MetaItem>();

  /** items 变更后同步 LazyForEach 数据源，避免逐处手写 update。 */
  private onItemsChanged(): void {
    this.itemsSource.update(this.items);
  }

  aboutToAppear(): void {
    void this.loadMeta(true);
  }

  /** 作者/标签支持置顶（item_type 0=作者 1=标签）。 */
  private pinItemType(): number {
    return this.metaType === 'author' ? 0 : 1;
  }

  private canPin(): boolean {
    return this.metaType === 'author' || this.metaType === 'tag';
  }

  private parseMetaItems(list: Record<string, Object>[] | undefined): MetaItem[] {
    const result: MetaItem[] = [];
    if (list === undefined) {
      return result;
    }
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      const name = String(item['name'] ?? item['title'] ?? '');
      if (name.length > 0) {
        result.push({ name: name, count: Number(item['count'] ?? 0) });
      }
    }
    return result;
  }

  private async loadMeta(reset: boolean = true): Promise<void> {
    if (reset) {
      this.currentPage = 1;
      this.hasMore = true;
      this.items = [];
      this.pins = [];
      this.loading = true;
      this.errorMessage = '';
    } else {
      this.loadingMore = true;
    }
    const page = this.currentPage;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.errorMessage = '请先配置 Talebook 服务器';
        return;
      }
      let fetched: MetaItem[] = [];
      if (this.metaType === 'category') {
        fetched = await TalebookApi.getCategories();
      } else {
        if (TalebookService.hasAuthCredentials()) {
          await TalebookService.ensureAuthenticated();
        }
        const envelope = await TalebookService.getMetaListAsync(this.metaType, page,
          PaginationConstants.PAGE_SIZE);
        if (!TalebookService.isApiSuccess(envelope)) {
          if (reset) {
            this.errorMessage = envelope.error.length > 0 ? envelope.error : '加载分类失败';
          } else {
            this.getUIContext().getPromptAction().showToast({
              message: envelope.error.length > 0 ? envelope.error : '加载更多失败',
            });
            this.currentPage = Math.max(1, this.currentPage - 1);
          }
          return;
        }
        const body = envelope.body ?? {};
        fetched = this.parseMetaItems((body['items'] as Record<string, Object>[] | undefined) ??
          (body['tags'] as Record<string, Object>[] | undefined));
        this.pins = this.parseMetaItems(body['pins'] as Record<string, Object>[] | undefined);
      }
      if (reset) {
        this.items = fetched;
      } else {
        this.items = this.items.concat(fetched);
      }
      this.hasMore = this.metaType === 'category' ?
        false : PaginationHelper.computeHasMore(fetched.length);
    } catch (error) {
      if (reset) {
        this.errorMessage = error instanceof Error ? error.message : `${error}`;
      }
    } finally {
      this.loading = false;
      this.loadingMore = false;
      this.lastLoadTime = Date.now();
    }
  }

  private loadMore(): void {
    if (!PaginationHelper.canLoadMore(this.lastLoadTime, this.loadingMore, this.hasMore)) {
      return;
    }
    this.currentPage += 1;
    void this.loadMeta(false);
  }

  private openMeta(name: string): void {
    if (name.length === 0) {
      return;
    }
    if (this.metaType === 'category') {
      router.pushUrl({
        url: 'pages/BookListPage',
        params: { type: 'category', metaName: name },
      });
    } else {
      router.pushUrl({
        url: 'pages/BookListPage',
        params: { type: 'meta', metaType: this.metaType, metaName: name },
      });
    }
  }

  private async togglePin(name: string, pinned: boolean): Promise<void> {
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = pinned ? await TalebookApi.unpinItem(this.pinItemType(), name) :
        await TalebookApi.pinItem(this.pinItemType(), name);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.getUIContext().getPromptAction().showToast({
          message: rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err,
        });
        return;
      }
      this.getUIContext().getPromptAction().showToast({
        message: pinned ? '已取消置顶' : '置顶成功',
      });
      await this.loadMeta(true);
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: `操作失败：${error}` });
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '分类',
        showBack: true,
        content: () => {
          this.metaContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  pinChip(item: MetaItem) {
    Stack({ alignContent: Alignment.TopEnd }) {
      ChipButton({
        label: `${item.name} (${item.count})`,
        onTap: () => this.openMeta(item.name),
      });
      Text('×')
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .padding({ left: 4, right: 4, top: 2, bottom: 2 })
        .onClick(() => {
          void this.togglePin(item.name, true);
        });
    }
    .margin({ right: 8, bottom: 8 });
  }

  @Builder
  metaContent() {
    Column() {
      FilterChips({
        items: this.filterItems,
        selected: $selectedTab,
        onChange: (value: number) => {
          this.metaType = this.metaTypes[value];
          void this.loadMeta(true);
        },
      });
      if (this.loading) {
        LoadingState({});
      } else if (this.errorMessage.length > 0) {
        EmptyState({
          message: this.errorMessage,
          actionLabel: this.errorMessage.includes('配置') ? '去配置' : '',
          onAction: () => router.pushUrl({ url: 'pages/TalebookConfigPage' }),
        });
      } else if (this.items.length === 0 && this.pins.length === 0) {
        EmptyState({ message: '暂无分类数据' });
      } else {
        List({ scroller: this.scrollController }) {
          if (this.canPin() && this.pins.length > 0) {
            ListItem() {
              Column({ space: 8 }) {
                Text('已置顶')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'));
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.pins, (pin: MetaItem) => {
                    this.pinChip(pin);
                  }, (pin: MetaItem) => `pin-${pin.name}`);
                }
                .width('100%');
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding({ top: 8, bottom: 8 });
            }
          }
          LazyForEach(this.itemsSource, (item: MetaItem) => {
            ListItem() {
              SettingCell({
                title: item.name,
                subtitle: `${item.count} 本`,
                showChevron: true,
                onTap: () => this.openMeta(item.name),
              })
                .gesture(LongPressGesture()
                  .onAction(() => {
                    if (this.canPin()) {
                      void this.togglePin(item.name, false);
                    }
                  }));
            }
          }, (item: MetaItem) => `${item.name}-${item.count}`);
          if (this.loadingMore) {
            ListItem() {
              LoadingState({ hint: '加载更多...' });
            }
          }
        }
        .layoutWeight(1)
        .divider({ strokeWidth: 0.5, color: $r('app.color.divider') })
        .onReachEnd(() => this.loadMore());
        if (this.canPin()) {
          Text('长按列表项可置顶作者/标签')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 6, bottom: 10 });
        }
      }
    }
    .width('100%')
    .height('100%');
  }
}
