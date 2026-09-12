import {
  PageScaffold, PrimaryButton, SecondaryButton, SettingCell, LoadingState
} from '../components';
import {
  TalebookApi, ApiMessageResult, apiErrorMessage, ToolboxTaskProgressResponse
} from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';

@Entry
@Component
struct FormatsPruningToolPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State progressHint: string = '';
  @State running: boolean = false;
  @State selectedFormat: string = 'azw3_mobi';

  private pollTimer: number = -1;
  private readonly formatKeys: string[] = ['pdf', 'epub', 'azw3_mobi', 'txt', 'docx'];

  aboutToAppear(): void {
    void this.bootstrap();
  }

  aboutToDisappear(): void {
    this.stopPoll();
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

  private formatLabel(key: string): string {
    if (key === 'pdf') {
      return 'PDF';
    }
    if (key === 'epub') {
      return 'EPUB';
    }
    if (key === 'azw3_mobi') {
      return 'AZW3 / MOBI';
    }
    if (key === 'txt') {
      return 'TXT';
    }
    if (key === 'docx') {
      return 'DOCX';
    }
    return key;
  }

  private cycleFormat(): void {
    const idx = this.formatKeys.indexOf(this.selectedFormat);
    const next = idx < 0 ? 0 : (idx + 1) % this.formatKeys.length;
    this.selectedFormat = this.formatKeys[next];
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

  private confirmStart(): void {
    if (this.busy || this.running) {
      return;
    }
    const label = this.formatLabel(this.selectedFormat);
    this.getUIContext().getPromptAction().showDialog({
      title: '确认清理格式',
      message: `将从书库中删除所有「${label}」格式文件，此操作不可撤销。确定开始？`,
      buttons: [
        { text: '取消', color: '#999999' },
        { text: '开始清理', color: '#E84026' },
      ],
    }).then((result) => {
      if (result.index === 1) {
        void this.startPrune();
      }
    }).catch(() => {});
  }

  private async startPrune(): Promise<void> {
    if (this.busy || this.running) {
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.formatsPruningStart([this.selectedFormat]);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '启动清理失败', true);
        return;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已开始清理格式', false);
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
      const rsp: ToolboxTaskProgressResponse = await TalebookApi.formatsPruningProgress();
      const data = rsp.data;
      const status = data !== undefined ? String(data['status'] ?? '') : '';
      const percentRaw = data !== undefined ? (data['percent'] ?? data['progress']) : undefined;
      const percent = percentRaw !== undefined ? Number(percentRaw) : -1;
      const msg = data !== undefined
        ? String(data['message'] ?? data['msg'] ?? data['stage'] ?? '')
        : (rsp.msg !== undefined ? rsp.msg : '');

      const extras: string[] = [];
      if (data !== undefined) {
        const checked = data['checked'];
        const total = data['total'];
        const prunedBooks = data['pruned_books'];
        const prunedFormats = data['pruned_formats'];
        if (checked !== undefined && total !== undefined) {
          extras.push(`已检查 ${checked}/${total}`);
        } else if (total !== undefined) {
          extras.push(`共 ${total}`);
        }
        if (prunedBooks !== undefined) {
          extras.push(`清理书籍 ${prunedBooks}`);
        }
        if (prunedFormats !== undefined) {
          extras.push(`清理格式 ${prunedFormats}`);
        }
      }

      const isRunning = status === 'running' || status === 'pending' || status === 'processing' ||
        (percent >= 0 && percent < 100 && status !== 'done' && status !== 'finished' &&
          status !== 'completed' && status !== 'success' && status !== 'failed' &&
          status !== 'error' && status.length > 0);

      if (rsp.err !== undefined && rsp.err !== 'ok' && !isRunning) {
        this.progressHint = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '';
        this.running = false;
        this.stopPoll();
        return;
      }

      const pct = percent >= 0 ? ` ${percent}%` : '';
      const base = msg.length > 0 ? msg : (status.length > 0 ? status : '无进度详情');
      const extraText = extras.length > 0 ? ` · ${extras.join(' · ')}` : '';
      this.progressHint = `${base}${pct}${extraText}`;

      if (isRunning) {
        this.running = true;
        this.schedulePoll();
        return;
      }

      if (fromPoll && this.running) {
        this.setMsg(this.progressHint.length > 0 ? this.progressHint : '清理已结束', false);
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
        title: '格式清理',
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
          Text('从书库中批量删除指定格式文件。点击「要删除的格式」可切换选项，确认后再开始。')
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

          Column() {
            SettingCell({
              title: '要删除的格式',
              subtitle: this.formatLabel(this.selectedFormat),
              showChevron: true,
              onTap: () => {
                if (!this.busy && !this.running) {
                  this.cycleFormat();
                }
              },
            });
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          Text('可选：PDF / EPUB / AZW3·MOBI / TXT / DOCX')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%');

          PrimaryButton({
            label: this.busy ? '处理中…' : (this.running ? '清理进行中…' : '开始清理'),
            buttonEnabled: !this.busy && !this.running,
            onTap: () => {
              this.confirmStart();
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
