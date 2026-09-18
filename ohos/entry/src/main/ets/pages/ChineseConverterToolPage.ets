import {
  PageScaffold, PrimaryButton, SecondaryButton, SettingCell, LoadingState, BookIdPicker
} from '../components';
import {
  TalebookApi, ApiMessageResult, apiErrorMessage, ToolboxTaskProgressResponse
} from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';

@Entry
@Component
struct ChineseConverterToolPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State progressHint: string = '';
  @State converting: boolean = false;

  @State bookIdText: string = '';
  @State convertDirection: string = 't2s';
  @State mode: string = 'book';
  @State convertTitle: boolean = true;
  @State useA5: boolean = false;
  @State backup: boolean = false;

  private pollTimer: number = -1;

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
    if (!this.converting) {
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

  private async runConvert(): Promise<void> {
    if (this.busy || this.converting) {
      return;
    }
    const bookId = Number(this.bookIdText.trim());
    if (!(bookId > 0)) {
      this.setMsg('请填写有效的书籍 ID', true);
      return;
    }
    const direction = this.convertDirection.trim().length > 0 ? this.convertDirection.trim() : 't2s';
    const mode = this.mode.trim().length > 0 ? this.mode.trim() : 'book';
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.chineseConverterConvert(
        bookId, direction, mode, this.convertTitle, this.useA5, this.backup);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '启动转换失败', true);
        return;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已开始简繁转换', false);
      this.converting = true;
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
      const rsp: ToolboxTaskProgressResponse = await TalebookApi.chineseConverterProgress();
      const data = rsp.data;
      const status = data !== undefined ? String(data['status'] ?? '') : '';
      const percentRaw = data !== undefined ? data['percent'] : undefined;
      const percent = percentRaw !== undefined ? Number(percentRaw) : -1;
      const msg = data !== undefined ? String(data['message'] ?? data['msg'] ?? '') :
        (rsp.msg !== undefined ? rsp.msg : '');
      const running = status === 'running' || status === 'pending' || status === 'converting' ||
        (percent >= 0 && percent < 100 && status !== 'done' && status !== 'finished' &&
          status !== 'success' && status !== 'failed' && status !== 'error' && status.length > 0);

      if (rsp.err !== undefined && rsp.err !== 'ok' && !running) {
        this.progressHint = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '';
        this.converting = false;
        this.stopPoll();
        return;
      }

      const pct = percent >= 0 ? ` ${percent}%` : '';
      this.progressHint = (msg.length > 0 ? msg : (status.length > 0 ? status : '无进行中任务')) + pct;

      if (running) {
        this.converting = true;
        this.schedulePoll();
        return;
      }

      if (fromPoll && this.converting) {
        this.setMsg(this.progressHint.length > 0 ? this.progressHint : '转换已结束', false);
      }
      this.converting = false;
      this.stopPoll();
    } catch (_e) {
      if (this.converting) {
        this.schedulePoll();
      }
    }
  }

  private directionLabel(): string {
    return this.convertDirection;
  }

  private cycleDirection(): void {
    const dirs: string[] = ['t2s', 'tw2s', 'tw2sp', 's2t', 's2tw', 's2twp', 't2tw', 'tw2t'];
    let idx = dirs.indexOf(this.convertDirection);
    if (idx < 0) {
      idx = 0;
    } else {
      idx = (idx + 1) % dirs.length;
    }
    this.convertDirection = dirs[idx];
  }

  private cycleMode(): void {
    // book=另存为新书；replace=替换原书
    this.mode = this.mode === 'replace' ? 'book' : 'replace';
  }

  build() {
    Column() {
      PageScaffold({
        title: '简繁转换',
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
          if (this.progressHint.length > 0 || this.converting) {
            Text(this.converting ? `进度：${this.progressHint}` : `上次：${this.progressHint}`)
              .fontSize(13)
              .fontColor($r('app.color.brand_primary'))
              .width('100%');
          }

          Column({ space: 10 }) {
            BookIdPicker({ bookIdText: $bookIdText });
            Text('方向：t2s/tw2s/tw2sp/s2t/s2tw/s2twp/t2tw/tw2t')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%');
            TextInput({ placeholder: '方向 direction（t2s / s2t）', text: this.convertDirection })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.convertDirection = v;
              });
            Text('模式：book=另存新书，replace=替换原书')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%');
            TextInput({ placeholder: '模式 mode', text: this.mode })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.mode = v;
              });
          }
          .width('100%')
          .padding(12)
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          Column() {
            SettingCell({
              title: '当前方向',
              subtitle: this.directionLabel(),
              showChevron: true,
              onTap: () => {
                this.cycleDirection();
              },
            });
            SettingCell({
              title: '当前模式',
              subtitle: this.mode,
              showChevron: true,
              onTap: () => {
                this.cycleMode();
              },
            });
            SettingCell({
              title: '同时转换标题',
              showToggle: true,
              toggleOn: this.convertTitle,
              onToggle: (v: boolean) => {
                this.convertTitle = v;
              },
            });
            SettingCell({
              title: '使用 A5 词典增强',
              showToggle: true,
              toggleOn: this.useA5,
              onToggle: (v: boolean) => {
                this.useA5 = v;
              },
            });
            SettingCell({
              title: '转换前备份',
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
            label: this.busy ? '处理中…' : (this.converting ? '转换进行中…' : '开始转换'),
            buttonEnabled: !this.busy && !this.converting,
            onTap: () => {
              void this.runConvert();
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
