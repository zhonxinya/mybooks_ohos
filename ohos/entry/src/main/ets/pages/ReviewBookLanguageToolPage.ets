import {
  PageScaffold, PrimaryButton, LoadingState
} from '../components';
import { TalebookApi, ApiMessageResult, apiErrorMessage } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';

@Entry
@Component
struct ReviewBookLanguageToolPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;

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
      this.setMsg('将遍历书库，按书名检测语言并更新 languages 字段', false);
    } finally {
      this.loading = false;
    }
  }

  private confirmStart(): void {
    if (this.busy) {
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: '确认开始检测',
      message: '将遍历全部书籍，根据书名检测简体/繁体/日文等语言，并在不一致时更新语言字段。书多时可能较慢。',
      buttons: [
        { text: '取消', color: '#999999' },
        { text: '开始', color: '#007DFF' },
      ],
    }).then((result) => {
      if (result.index === 1) {
        void this.startReview();
      }
    }).catch(() => {});
  }

  private async startReview(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.setMsg('正在提交语言检测任务…', false);
    try {
      const rsp: ApiMessageResult = await TalebookApi.reviewBookLanguage();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '启动失败', true);
        return;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0
        ? rsp.msg
        : '已启动书名语言检测（可在运行任务中查看进度）', false);
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '书名语言检测',
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
          Text('遍历全部书籍，检测书名语言（简体中文 / 繁体中文 / 日文等），若与当前 languages 不一致则更新。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13)
              .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
              .width('100%');
          }

          PrimaryButton({
            label: this.busy ? '处理中…' : '开始检测',
            buttonEnabled: !this.busy,
            onTap: () => {
              this.confirmStart();
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
