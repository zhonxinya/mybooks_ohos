import { PageScaffold, FilterChipItem, LoadingState, EmptyState, ChipButton, LazyDataSource } from '../components';
import { TalebookService } from '../services/TalebookService';
import { TalebookApi, MetaNameCount } from '../services/TalebookApi';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { PaginationConstants } from '../utils/PaginationHelper';

interface MetaItem {
  name: string;
  count: number;
}

/**
 * 页面自有「可横向滚动」的类型胶囊。
 * 不用共享 FilterChips：它是固定 `Row`（不滚动），7 个胶囊在 1260px 设备上会溢出，
 * 末尾的「格式」「分类」被裁掉且点不到（实测）。ChipButton 的 label/selected 是 @Prop，
 * 因此用 Row + ChipButton 自建并加 Scroll。
 */
@Component
struct MetaTypeChips {
  @Prop labels: string[] = [];
  @Prop selected: number = 0;
  onPick?: (value: number) => void;

  build() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.labels, (label: string, index: number) => {
          ChipButton({
            label: label,
            selected: this.selected === index,
            onTap: () => {
              if (this.onPick) {
                this.onPick(index);
              }
            },
          });
        }, (label: string, index: number) => `meta-chip-${index}-${label}`);
      }
      .padding({ left: 16, right: 16, bottom: 8 });
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%');
  }
}

@Entry
@Component
struct MetaBookListPage {
  @State metaType: string = 'tag';
  @State selectedTab: number = 0;
  @State @Watch('onItemsChanged') items: MetaItem[] = [];
  @State pins: MetaItem[] = [];
  @State loading: boolean = true;
  @State errorMessage: string = '';
  /** 服务端返回的条目总数（MetaList 不支持 start/size，用它与已加载数比较判断是否截断）。 */
  @State total: number = 0;
  /** 是否请求 `show=all`（上游用该参数绕过热门度过滤，服务端支持）。 */
  @State showAll: boolean = false;
  private baseFilters: FilterChipItem[] = [
    { label: '标签', value: 0 },
    { label: '作者', value: 1 },
    { label: '丛书', value: 2 },
    { label: '出版社', value: 3 },
    { label: '评分', value: 4 },
    { label: ServerRegistry.resolveMetaType('language') === 'language' ? '语言' : '格式', value: 5 },
  ];
  /** 「分类」仅在服务端提供 /api/categories 时显示。 */
  private filterItems: FilterChipItem[] = ServerRegistry.supports(ServerFeature.CATEGORIES)
    ? this.baseFilters.concat([{ label: '分类', value: 6 }])
    : this.baseFilters;
  /** 末位元数据键按当前 ServerProfile 归一化（mybooks `language` ↔ talebook `format`）。 */
  private metaTypes: string[] = ['tag', 'author', 'series', 'publisher', 'rating',
    ServerRegistry.resolveMetaType('language'), 'category'];
  private scrollController: Scroller = new Scroller();
  private itemsSource: LazyDataSource<MetaItem> = new LazyDataSource<MetaItem>();

  /** items 变更后同步 LazyForEach 数据源，避免逐处手写 update。 */
  private onItemsChanged(): void {
    this.itemsSource.update(this.items);
  }

  aboutToAppear(): void {
    void this.loadMeta();
  }

  /** 作者/标签支持置顶（item_type 0=作者 1=标签）。 */
  private pinItemType(): number {
    return this.metaType === 'author' ? 0 : 1;
  }

  private canPin(): boolean {
    return ServerRegistry.supports(ServerFeature.USER_PIN) &&
      (this.metaType === 'author' || this.metaType === 'tag');
  }

  // ---- 类型元信息（标题/图标/展示形态，对齐上游 MetaList 的 titles 与网格布局） ----

  /** 当前元数据类型的标题（上游 `titles` 映射，含 mybooks 的 language 与自有的 category）。 */
  private typeTitle(): string {
    if (this.metaType === 'tag') {
      return '全部标签';
    }
    if (this.metaType === 'author') {
      return '全部作者';
    }
    if (this.metaType === 'series') {
      return '丛书列表';
    }
    if (this.metaType === 'publisher') {
      return '全部出版社';
    }
    if (this.metaType === 'rating') {
      return '全部评分';
    }
    if (this.metaType === 'category') {
      return '全部分类';
    }
    return this.metaType === 'language' ? '全部语言' : '全部格式';
  }

  private typeIcon(): Resource {
    if (this.metaType === 'author') {
      return $r('sys.symbol.person');
    }
    if (this.metaType === 'series') {
      return $r('sys.symbol.book');
    }
    if (this.metaType === 'publisher') {
      return $r('sys.symbol.folder');
    }
    if (this.metaType === 'rating') {
      return $r('sys.symbol.star_fill');
    }
    if (this.metaType === 'category') {
      return $r('sys.symbol.square_grid_2x2');
    }
    if (this.metaType === 'language' || this.metaType === 'format') {
      return $r('sys.symbol.doc_text');
    }
    return $r('sys.symbol.bookmark');
  }

  /** 短标签型（评分/格式/语言/分类）用胶囊网格，名称较长的用单行列表（都贴合上游形态）。 */
  private isGridType(): boolean {
    const type: string = this.metaType;
    return type === 'rating' || type === 'format' || type === 'language' || type === 'category';
  }

  /** 服务端返回的条目多于本次加载量（>300 时会做热门度截断）。 */
  private truncated(): boolean {
    return this.items.length < this.total;
  }

  /** 胶囊/行内的名称+计数文案（计数为 0 时不显示，对齐上游 `v-if="item.count"`）。 */
  private chipLabel(item: MetaItem): string {
    const name: string = this.metaType === 'rating' ? `${item.name} 星` : item.name;
    return item.count > 0 ? `${name} (${item.count})` : name;
  }

  private metaSubtitle(): string {
    const shown: number = this.items.length;
    if (this.total <= 0) {
      return '暂无数据';
    }
    if (shown >= this.total) {
      return `共 ${this.total} 项 · 已全部显示`;
    }
    return `已显示 ${shown} / ${this.total} 项 · 服务端按书籍数量截断`;
  }

  private async loadMeta(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.errorMessage = '请先配置 Talebook 服务器';
        return;
      }
      if (this.metaType === 'category') {
        if (!ServerRegistry.supports(ServerFeature.CATEGORIES)) {
          this.errorMessage = `${ServerRegistry.profile().displayName} 服务端不支持书籍分类`;
          return;
        }
        const categories: MetaItem[] = await TalebookApi.getCategories();
        this.items = categories;
        this.pins = [];
        this.total = categories.length;
        return;
      }
      if (TalebookService.hasAuthCredentials()) {
        await TalebookService.ensureAuthenticated();
      }
      // 上游 MetaList 不识别 start/size（始终返回全部并做热门度过滤），
      // 因此这里只请求一页、用 show=all 决定是否绕过过滤，不再做「加载更多」。
      const envelope = await TalebookService.getMetaListAsync(this.metaType, 1,
        PaginationConstants.PAGE_SIZE, this.showAll ? 'show=all' : '');
      if (!TalebookService.isApiSuccess(envelope)) {
        this.errorMessage = envelope.error.length > 0 ? envelope.error : '加载元数据失败';
        return;
      }
      const body = envelope.body ?? {};
      const fetched: MetaItem[] = this.parseMetaItems(
        (body['items'] as Record<string, Object>[] | undefined) ??
        (body['tags'] as Record<string, Object>[] | undefined));
      this.items = fetched;
      this.pins = this.parseMetaItems(body['pins'] as Record<string, Object>[] | undefined);
      this.total = Number(body['total'] ?? fetched.length);
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : `${error}`;
    } finally {
      this.loading = false;
    }
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

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openMeta(name: string): void {
    if (name.length === 0) {
      return;
    }
    if (this.metaType === 'category') {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/BookListPage',
        params: { type: 'category', metaName: name },
      });
    } else {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/BookListPage',
        params: { type: 'meta', metaType: this.metaType, metaName: name },
      });
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async togglePin(name: string, pinned: boolean): Promise<void> {
    // 置顶（pin/unpin）为 mybooks 专有端点；入口已按能力隐藏，这里兜底
    if (!ServerRegistry.supports(ServerFeature.USER_PIN)) {
      return;
    }
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
      await this.loadMeta();
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: `操作失败：${error}` });
    }
  }

  build() {
    Column() {
      PageScaffold({
        // 顶栏用中性标题：具体类型（全部标签/全部作者…）随页签变化，由内容区概览块呈现，
        // 而 PageScaffold.title 是普通成员，不随状态重绘（ArkUI 陷阱），不能用来放动态标题。
        title: '元数据',
        showBack: true,
        content: () => {
          this.metaContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  /** 概览头：类型标题 + 图标 + 总数 + 截断提示 + 显示全部（对齐上游 titles 与 show=all）。 */
  @Builder
  overviewBlock() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph(this.typeIcon())
          .fontSize(18)
          .fontColor([$r('app.color.brand_primary')]);
        Text(this.typeTitle())
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Text(`共 ${this.total} 项`)
          .fontSize(11)
          .fontColor($r('app.color.brand_primary'))
          .backgroundColor($r('app.color.card_background'))
          .borderRadius($r('app.float.badge_radius'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 });
      }
      .width('100%');

      Text(this.metaSubtitle())
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');

      if (this.canPin()) {
        Text('点列表右侧星标可置顶，已置顶项在最上方')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }

      // 服务端在条目过多时会按热门度截断，用 show=all 取全量（上游同款开关）
      if (this.truncated() || this.showAll) {
        ChipButton({
          label: this.showAll ? '恢复精简列表' : `显示全部 ${this.total} 项`,
          selected: this.showAll,
          onTap: () => {
            this.showAll = !this.showAll;
            void this.loadMeta();
          },
        });
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .backgroundColor($r('app.color.brand_primary_light'));
  }

  /** 已置顶区：星标 + 名称 + 计数，右侧 × 取消置顶（左侧与 × 各自独立点击，避免误触）。 */
  @Builder
  pinnedBlock() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.star_fill'))
          .fontSize(13)
          .fontColor([$r('app.color.warning')]);
        Text(`已置顶 ${this.pins.length} 项`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.warning'))
          .layoutWeight(1);
      }
      .width('100%');

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.pins, (pin: MetaItem) => {
          this.pinChip(pin);
        }, (pin: MetaItem) => `pin-${pin.name}`);
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .backgroundColor($r('app.color.warning_light'));
  }

  @Builder
  pinChip(item: MetaItem) {
    Row({ space: 4 }) {
      Row({ space: 4 }) {
        Text(item.name)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 200 });
        if (item.count > 0) {
          Text(`${item.count}`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'));
        }
      }
      .padding({ left: 10, top: 6, bottom: 6 })
      .onClick(() => this.openMeta(item.name));

      Text('×')
        .fontSize(14)
        .fontColor($r('app.color.warning'))
        .padding({ left: 4, right: 10, top: 4, bottom: 4 })
        .onClick(() => {
          void this.togglePin(item.name, true);
        });
    }
    .backgroundColor($r('app.color.card_background'))
    .borderRadius($r('app.float.chip_radius'))
    .margin({ right: 8, bottom: 8 });
  }

  /** 短标签型：胶囊网格（对齐上游 rating 的 4 列网格观感）。 */
  @Builder
  gridBlock() {
    Column({ space: 8 }) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.items, (item: MetaItem) => {
          ChipButton({
            label: this.chipLabel(item),
            onTap: () => this.openMeta(item.name),
          });
        }, (item: MetaItem) => `${item.name}-${item.count}`);
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'));
  }

  /** 长名称型：单行列表项（左区可点打开；星标单独置顶，避免与整行点击冲突）。 */
  @Builder
  itemRow(item: MetaItem) {
    Row({ space: 4 }) {
      Row({ space: 8 }) {
        Text(item.name)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        if (item.count > 0) {
          Text(`${item.count} 本`)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.page_background'))
            .borderRadius($r('app.float.badge_radius'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 });
        }
      }
      .layoutWeight(1)
      .onClick(() => this.openMeta(item.name));

      if (this.canPin()) {
        SymbolGlyph($r('sys.symbol.star'))
          .fontSize(18)
          .fontColor([$r('app.color.text_tertiary')])
          .padding({ left: 10, right: 6, top: 8, bottom: 8 })
          .onClick(() => {
            void this.togglePin(item.name, false);
          });
      }
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([$r('app.color.text_tertiary')]);
    }
    .width('100%')
    .padding($r('app.float.page_padding'))
    .backgroundColor(Color.Transparent)
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    });
  }

  @Builder
  metaContent() {
    Column() {
      MetaTypeChips({
        labels: this.filterItems.map((item: FilterChipItem): string => item.label),
        selected: this.selectedTab,
        onPick: (value: number) => {
          this.selectedTab = value;
          this.metaType = this.metaTypes[value];
          this.showAll = false;
          void this.loadMeta();
        },
      });
      if (this.loading) {
        LoadingState({});
      } else if (this.errorMessage.length > 0) {
        EmptyState({
          message: this.errorMessage,
          actionLabel: this.errorMessage.includes('配置') ? '去配置' : '',
          onAction: () => this.getUIContext().getRouter().pushUrl({ url: 'pages/TalebookConfigPage' }),
        });
      } else {
        // 卡片左右留白放在外层 Column 的 padding 上：
        // List 是 `width('100%')`，给它加 margin 会溢出而不是内缩（实测卡片会贴到屏幕边缘）。
        Column() {
          List({ scroller: this.scrollController }) {
            ListItem() {
              this.overviewBlock();
            }
            if (this.canPin() && this.pins.length > 0) {
              ListItem() {
                this.pinnedBlock();
              }
            }
            if (this.items.length === 0) {
              ListItem() {
                EmptyState({ message: '该分类下暂无数据' });
              }
            } else if (this.isGridType()) {
              ListItem() {
                this.gridBlock();
              }
            } else {
              LazyForEach(this.itemsSource, (item: MetaItem) => {
                ListItem() {
                  this.itemRow(item);
                }
              }, (item: MetaItem) => `${item.name}-${item.count}`);
            }
          }
          .layoutWeight(1)
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'))
          .clip(true)
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider') })
          .scrollBar(BarState.Off);
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 12 });
      }
    }
    .width('100%')
    .height('100%');
  }
}
