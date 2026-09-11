import {
  PageScaffold, PrimaryButton, LoadingState
} from '../components';
import { TalebookApi, ApiMessageResult, apiErrorMessage } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';

@Entry
@Component
struct RareBookDownloaderToolPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State urlText: string = '';

  aboutToAppear(): void {
    void this.bootstrap();
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
      this.setMsg('粘贴受支持的古书页面链接后开始下载导入', false);
    } finally {
      this.loading = false;
    }
  }

  private async startDownload(): Promise<void> {
    if (this.busy) {
      return;
    }
    const url = this.urlText.trim();
    if (url.length === 0) {
      this.setMsg('请填写古书页面 URL', true);
      return;
    }
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      this.setMsg('URL 需以 http:// 或 https:// 开头', true);
      return;
    }
    this.busy = true;
    this.setMsg('正在提交下载任务，可能较慢…', false);
    try {
      const rsp: ApiMessageResult = await TalebookApi.rareBookDownload(url);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '下载失败', true);
        return;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0
        ? rsp.msg
        : '已提交下载，完成后会导入书库', false);
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '古书下载',
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
          Text('从受支持的图书馆站点下载古书并导入书库。目前主要支持港科大等收录站点链接。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13)
              .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
              .width('100%');
          }

          Column({ space: 10 }) {
            TextArea({ placeholder: 'https://… 古书页面 URL', text: this.urlText })
              .height(100)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.urlText = v;
              });
          }
          .width('100%')
          .padding(12)
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          PrimaryButton({
            label: this.busy ? '下载中…' : '开始下载',
            buttonEnabled: !this.busy,
            onTap: () => {
              void this.startDownload();
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
