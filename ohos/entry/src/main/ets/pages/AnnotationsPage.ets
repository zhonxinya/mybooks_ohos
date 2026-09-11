import { router } from '@kit.ArkUI';
import {
  PageScaffold, LoadingState, EmptyState, SearchBar, FilterChips, FilterChipItem,
  TextButton, SectionTitle,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import {
  AnnotationApi, AnnotationItem,
  ANNOTATION_TYPE_HIGHLIGHT, ANNOTATION_TYPE_NOTE, ANNOTATION_TYPE_BOOKMARK,
  ANNOTATION_TYPE_CHAPTER_COMMENT, annotationTypeLabel,
} from '../services/AnnotationApi';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';

const TYPE_ALL: number = 0;

/**
 * 我的全部标注（GET /api/annotations）。
 *
 * 上游非 ListHandler 系、不识别 start/size，一次性返回全量，
 * 因此这里按项目分页约定在本地逐页展开（PaginationHelper 负责阈值与防抖）。
 */
@Entry
@Component
struct AnnotationsPage {
  @State supported: boolean = true;
  @State loading: boolean = true;
  @State loadError: string = '';
  @State allItems: AnnotationItem[] = [];
  @State rows: AnnotationItem[] = [];
  @State hasMore: boolean = false;
  @State visibleCount: number = PaginationConstants.PAGE_SIZE;
  @State @Watch('onKeywordChanged') keyword: string = '';
  @State typeFilter: number = TYPE_ALL;
  @State exporting: boolean = false;
  @State exportText: string = '';
  @State exportMeta: string = '';
  private lastLoadTime: number = 0;
  private filterItems: FilterChipItem[] = [
    { label: '全部', value: 0 },
    { label: '高亮', value: 1 },
    { label: '笔记', value: 2 },
    { label: '书签', value: 3 },
    { label: '章节批注', value: 4 },
  ];

  aboutToAppear(): void {
    this.supported = ServerRegistry.supports(ServerFeature.ANNOTATIONS);
    if (!this.supported) {
      this.loading = false;
      return;
    }
    void this.load();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.loadError = '尚未配置书库地址';
        return;
      }
      await TalebookService.ensureAuthenticated();
      this.allItems = await AnnotationApi.listMyAnnotations();
      this.visibleCount = PaginationConstants.PAGE_SIZE;
      this.applyFilter();
    } catch (error) {
      this.loadError = error instanceof Error ? error.message : `${error}`;
    } finally {
      this.loading = false;
      this.lastLoadTime = Date.now();
    }
  }

  private onKeywordChanged(): void {
    this.visibleCount = PaginationConstants.PAGE_SIZE;
    this.applyFilter();
  }

  private onTypeChanged(): void {
    this.visibleCount = PaginationConstants.PAGE_SIZE;
    this.applyFilter();
  }

  private filterTypeOf(value: number): string {
    switch (value) {
      case 1:
        return ANNOTATION_TYPE_HIGHLIGHT;
      case 2:
        return ANNOTATION_TYPE_NOTE;
      case 3:
        return ANNOTATION_TYPE_BOOKMARK;
      case 4:
        return ANNOTATION_TYPE_CHAPTER_COMMENT;
      default:
        return '';
    }
  }

  private matchesKeyword(item: AnnotationItem, keyword: string): boolean {
    const fields: string[] = [
      item.quoteText, item.content, item.chapter, item.authorName, `${item.bookId}`,
    ];
    for (let index = 0; index < fields.length; index++) {
      if (fields[index].toLowerCase().indexOf(keyword) >= 0) {
        return true;
      }
    }
    return false;
  }

  private filteredItems(): AnnotationItem[] {
    const type = this.filterTypeOf(this.typeFilter);
    const keyword = this.keyword.trim().toLowerCase();
    const result: AnnotationItem[] = [];
    for (let index = 0; index < this.allItems.length; index++) {
      const item = this.allItems[index];
      if (type.length > 0 && item.annotationType !== type) {
        continue;
      }
      if (keyword.length > 0 && !this.matchesKeyword(item, keyword)) {
        continue;
      }
      result.push(item);
    }
    return result;
  }

  /** 本地分页：按当前筛选结果截取已展开的窗口。 */
  private applyFilter(): void {
    const filtered = this.filteredItems();
    const count = this.visibleCount > filtered.length ? filtered.length : this.visibleCount;
    this.rows = filtered.slice(0, count);
    this.hasMore = filtered.length > this.rows.length;
  }

  private loadMore(): void {
    if (!PaginationHelper.canLoadMore(this.lastLoadTime, false, this.hasMore)) {
      return;
    }
    this.visibleCount += PaginationConstants.PAGE_SIZE;
    this.applyFilter();
    this.lastLoadTime = Date.now();
  }

  private async doExport(): Promise<void> {
    if (this.exporting) {
      return;
    }
    this.exporting = true;
    try {
      const result = await AnnotationApi.exportAnnotations();
      this.exportText = result.json;
      this.exportMeta = `${result.count} 条 · ${result.schema} · ${result.exportedAt}`;
      this.toast(`已导出 ${result.count} 条标注`);
    } catch (error) {
      this.toast(`导出失败：${error instanceof Error ? error.message : error}`);
    } finally {
      this.exporting = false;
    }
  }

  private openBook(item: AnnotationItem): void {
    router.pushUrl({
      url: 'pages/BookAnnotationsPage',
      params: { bookId: item.bookId },
    });
  }

  private rowSubtitle(item: AnnotationItem): string {
    const parts: string[] = [];
    if (item.chapter.length > 0) {
      parts.push(item.chapter);
    }
    if (item.authorName.length > 0) {
      parts.push(item.authorName);
    }
    parts.push(this.formatTime(item.updatedAt.length > 0 ? item.updatedAt : item.createdAt));
    return parts.join(' · ');
  }

  /** 上游时间戳为 ISO 字符串（如 2026-09-12T08:30:00），这里截到分钟并去掉 T。 */
  private formatTime(value: string): string {
    if (value.length < 16) {
      return value;
    }
    return value.slice(0, 16).replace('T', ' ');
  }

  build() {
    Column() {
      PageScaffold({
        title: '我的标注',
        showBack: true,
        action: () => {
          this.actionArea();
        },
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  actionArea() {
    TextButton({
      label: this.exporting ? '导出中…' : '导出',
      onTap: () => {
        void this.doExport();
      },
    });
  }

  @Builder
  pageContent() {
    if (!this.supported) {
      EmptyState({ message: `${ServerRegistry.profile().displayName} 服务端不支持标注` });
    } else if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({
        message: this.loadError,
        actionLabel: '重试',
        onAction: () => {
          void this.load();
        },
      });
    } else {
      Column() {
        SearchBar({
          placeholder: '搜索引文、笔记、章节',
          keyword: $keyword,
          onSearch: () => this.applyFilter(),
        });
        FilterChips({
          items: this.filterItems,
          selected: $typeFilter,
          onChange: () => this.onTypeChanged(),
        });
        Text(`共 ${this.allItems.length} 条，已显示 ${this.rows.length} 条`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 });
        if (this.exportText.length > 0) {
          this.exportPanel();
        }
        if (this.rows.length === 0) {
          EmptyState({ message: this.allItems.length === 0 ? '暂无标注' : '没有匹配的标注' });
        } else {
          List({ space: 8 }) {
            ForEach(this.rows, (item: AnnotationItem) => {
              ListItem() {
                this.annotationRow(item);
              }
            }, (item: AnnotationItem) => `annotation-${item.id}`);
            if (this.hasMore) {
              ListItem() {
                Text('上滑加载更多')
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 8, bottom: 8 });
              }
            }
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 12, right: 12 })
          .onReachEnd(() => this.loadMore());
        }
      }
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  exportPanel() {
    Column({ space: 6 }) {
      SectionTitle({
        title: '导出结果',
        actionLabel: '收起',
        onAction: () => {
          this.exportText = '';
          this.exportMeta = '';
        },
      });
      Text(this.exportMeta)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ left: 16, right: 16 });
      Scroll() {
        Text(this.exportText)
          .fontSize(11)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
      }
      .height(140)
      .width('100%')
      .padding({ left: 16, right: 16 })
      .backgroundColor($r('app.color.card_background'))
      .borderRadius($r('app.float.card_radius'));
    }
    .width('100%')
    .padding({ bottom: 8 });
  }

  @Builder
  annotationRow(item: AnnotationItem) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(annotationTypeLabel(item.annotationType))
          .fontSize(11)
          .fontColor($r('app.color.brand_primary'))
          .backgroundColor($r('app.color.brand_primary_light'))
          .borderRadius(8)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 });
        Text(`书籍 #${item.bookId}`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1);
        if (item.isPrivate) {
          Text('私有')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'));
        }
      }
      .width('100%');

      if (item.quoteText.length > 0) {
        Text(item.quoteText)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
      if (item.content.length > 0) {
        Text(item.content)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
      Text(this.rowSubtitle(item))
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.card_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .onClick(() => this.openBook(item));
  }
}
