import { common, Want } from '@kit.AbilityKit';
import { PageScaffold, LoadingState, EmptyState } from '../components';
import { TalebookApi } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';

@Entry
@Component
struct AdminResourcesPage {
  @State resources: Record<string, Object>[] = [];
  @State loading: boolean = true;
  @State loadError: string = '';

  aboutToAppear(): void {
    void this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.getAdminResources();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.loadError = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err;
        return;
      }
      this.resources = rsp.resources ?? [];
    } catch (e) {
      this.loadError = `加载失败：${e}`;
    } finally {
      this.loading = false;
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openLink(url: string): void {
    // 链接来自服务端数据，仅允许 http/https，避免隐式 Want 被注入任意协议 URI
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      this.getUIContext().getPromptAction().showToast({ message: '链接协议不受支持' });
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: url,
    };
    context.startAbility(want).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开链接' });
    });
  }

  build() {
    Column() {
      PageScaffold({
        title: '资源导航',
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
    if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({ message: this.loadError });
    } else if (this.resources.length === 0) {
      EmptyState({ message: '暂无资源配置' });
    } else {
      List({ space: 8 }) {
        ForEach(this.resources, (resource: Record<string, Object>) => {
          ListItem() {
            this.resourceRow(resource);
          }
        }, (resource: Record<string, Object>, index: number) => `res-${index}`);
      }
      .layoutWeight(1)
      .width('100%');
    }
  }

  @Builder
  resourceRow(resource: Record<string, Object>) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.doc_text'))
        .fontSize(22)
        .fontColor([$r('app.color.brand_primary')]);
      Column({ space: 2 }) {
        Text(String(resource['title'] ?? ''))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(String(resource['link'] ?? ''))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
    .width('100%')
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .onClick(() => {
      const link = String(resource['link'] ?? '');
      if (link.length > 0) {
        this.openLink(link);
      }
    });
  }
}
