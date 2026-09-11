import { PageScaffold, LoadingState, EmptyState } from '../components';
import { TalebookApi } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';

@Entry
@Component
struct AdminSyslogPage {
  @State lines: string[] = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  @State refreshing: boolean = false;

  aboutToAppear(): void {
    void this.loadLog();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async loadLog(): Promise<void> {
    if (this.lines.length > 0) {
      this.refreshing = true;
    } else {
      this.loading = true;
    }
    this.loadError = '';
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.getAdminSyslog();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.loadError = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err;
      } else {
        this.lines = rsp.lines ?? [];
      }
    } catch (e) {
      this.loadError = `加载失败：${e}`;
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '系统日志',
        showBack: true,
        action: () => {
          this.refreshAction();
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
  refreshAction() {
    Text('刷新')
      .fontSize(14)
      .fontColor($r('app.color.brand_primary'))
      .padding({ left: 8, right: 16 })
      .onClick(() => {
        if (!this.refreshing) {
          void this.loadLog();
        }
      });
  }

  @Builder
  pageContent() {
    if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({ message: this.loadError });
    } else if (this.lines.length === 0) {
      EmptyState({ message: '日志为空' });
    } else {
      Column() {
        Text(`最近 ${this.lines.length} 行日志 · 点「刷新」获取最新`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 4 });
        List() {
          ForEach(this.lines, (line: string, index: number) => {
            ListItem() {
              Text(line.length > 0 ? line : ' ')
                .fontSize(11)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .padding({ left: 12, right: 12, top: 1, bottom: 1 });
            }
          }, (line: string, index: number) => `log-${index}-${line.length}`);
        }
        .layoutWeight(1)
        .width('100%')
        .backgroundColor($r('app.color.card_background'))
        .borderRadius($r('app.float.card_radius'))
        .margin({ left: 16, right: 16, bottom: 16 });
      }
      .width('100%')
      .height('100%');
    }
  }
}
