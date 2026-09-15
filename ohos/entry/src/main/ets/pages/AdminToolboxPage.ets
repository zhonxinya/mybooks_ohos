import { PageScaffold, LoadingState, EmptyState, FilterChips, FilterChipItem,
  SecondaryButton } from '../components';
import { TalebookApi, ApiMessageResult, ToolboxStoreIndexResponse } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';

@Entry
@Component
struct AdminToolboxPage {
  @State tools: Record<string, Object>[] = [];
  @State storeTools: Record<string, Object>[] = [];
  @State storeEnabled: boolean = false;
  @State loading: boolean = true;
  @State loadError: string = '';
  @State workingId: string = '';
  @State selectedTab: number = 0;
  @State storeHint: string = '';
  /** 工具箱（工具启停/安装/商店）为 mybooks 专有端点。 */
  @State supported: boolean = true;

  aboutToAppear(): void {
    this.supported = ServerRegistry.supports(ServerFeature.ADMIN_TOOLBOX);
    if (!this.supported) {
      this.loading = false;
      return;
    }
    void this.loadInstalled();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private onTabChange(value: number): void {
    this.selectedTab = value;
    if (value === 0) {
      void this.loadInstalled();
    } else {
      void this.loadStore(false);
    }
  }

  private async loadInstalled(): Promise<void> {
    if (!this.supported) {
      this.loading = false;
      return;
    }
    this.loading = this.tools.length === 0;
    this.loadError = '';
    try {
      await TalebookService.ensureAuthenticated();
      // 管理页需要看到已禁用工具
      const rsp = await TalebookApi.getAdminToolList(true);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.loadError = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err;
        return;
      }
      this.tools = rsp.tools ?? [];
    } catch (e) {
      this.loadError = `加载失败：${e}`;
    } finally {
      this.loading = false;
    }
  }

  private async loadStore(forceRefresh: boolean): Promise<void> {
    if (!this.supported) {
      this.loading = false;
      return;
    }
    this.loading = this.storeTools.length === 0;
    this.loadError = '';
    this.storeHint = '';
    try {
      await TalebookService.ensureAuthenticated();
      const rsp: ToolboxStoreIndexResponse = await TalebookApi.getToolboxStoreIndex(forceRefresh);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.loadError = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err;
        return;
      }
      this.storeEnabled = Boolean(rsp.enabled);
      this.storeTools = rsp.tools ?? [];
      if (!this.storeEnabled) {
        this.storeHint = '工具商店未开启（可在管理员设置中启用）';
      } else if (this.storeTools.length === 0) {
        this.storeHint = '暂无可安装工具';
      }
    } catch (e) {
      this.loadError = `商店加载失败：${e}`;
    } finally {
      this.loading = false;
    }
  }

  private handleResult(rsp: ApiMessageResult, fallback: string): boolean {
    if (rsp.err === undefined || rsp.err === 'ok') {
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : fallback);
      return true;
    }
    this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
    return false;
  }

  private setToolEnabled(tool: Record<string, Object>, enable: boolean): void {
    if (!ServerRegistry.supports(ServerFeature.ADMIN_TOOLBOX)) {
      return;
    }
    const toolId = String(tool['id'] ?? '');
    if (toolId.length === 0 || this.workingId.length > 0) {
      return;
    }
    this.workingId = toolId;
    const req = enable ? TalebookApi.enableToolboxTool(toolId) : TalebookApi.disableToolboxTool(toolId);
    req.then((rsp: ApiMessageResult) => {
      this.workingId = '';
      if (this.handleResult(rsp, enable ? '已启用' : '已禁用')) {
        void this.loadInstalled();
      }
    }).catch((e: Object) => {
      this.workingId = '';
      this.toast(`操作失败：${e}`);
    });
  }

  private uninstallTool(tool: Record<string, Object>): void {
    if (!ServerRegistry.supports(ServerFeature.ADMIN_TOOLBOX)) {
      return;
    }
    const toolId = String(tool['id'] ?? '');
    const name = String(tool['name'] ?? toolId);
    if (toolId.length === 0 || this.workingId.length > 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '卸载工具',
      message: `确定卸载「${name}」吗？可能需要重启服务端后完全生效。`,
      primaryButton: {
        value: '卸载',
        action: () => {
          this.workingId = toolId;
          TalebookApi.uninstallToolboxTool(toolId)
            .then((rsp: ApiMessageResult) => {
              this.workingId = '';
              if (this.handleResult(rsp, '已卸载')) {
                void this.loadInstalled();
              }
            })
            .catch((e: Object) => {
              this.workingId = '';
              this.toast(`卸载失败：${e}`);
            });
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private installStoreTool(tool: Record<string, Object>): void {
    if (!ServerRegistry.supports(ServerFeature.ADMIN_TOOLBOX)) {
      return;
    }
    const toolId = String(tool['tool_id'] ?? tool['id'] ?? '');
    if (toolId.length === 0 || this.workingId.length > 0) {
      return;
    }
    const installed = Boolean(tool['installed']);
    this.workingId = toolId;
    TalebookApi.installToolboxStoreTool(toolId)
      .then((rsp: ApiMessageResult) => {
        this.workingId = '';
        if (this.handleResult(rsp, installed ? '已更新' : '已安装')) {
          void this.loadStore(true);
          void this.loadInstalled();
        }
      })
      .catch((e: Object) => {
        this.workingId = '';
        this.toast(`安装失败：${e}`);
      });
  }

    private openToolPage(toolId: string): void {
    if (toolId === 'mimo_tts') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/MimoTtsToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'epub_beautify') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/EpubBeautifyToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'chinese_converter') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/ChineseConverterToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'bookbarn_acceptor') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/BookbarnAcceptorToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'minify_pdf') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/MinifyPdfToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'epub_fixer') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/EpubFixerToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'epub_split') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/EpubSplitToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'text_replace') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/TextReplaceToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'txt_encoding_fixer') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/TxtEncodingFixerToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'formats_pruning') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/FormatsPruningToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'author_clean') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/AuthorCleanToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'text_processor') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/TextProcessorToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'merge_formats_tool' || toolId === 'merge_formats') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/MergeFormatsToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'rare_book_downloader') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/RareBookDownloaderToolPage' }).catch(() => {});
      return;
    }
    if (toolId === 'review_book_language') {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/ReviewBookLanguageToolPage' }).catch(() => {});
      return;
    }
    try {
      this.getUIContext().getPromptAction().showToast({ message: '该工具暂无独立页面' });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private showInstalledActions(tool: Record<string, Object>): void {
    const toolId = String(tool['id'] ?? '');
    const disabled = String(tool['status'] ?? '') === 'disabled';
    const enableText = disabled ? '启用工具' : '停用工具';
    if (toolId === 'mimo_tts' || toolId === 'epub_beautify' || toolId === 'chinese_converter' || toolId === 'bookbarn_acceptor' || toolId === 'minify_pdf' || toolId === 'epub_fixer' || toolId === 'epub_split' || toolId === 'text_replace' || toolId === 'txt_encoding_fixer' || toolId === 'formats_pruning' || toolId === 'author_clean' || toolId === 'text_processor' || toolId === 'merge_formats_tool' || toolId === 'merge_formats' || toolId === 'rare_book_downloader' || toolId === 'review_book_language') {
      this.getUIContext().getPromptAction().showActionMenu({
        title: String(tool['name'] ?? ''),
        buttons: [
          { text: '打开工具', color: '#007DFF' },
          { text: enableText, color: '#007DFF' },
          { text: '卸载工具', color: '#E84026' },
        ],
      }).then((result) => {
        if (result.index === 0) {
          this.openToolPage(toolId);
        } else if (result.index === 1) {
          this.setToolEnabled(tool, disabled);
        } else if (result.index === 2) {
          this.uninstallTool(tool);
        }
      }).catch(() => {});
      return;
    }
    this.getUIContext().getPromptAction().showActionMenu({
      title: String(tool['name'] ?? ''),
      buttons: [
        { text: enableText, color: '#007DFF' },
        { text: '卸载工具', color: '#E84026' },
      ],
    }).then((result) => {
      if (result.index === 0) {
        this.setToolEnabled(tool, disabled);
      } else if (result.index === 1) {
        this.uninstallTool(tool);
      }
    }).catch(() => {});
  }

  private showStoreActions(tool: Record<string, Object>): void {
    const installed = Boolean(tool['installed']);
    this.getUIContext().getPromptAction().showActionMenu({
      title: String(tool['name'] ?? tool['tool_id'] ?? ''),
      buttons: [
        { text: installed ? '更新 / 重装' : '安装', color: '#007DFF' },
      ],
    }).then((result) => {
      if (result.index === 0) {
        this.installStoreTool(tool);
      }
    }).catch(() => {});
  }

  private statusLabel(status: string): string {
    return status === 'disabled' ? '已禁用' : '已启用';
  }

  private statusColor(status: string): ResourceColor {
    return status === 'disabled' ? $r('app.color.text_tertiary') : $r('app.color.on_brand');
  }

  build() {
    Column() {
      PageScaffold({
        title: '工具箱',
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
      EmptyState({ message: `${ServerRegistry.profile().displayName} 服务端不支持工具箱` });
    } else {
      this.toolboxContent();
    }
  }

  @Builder
  toolboxContent() {
    Column() {
      FilterChips({
        items: [
          { label: '已安装', value: 0 },
          { label: '商店', value: 1 },
        ] as FilterChipItem[],
        selected: $selectedTab,
        onChange: (value: number) => this.onTabChange(value),
      });

      if (this.selectedTab === 1) {
        Row() {
          Text(this.storeEnabled ? '商店已开启' : '商店未开启')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1);
          SecondaryButton({
            label: this.workingId.length > 0 ? '处理中…' : '刷新商店',
            buttonEnabled: this.workingId.length === 0 && !this.loading,
            fullWidth: false,
            onTap: () => { void this.loadStore(true); },
          });
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 4 });
      }

      if (this.loading) {
        LoadingState({});
      } else if (this.loadError.length > 0) {
        EmptyState({ message: this.loadError });
      } else if (this.selectedTab === 0) {
        if (this.tools.length === 0) {
          EmptyState({ message: '尚未安装工具' });
        } else {
          List({ space: 8 }) {
            ForEach(this.tools, (tool: Record<string, Object>) => {
              ListItem() {
                this.installedRow(tool);
              }
            }, (tool: Record<string, Object>) => `tool-${String(tool['id'] ?? '')}`);
          }
          .layoutWeight(1)
          .width('100%');
        }
      } else {
        if (this.storeTools.length === 0) {
          EmptyState({ message: this.storeHint.length > 0 ? this.storeHint : '暂无可安装工具' });
        } else {
          if (this.storeHint.length > 0) {
            Text(this.storeHint)
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .padding({ left: 16, right: 16, bottom: 4 });
          }
          List({ space: 8 }) {
            ForEach(this.storeTools, (tool: Record<string, Object>) => {
              ListItem() {
                this.storeRow(tool);
              }
            }, (tool: Record<string, Object>) => `store-${String(tool['tool_id'] ?? tool['id'] ?? '')}`);
          }
          .layoutWeight(1)
          .width('100%');
        }
      }
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  installedRow(tool: Record<string, Object>) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(String(tool['name'] ?? ''))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Text(this.workingId === String(tool['id'] ?? '') ? '处理中' : this.statusLabel(String(tool['status'] ?? '')))
          .fontSize(11)
          .fontColor(this.statusColor(String(tool['status'] ?? '')))
          .backgroundColor($r('app.color.page_background'))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 });
      }
      .width('100%');

      if (String(tool['description'] ?? '').length > 0) {
        Text(String(tool['description'] ?? ''))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }

      Text(`版本 ${String(tool['revision'] ?? '')} · ${String(tool['author'] ?? '')} · 点按管理`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'));
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
    .onClick(() => this.showInstalledActions(tool));
  }

  @Builder
  storeRow(tool: Record<string, Object>) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(String(tool['name'] ?? tool['tool_id'] ?? ''))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Text(Boolean(tool['installed']) ? '已安装' : '未安装')
          .fontSize(11)
          .fontColor(Boolean(tool['installed']) ? $r('app.color.on_brand') : $r('app.color.text_tertiary'))
          .backgroundColor($r('app.color.page_background'))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 });
      }
      .width('100%');

      if (String(tool['description'] ?? '').length > 0) {
        Text(String(tool['description'] ?? ''))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }

      Text(`最新 ${String(tool['latest_revision'] ?? tool['revision'] ?? '')}`
        + (Boolean(tool['installed']) ? ` · 本地 ${String(tool['installed_revision'] ?? '')}` : '')
        + ' · 点按安装')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'));
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
    .onClick(() => this.showStoreActions(tool));
  }
}
