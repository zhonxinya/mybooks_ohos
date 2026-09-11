import { router } from '@kit.ArkUI';
import {
  PageScaffold, PrimaryButton, SecondaryButton, SettingCell, LoadingState
} from '../components';
import {
  TalebookApi, ApiMessageResult, apiErrorMessage,
  ToolboxDataResponse, ToolboxTaskProgressResponse
} from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';

@Entry
@Component
struct TextReplaceToolPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State progressHint: string = '';
  @State running: boolean = false;

  @State bookIdText: string = '';
  @State pattern: string = '';
  @State replacement: string = '';
  @State useRegex: boolean = false;
  @State suffix: string = '';
  @State format: string = '';
  @State previewHint: string = '';

  private pollTimer: number = -1;

  aboutToAppear(): void {
    void this.bootstrap();
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private setMsg(text: string, error: boolean): void {
    this.message = text;
    this.isError = error;
  }

  private stopPoll(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private schedulePoll(): void {
    this.stopPoll();
    if (!this.running) {
      return;
    }
    this.pollTimer = setTimeout(() => {
      void this.refreshProgress(true);
    }, 2000);
  }

  private async bootstrap(): Promise<void> {
    this.loading = true;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.setMsg('请先配置 Talebook 服务器', true);
        return;
      }
      await TalebookService.ensureAuthenticated();
      await this.refreshProgress(false);
    } finally {
      this.loading = false;
    }
  }

  private async runPreview(): Promise<void> {
    if (this.busy) {
      return;
    }
    const bookId = Number(this.bookIdText.trim());
    if (!(bookId > 0)) {
      this.setMsg('请填写有效的书籍 ID', true);
      return;
    }
    if (this.pattern.length === 0) {
      this.setMsg('请填写查找内容 / 正则', true);
      return;
    }
    this.busy = true;
    try {
      const rsp: ToolboxDataResponse = await TalebookApi.textReplacePreview(
        bookId, this.pattern, this.replacement, this.useRegex, this.format.trim());
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '预览失败', true);
        return;
      }
      const data = rsp.data;
      let hint = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '预览完成';
      if (data !== undefined) {
        const regexErr = String(data['regex_error'] ?? '');
        if (regexErr.length > 0) {
          this.setMsg(`正则错误：${regexErr}`, true);
          this.previewHint = '';
          return;
        }
        const count = data['count'] ?? data['match_count'] ?? data['matches'];
        const fmt = data['format'];
        if (count !== undefined) {
          hint = `${hint} · 匹配 ${count}`;
        }
        if (fmt !== undefined) {
          hint = `${hint} · 格式 ${fmt}`;
        }
        const samples = data['samples'];
        if (Array.isArray(samples) && samples.length > 0) {
          const first = samples[0] as Record<string, Object>;
          const sampleText = String(first['text'] ?? first['before'] ?? first['after'] ?? JSON.stringify(first));
          hint = `${hint}\n样例：${sampleText.substring(0, 120)}`;
        }
      }
      this.previewHint = hint;
      this.setMsg('预览完成', false);
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async runReplace(): Promise<void> {
    if (this.busy || this.running) {
      return;
    }
    const bookId = Number(this.bookIdText.trim());
    if (!(bookId > 0)) {
      this.setMsg('请填写有效的书籍 ID', true);
      return;
    }
    if (this.pattern.length === 0) {
      this.setMsg('请填写查找内容 / 正则', true);
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.textReplaceRun(
        bookId, this.pattern, this.replacement, this.useRegex,
        this.suffix.trim(), this.format.trim());
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '启动替换失败', true);
        return;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已开始文本替换', false);
      this.running = true;
      this.schedulePoll();
      await this.refreshProgress(false);
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async refreshProgress(fromPoll: boolean): Promise<void> {
    try {
      const rsp: ToolboxTaskProgressResponse = await TalebookApi.textReplaceProgress();
      const data = rsp.data;
      const status = data !== undefined ? String(data['status'] ?? '') : '';
      const percentRaw = data !== undefined ? (data['percent'] ?? data['progress']) : undefined;
      const percent = percentRaw !== undefined ? Number(percentRaw) : -1;
      const msg = data !== undefined
        ? String(data['message'] ?? data['msg'] ?? data['stage'] ?? '')
        : (rsp.msg !== undefined ? rsp.msg : '');
      const isRunning = status === 'running' || status === 'pending' || status === 'processing' ||
        (percent >= 0 && percent < 100 && status !== 'done' && status !== 'finished' &&
          status !== 'success' && status !== 'failed' && status !== 'error' && status.length > 0);

      if (rsp.err !== undefined && rsp.err !== 'ok' && !isRunning) {
        this.progressHint = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '';
        this.running = false;
        this.stopPoll();
        return;
      }

      const pct = percent >= 0 ? ` ${percent}%` : '';
      this.progressHint = (msg.length > 0 ? msg : (status.length > 0 ? status : '无进行中任务')) + pct;

      if (isRunning) {
        this.running = true;
        this.schedulePoll();
        return;
      }

      if (fromPoll && this.running) {
        this.setMsg(this.progressHint.length > 0 ? this.progressHint : '替换已结束', false);
      }
      this.running = false;
      this.stopPoll();
    } catch (_e) {
      if (this.running) {
        this.schedulePoll();
      }
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '文本替换',
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
          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13)
              .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
              .width('100%');
          }
          if (this.progressHint.length > 0 || this.running) {
            Text(this.running ? `进度：${this.progressHint}` : `上次：${this.progressHint}`)
              .fontSize(13)
              .fontColor($r('app.color.brand_primary'))
              .width('100%');
          }
          if (this.previewHint.length > 0) {
            Text(this.previewHint)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%');
          }

          Column({ space: 10 }) {
            TextInput({ placeholder: '书籍 ID', text: this.bookIdText })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.bookIdText = v;
              });
            TextInput({ placeholder: '查找内容 / 正则 pattern', text: this.pattern })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.pattern = v;
              });
            TextInput({ placeholder: '替换为 replacement（可空）', text: this.replacement })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.replacement = v;
              });
            TextInput({ placeholder: '格式 format（可选，如 EPUB / TXT）', text: this.format })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.format = v;
              });
            TextInput({ placeholder: '输出后缀 suffix（可选）', text: this.suffix })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.suffix = v;
              });
          }
          .width('100%')
          .padding(12)
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          Column() {
            SettingCell({
              title: '使用正则',
              subtitle: this.useRegex ? '正则模式' : '普通文本模式',
              showToggle: true,
              toggleOn: this.useRegex,
              onToggle: (v: boolean) => {
                this.useRegex = v;
              },
            });
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          SecondaryButton({
            label: this.busy ? '预览中…' : '预览匹配',
            buttonEnabled: !this.busy && !this.running,
            onTap: () => {
              void this.runPreview();
            },
          });
          PrimaryButton({
            label: this.busy ? '处理中…' : (this.running ? '替换进行中…' : '开始替换'),
            buttonEnabled: !this.busy && !this.running,
            onTap: () => {
              void this.runReplace();
            },
          });
          SecondaryButton({
            label: '刷新进度',
            buttonEnabled: !this.busy,
            onTap: () => {
              void this.refreshProgress(false);
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
