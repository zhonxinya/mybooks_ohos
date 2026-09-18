import {
  PageScaffold, PrimaryButton, SecondaryButton, SettingCell, LoadingState, BookIdPicker
} from '../components';
import {
  TalebookApi, ApiMessageResult, apiErrorMessage
} from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';

@Entry
@Component
struct EpubFixerToolPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State bookIdText: string = '';
  @State backup: boolean = false;
  @State lastResult: string = '';

  aboutToAppear(): void {
    void this.bootstrap();
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private setMsg(text: string, error: boolean): void {
    this.message = text;
    this.isError = error;
  }

  private async bootstrap(): Promise<void> {
    this.loading = true;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.setMsg('请先配置 Talebook 服务器', true);
        return;
      }
      await TalebookService.ensureAuthenticated();
    } finally {
      this.loading = false;
    }
  }

  private async runFix(): Promise<void> {
    if (this.busy) {
      return;
    }
    const bookId = Number(this.bookIdText.trim());
    if (!(bookId > 0)) {
      this.setMsg('请填写有效的书籍 ID', true);
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.epubFixerFix(bookId, this.backup);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '启动修复失败', true);
        return;
      }
      const ok = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已开始 EPUB 修复（后台任务）';
      this.setMsg(ok, false);
      this.lastResult = `书籍 ${bookId}` + (this.backup ? ' · 含备份' : '') + ` · ${ok}`;
      this.toast(ok);
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: 'EPUB 修复',
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
    } else {
      Scroll() {
        Column({ space: 12 }) {
          Text('修复损坏或不规范的 EPUB，任务在服务器后台执行。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13)
              .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
              .width('100%');
          }
          if (this.lastResult.length > 0) {
            Text(this.lastResult)
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%');
          }

          Column({ space: 10 }) {
            BookIdPicker({ bookIdText: $bookIdText });
          }
          .width('100%')
          .padding(12)
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          Column() {
            SettingCell({
              title: '修复前备份原 EPUB',
              subtitle: '建议开启，便于回滚',
              showToggle: true,
              toggleOn: this.backup,
              onToggle: (v: boolean) => {
                this.backup = v;
              },
            });
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          PrimaryButton({
            label: this.busy ? '提交中…' : '开始修复',
            buttonEnabled: !this.busy,
            onTap: () => {
              void this.runFix();
            },
          });
          SecondaryButton({
            label: '查看运行中任务（设置 · 管理概览）',
            buttonEnabled: !this.busy,
            onTap: () => {
              this.getUIContext().getRouter().pushUrl({
                url: 'pages/MainTabs',
                params: { tab: 2, section: 'admin' },
              }).catch(() => {});
            },
          });
        }
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
        .width('100%');
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off);
    }
  }
}
