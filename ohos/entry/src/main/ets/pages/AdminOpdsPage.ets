import { PageScaffold, LoadingState, EmptyState, FilterChips, FilterChipItem,
  PrimaryButton, SecondaryButton, SectionTitle, SettingCell, TextButton } from '../components';
import {
  AdminOpdsApi, AdminOpdsSource, AdminOpdsBrowseItem, AdminOpdsFailedItem,
  AdminOpdsImportCounts, AdminOpdsImportBook,
} from '../services/AdminOpdsApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';

/** OPDS 导入进度轮询：3 秒一次，最多约 5 分钟。 */
const OPDS_POLL_INTERVAL_MS: number = 3000;
const OPDS_POLL_MAX_TICKS: number = 100;

@Entry
@Component
struct AdminOpdsPage {
  @State private supported: boolean = true;
  @State private view: number = 0;
  @State private loading: boolean = true;
  @State private loadError: string = '';
  @State private sources: AdminOpdsSource[] = [];
  @State private browseUrl: string = '';
  @State private currentPath: string = '';
  @State private browseItems: AdminOpdsBrowseItem[] = [];
  @State private selectedHrefs: string[] = [];
  @State private importBooksUrl: string = '';
  @State private importCounts: AdminOpdsImportCounts = {};
  @State private failedItems: AdminOpdsFailedItem[] = [];
  @State private deleteAfter: boolean = false;
  @State private working: boolean = false;
  @State private statusLine: string = '';
  @State private failedLoaded: boolean = false;
  private pollTimer: number = -1;
  private pollTicks: number = 0;

  aboutToAppear(): void {
    this.supported = ServerRegistry.supports(ServerFeature.ADMIN_OPDS);
    if (this.supported) {
      void this.loadSources();
      void this.refreshImportStatus(false);
    } else {
      this.loading = false;
    }
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private messageOf(err: string | undefined, msg: string | undefined, fallback: string): string {
    if (msg !== undefined && msg.length > 0) {
      return msg;
    }
    if (err !== undefined && err !== 'ok') {
      return err;
    }
    return fallback;
  }

  // ---- 轮询 ----

  private stopPoll(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private startPoll(): void {
    this.stopPoll();
    this.pollTicks = 0;
    this.schedulePoll();
  }

  private schedulePoll(): void {
    this.stopPoll();
    if (this.pollTicks >= OPDS_POLL_MAX_TICKS) {
      this.statusLine = '导入任务仍在进行，已停止自动刷新';
      return;
    }
    this.pollTimer = setTimeout(() => {
      this.pollTicks += 1;
      void this.refreshImportStatus(true);
    }, OPDS_POLL_INTERVAL_MS);
  }

  private isImportActive(): boolean {
    const total: number = this.importCounts.total !== undefined ? this.importCounts.total : 0;
    const finished: number = (this.importCounts.done ?? 0)
      + (this.importCounts.skip ?? 0) + (this.importCounts.fail ?? 0);
    return total > 0 && finished < total;
  }

  private async refreshImportStatus(continuePoll: boolean): Promise<void> {
    try {
      const rsp = await AdminOpdsApi.getImportStatus();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.statusLine = this.messageOf(rsp.err, rsp.msg, '进度读取失败');
        this.stopPoll();
        return;
      }
      this.importCounts = rsp.status ?? {};
      const active: boolean = this.isImportActive();
      this.statusLine = active
        ? `导入中：完成 ${this.importCounts.done ?? 0} · 跳过 ${this.importCounts.skip ?? 0}`
          + ` · 失败 ${this.importCounts.fail ?? 0} / 共 ${this.importCounts.total ?? 0}`
        : '';
      if (active) {
        if (continuePoll) {
          this.schedulePoll();
        }
      } else {
        this.stopPoll();
        if (continuePoll) {
          void this.loadFailed();
        }
      }
    } catch (e) {
      this.statusLine = `进度读取失败：${e}`;
      this.stopPoll();
    }
  }

  // ---- 数据 ----

  private async loadSources(): Promise<void> {
    this.loading = this.sources.length === 0;
    this.loadError = '';
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await AdminOpdsApi.listSources();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.loadError = this.messageOf(rsp.err, rsp.msg, 'OPDS 源加载失败');
        return;
      }
      this.sources = rsp.items ?? [];
    } catch (e) {
      this.loadError = `OPDS 源加载失败：${e}`;
    } finally {
      this.loading = false;
    }
  }

  private async loadFailed(): Promise<void> {
    try {
      const rsp = await AdminOpdsApi.listFailed();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(this.messageOf(rsp.err, rsp.msg, '失败记录加载失败'));
        return;
      }
      this.failedItems = rsp.items ?? [];
      this.failedLoaded = true;
    } catch (e) {
      this.toast(`失败记录加载失败：${e}`);
    }
  }

  private async browse(url: string): Promise<void> {
    if (url.length === 0) {
      this.toast('请填写或选择 OPDS 地址');
      return;
    }
    if (this.working) {
      return;
    }
    this.working = true;
    try {
      const rsp = await AdminOpdsApi.browse(url);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(this.messageOf(rsp.err, rsp.msg, '浏览失败'));
        return;
      }
      this.browseUrl = url;
      this.currentPath = rsp.current_path !== undefined ? rsp.current_path : url;
      this.browseItems = rsp.items ?? [];
      this.selectedHrefs = [];
    } catch (e) {
      this.toast(`浏览失败：${e}`);
    } finally {
      this.working = false;
    }
  }

  // ---- 浏览项 ----

  private isFolder(item: AdminOpdsBrowseItem): boolean {
    return item.type === 'folder';
  }

  private itemTitle(item: AdminOpdsBrowseItem): string {
    const title: string = item.title !== undefined && item.title.length > 0 ? item.title : '未命名';
    return this.isFolder(item) ? `📁 ${title}` : title;
  }

  private itemSubtitle(item: AdminOpdsBrowseItem): string {
    const author: string = item.author !== undefined ? item.author : '';
    const href: string = item.href !== undefined ? item.href : '';
    return `${author}${author.length > 0 ? ' · ' : ''}${href}`;
  }

  private isSelected(item: AdminOpdsBrowseItem): boolean {
    const href: string = item.href !== undefined ? item.href : '';
    return href.length > 0 && this.selectedHrefs.indexOf(href) >= 0;
  }

  private toggleSelect(item: AdminOpdsBrowseItem): void {
    const href: string = item.href !== undefined ? item.href : '';
    if (href.length === 0) {
      return;
    }
    const index: number = this.selectedHrefs.indexOf(href);
    if (index >= 0) {
      const next: string[] = this.selectedHrefs.slice();
      next.splice(index, 1);
      this.selectedHrefs = next;
    } else {
      this.selectedHrefs = this.selectedHrefs.concat([href]);
    }
  }

  private onBrowseItemTap(item: AdminOpdsBrowseItem): void {
    if (this.isFolder(item)) {
      const href: string = item.href !== undefined ? item.href : '';
      void this.browse(href);
    } else {
      this.toggleSelect(item);
    }
  }

  private selectedBooks(): AdminOpdsImportBook[] {
    const books: AdminOpdsImportBook[] = [];
    for (let i = 0; i < this.browseItems.length; i++) {
      const item: AdminOpdsBrowseItem = this.browseItems[i];
      if (!this.isSelected(item)) {
        continue;
      }
      const href: string = item.href !== undefined ? item.href : '';
      const book: AdminOpdsImportBook = {
        title: item.title !== undefined ? item.title : '',
        author: item.author !== undefined ? item.author : '',
        href: href,
        acquisition_link: href,
      };
      books.push(book);
    }
    return books;
  }

  private confirmImport(onlySelected: boolean): void {
    const count: number = this.selectedBooks().length;
    if (onlySelected && count === 0) {
      this.toast('请先选择要导入的书籍');
      return;
    }
    this.getUIContext().showAlertDialog({
      title: 'OPDS 导入',
      message: onlySelected
        ? `将异步导入选中的 ${count} 本书籍，继续？`
        : '将异步导入该 OPDS 目录下的全部书籍，继续？',
      primaryButton: {
        value: '导入',
        action: () => {
          this.startImport(onlySelected);
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private startImport(onlySelected: boolean): void {
    const url: string = this.browseUrl.length > 0 ? this.browseUrl : this.currentPath;
    if (url.length === 0 || this.working) {
      return;
    }
    this.working = true;
    const books: AdminOpdsImportBook[] = onlySelected ? this.selectedBooks() : [];
    AdminOpdsApi.importBooks(url, books, this.deleteAfter).then((rsp) => {
      this.working = false;
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.toast(this.messageOf(rsp.err, rsp.msg, '已开始导入'));
        this.importBooksUrl = url;
        this.startPoll();
      } else {
        this.toast(this.messageOf(rsp.err, rsp.msg, '导入失败'));
      }
    }).catch((e: Object) => {
      this.working = false;
      this.toast(`导入失败：${e}`);
    });
  }

  private retryFailed(item: AdminOpdsFailedItem): void {
    if (this.working) {
      return;
    }
    this.working = true;
    const hash: string = item.hash !== undefined ? item.hash : '';
    const id: number = item.id !== undefined ? item.id : 0;
    const request = id > 0 ? AdminOpdsApi.retryFailedById(id) : AdminOpdsApi.retryFailedByHash(hash);
    request.then((rsp) => {
      this.working = false;
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.toast(this.messageOf(rsp.err, rsp.msg, '已开始重试'));
        void this.loadFailed();
      } else {
        this.toast(this.messageOf(rsp.err, rsp.msg, '重试失败'));
      }
    }).catch((e: Object) => {
      this.working = false;
      this.toast(`重试失败：${e}`);
    });
  }

  private failedError(item: AdminOpdsFailedItem): string {
    if (item.error === undefined) {
      return '';
    }
    return JSON.stringify(item.error);
  }

  private sourceSubtitle(source: AdminOpdsSource): string {
    const url: string = source.url !== undefined ? source.url : '';
    const description: string = source.description !== undefined ? source.description : '';
    return `${url}${description.length > 0 ? `\n${description}` : ''}`;
  }

  build() {
    Column() {
      PageScaffold({
        title: 'OPDS 源',
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
    if (!this.supported) {
      EmptyState({ message: '当前服务端不支持 OPDS 管理（需要 Talebook）' });
    } else if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({ message: this.loadError, actionLabel: '重试', onAction: () => { void this.loadSources(); } });
    } else {
      Column() {
        FilterChips({
          items: [
            { label: '浏览与导入', value: 0 },
            { label: '失败记录', value: 1 },
          ] as FilterChipItem[],
          selected: $view,
          onChange: (value: number) => {
            this.view = value;
            if (value === 1) {
              void this.loadFailed();
            }
          },
        });
        if (this.view === 1) {
          this.failedView();
        } else {
          Scroll() {
            Column({ space: 8 }) {
              this.browseHeader();
              this.sourcesSection();
              this.browseResultSection();
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 24 });
          }
          .layoutWeight(1)
          .width('100%')
          .align(Alignment.Top);
        }
      }
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  browseHeader() {
    Column({ space: 8 }) {
      TextInput({ placeholder: 'OPDS 地址（http:// 或 https:// 开头）', text: this.browseUrl })
        .height($r('app.float.button_height_compact'))
        .onChange((value: string) => {
          this.browseUrl = value;
        });
      Row({ space: 12 }) {
        PrimaryButton({
          label: this.working ? '处理中…' : '浏览目录',
          buttonEnabled: !this.working,
          fullWidth: false,
          onTap: () => {
            void this.browse(this.browseUrl);
          },
        }).layoutWeight(1);
        SecondaryButton({
          label: '返回根目录',
          fullWidth: false,
          compact: true,
          onTap: () => {
            void this.browse(this.browseUrl);
          },
        }).layoutWeight(1);
      }
      .width('100%');
      if (this.currentPath.length > 0) {
        Text(`当前：${this.currentPath}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
      if (this.statusLine.length > 0) {
        Text(this.statusLine)
          .fontSize(12)
          .fontColor($r('app.color.brand_primary'))
          .width('100%');
      }
      if (this.importBooksUrl.length > 0) {
        Text(`最近导入源：${this.importBooksUrl}`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
      SettingCell({
        title: '导入后删除下载的临时文件',
        showToggle: true,
        toggleOn: this.deleteAfter,
        onToggle: (value: boolean) => {
          this.deleteAfter = value;
        },
      });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  sourcesSection() {
    SectionTitle({ title: `已保存的 OPDS 源（${this.sources.length}）`, actionLabel: '刷新',
      onAction: () => { void this.loadSources(); } });
    if (this.sources.length === 0) {
      Text('暂无已保存的源，可直接在上方输入 OPDS 地址浏览。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
    } else {
      Column() {
        ForEach(this.sources, (source: AdminOpdsSource) => {
          this.sourceRow(source);
          Divider().color($r('app.color.divider')).strokeWidth(0.5);
        }, (source: AdminOpdsSource) => `opds-src-${source.id ?? 0}`);
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));
    }
  }

  @Builder
  sourceRow(source: AdminOpdsSource) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(source.name !== undefined ? source.name : '未命名源')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        Text(source.active === true ? '启用' : '停用')
          .fontSize(11)
          .fontColor(source.active === true ? $r('app.color.success') : $r('app.color.text_tertiary'));
      }
      .width('100%');
      Text(this.sourceSubtitle(source))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => {
      void this.browse(source.url !== undefined ? source.url : '');
    });
  }

  @Builder
  browseResultSection() {
    SectionTitle({ title: `目录内容（已选 ${this.selectedHrefs.length}）` });
    Row({ space: 12 }) {
      PrimaryButton({
        label: '导入选中',
        buttonEnabled: !this.working,
        fullWidth: false,
        onTap: () => this.confirmImport(true),
      }).layoutWeight(1);
      PrimaryButton({
        label: '导入全部',
        buttonEnabled: !this.working,
        fullWidth: false,
        onTap: () => this.confirmImport(false),
      }).layoutWeight(1);
    }
    .width('100%');
    if (this.browseItems.length === 0) {
      Text('尚未浏览，或该目录没有条目。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
    } else {
      Column() {
        ForEach(this.browseItems, (item: AdminOpdsBrowseItem) => {
          this.browseRow(item);
          Divider().color($r('app.color.divider')).strokeWidth(0.5);
        }, (item: AdminOpdsBrowseItem) => `opds-item-${item.id ?? item.href ?? ''}`);
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));
    }
  }

  @Builder
  browseRow(item: AdminOpdsBrowseItem) {
    Row({ space: 12 }) {
      if (!this.isFolder(item)) {
        Toggle({ type: ToggleType.Checkbox, isOn: this.isSelected(item) })
          .onChange(() => {
            this.toggleSelect(item);
          });
      }
      Column({ space: 2 }) {
        Text(this.itemTitle(item))
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        Text(this.itemSubtitle(item))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
    .width('100%')
    .padding($r('app.float.page_padding'))
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => this.onBrowseItemTap(item));
  }

  @Builder
  failedView() {
    SectionTitle({ title: `导入失败记录（${this.failedItems.length}）`, actionLabel: '刷新',
      onAction: () => { void this.loadFailed(); } });
    if (this.failedItems.length === 0) {
      EmptyState({ message: this.failedLoaded ? '暂无失败记录' : '正在加载…' });
    } else {
      List({ space: 8 }) {
        ForEach(this.failedItems, (item: AdminOpdsFailedItem) => {
          ListItem() {
            this.failedRow(item);
          }
        }, (item: AdminOpdsFailedItem) => `opds-failed-${item.id ?? 0}`);
      }
      .layoutWeight(1)
      .width('100%');
    }
  }

  @Builder
  failedRow(item: AdminOpdsFailedItem) {
    Column({ space: 4 }) {
      Text(item.title !== undefined && item.title.length > 0 ? item.title : `#${item.id ?? 0}`)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
      Text(`${item.author ?? ''} · ${item.update_time ?? ''}`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
      Text(`${this.failedError(item)}`)
        .fontSize(12)
        .fontColor($r('app.color.error'))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
      TextButton({
        label: '重试导入',
        onTap: () => this.retryFailed(item),
      });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }
}
