import { router } from '@kit.ArkUI';
import {
  PageScaffold, PrimaryButton, SecondaryButton, LoadingState
} from '../components';
import {
  TalebookApi, ApiMessageResult, apiErrorMessage,
  ToolboxDataResponse, ToolboxTaskProgressResponse
} from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';

@Entry
@Component
struct TxtEncodingFixerToolPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State progressHint: string = '';
  @State running: boolean = false;
  @State bookIdText: string = '';
  @State analyzeHint: string = '';

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

  private async analyze(): Promise<void> {
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
      const rsp: ToolboxDataResponse = await TalebookApi.txtEncodingFixerAnalyze(bookId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '分析失败', true);
        this.analyzeHint = '';
        return;
      }
      const data = rsp.data;
      let hint = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '分析完成';
      if (data !== undefined) {
        const bits: string[] = [];
        const enc = data['encoding'] ?? data['detected_encoding'] ?? data['source_encoding'];
        const target = data['target_encoding'] ?? data['target'];
        const mojibake = data['mojibake'] ?? data['has_mojibake'] ?? data['need_fix'];
        const conf = data['confidence'];
        if (enc !== undefined) {
          bits.push(`检测编码 ${enc}`);
        }
        if (target !== undefined) {
          bits.push(`目标 ${target}`);
        }
        if (mojibake !== undefined) {
          bits.push(Boolean(mojibake) ? '疑似乱码' : '未见乱码');
        }
        if (conf !== undefined) {
          bits.push(`置信度 ${conf}`);
        }
        if (bits.length > 0) {
          hint = bits.join(' · ');
        }
        const sample = String(data['sample'] ?? data['preview'] ?? '');
        if (sample.length > 0) {
          hint = `${hint}\n样例：${sample.substring(0, 160)}`;
        }
      }
      this.analyzeHint = hint;
      this.setMsg('分析完成', false);
    } catch (e) {
      this.setMsg(`${e}`, true);
      this.analyzeHint = '';
    } finally {
      this.busy = false;
    }
  }

  private async runFix(): Promise<void> {
    if (this.busy || this.running) {
      return;
    }
    const bookId = Number(this.bookIdText.trim());
    if (!(bookId > 0)) {
      this.setMsg('请填写有效的书籍 ID', true);
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.txtEncodingFixerFix(bookId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '启动修复失败', true);
        return;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已开始编码修复', false);
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
      const rsp: ToolboxTaskProgressResponse = await TalebookApi.txtEncodingFixerProgress();
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
        this.setMsg(this.progressHint.length > 0 ? this.progressHint : '修复已结束', false);
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
        title: 'TXT 编码修复',
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
          Text('检测 TXT 乱码/错误编码并修复为可读编码。建议先分析再修复。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');

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
          if (this.analyzeHint.length > 0) {
            Text(this.analyzeHint)
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
          }
          .width('100%')
          .padding(12)
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          SecondaryButton({
            label: this.busy ? '分析中…' : '分析编码',
            buttonEnabled: !this.busy && !this.running,
            onTap: () => {
              void this.analyze();
            },
          });
          PrimaryButton({
            label: this.busy ? '处理中…' : (this.running ? '修复进行中…' : '开始修复'),
            buttonEnabled: !this.busy && !this.running,
            onTap: () => {
              void this.runFix();
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
