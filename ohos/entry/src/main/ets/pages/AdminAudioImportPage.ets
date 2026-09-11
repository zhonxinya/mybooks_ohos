import {
  PageScaffold, LoadingState, EmptyState, SectionTitle, SettingCell,
  PrimaryButton, SecondaryButton
} from '../components';
import {
  AdminImportApi, AdminApiResult, AudioTestOptions, AudioImportStatusResponse
} from '../services/AdminImportApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';

/** 状态轮询间隔 */
const POLL_INTERVAL_MS: number = 3000;

/**
 * 有声书导入（mybooks 专有）：POST /api/admin/audio_import/run 启动，
 * 轮询 /api/admin/audio_import/status 展示进度；POST /api/admin/audio/test 测试 EdgeTTS 连通性。
 */
@Entry
@Component
struct AdminAudioImportPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State testing: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State running: boolean = false;
  @State total: number = 0;
  @State imported: number = 0;
  @State exist: number = 0;
  @State skipped: number = 0;
  @State scanTotal: number = 0;
  @State scanDone: number = 0;
  @State scanTodo: number = 0;
  @State statusHint: string = '';
  @State proxyText: string = '';
  @State useBookbarnProxy: boolean = false;
  @State testResult: string = '';
  private gated: boolean = !ServerRegistry.supports(ServerFeature.ADMIN_AUDIO_IMPORT);
  private pollTimer: number = -1;

  aboutToAppear(): void {
    void this.bootstrap();
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private toast(text: string): void {
    this.getUIContext().getPromptAction().showToast({ message: text });
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
      void this.refreshStatus(true);
    }, POLL_INTERVAL_MS);
  }

  private async bootstrap(): Promise<void> {
    if (this.gated) {
      this.loading = false;
      return;
    }
    this.loading = true;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.setMsg('请先在设置中配置服务器地址', true);
        return;
      }
      await TalebookService.ensureAuthenticated();
      await this.refreshStatus(false);
      if (this.running) {
        this.schedulePoll();
      }
    } catch (e) {
      this.setMsg(`初始化失败：${e}`, true);
    } finally {
      this.loading = false;
    }
  }

  private async startImport(): Promise<void> {
    if (this.busy || this.running) {
      return;
    }
    this.busy = true;
    try {
      const rsp: AdminApiResult = await AdminImportApi.runAudioImport();
      if (!AdminImportApi.isOk(rsp)) {
        this.setMsg(AdminImportApi.errorText(rsp).length > 0 ?
          AdminImportApi.errorText(rsp) : '启动有声书导入失败', true);
        // 服务端已在运行时同步一次真实状态，避免界面与服务端不一致
        await this.refreshStatus(false);
        return;
      }
      this.total = 0;
      this.imported = 0;
      this.exist = 0;
      this.skipped = 0;
      this.statusHint = '任务已提交，等待服务端处理…';
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '有声书导入任务已启动', false);
      this.toast('有声书导入任务已启动');
      this.running = true;
      this.schedulePoll();
    } catch (e) {
      this.setMsg(`启动失败：${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async refreshStatus(continuePoll: boolean): Promise<void> {
    try {
      const rsp: AudioImportStatusResponse = await AdminImportApi.getAudioImportStatus();
      if (!AdminImportApi.isOk(rsp)) {
        this.statusHint = AdminImportApi.errorText(rsp).length > 0 ?
          AdminImportApi.errorText(rsp) : '状态获取失败';
        return;
      }
      const wasRunning = this.running;
      this.running = rsp.audio_importing === true;
      const status = rsp.status;
      if (status !== undefined) {
        this.total = status.total !== undefined ? status.total : 0;
        this.imported = status.imported !== undefined ? status.imported : 0;
        this.exist = status.exist !== undefined ? status.exist : 0;
        this.skipped = status.skipped !== undefined ? status.skipped : 0;
      }
      const summary = rsp.summary;
      if (summary !== undefined) {
        this.scanTotal = summary.total !== undefined ? summary.total : 0;
        this.scanDone = summary.done !== undefined ? summary.done : 0;
        this.scanTodo = summary.todo !== undefined ? summary.todo : 0;
      }
      if (this.running) {
        this.statusHint = `导入中 ${this.total > 0 ? `${this.imported + this.exist + this.skipped}/${this.total}` : '…'}`;
      } else if (wasRunning) {
        this.statusHint = `任务已结束：新增 ${this.imported}，已存在 ${this.exist}，跳过 ${this.skipped}`;
        this.toast('有声书导入任务已结束');
      } else {
        this.statusHint = '';
      }
    } catch (e) {
      this.statusHint = `状态刷新失败：${e}`;
    } finally {
      if (continuePoll) {
        this.schedulePoll();
      }
    }
  }

  private async testConnection(): Promise<void> {
    if (this.testing) {
      return;
    }
    const proxy = this.proxyText.trim();
    if (!this.useBookbarnProxy && proxy.length > 0 &&
      !(proxy.startsWith('http://') || proxy.startsWith('https://'))) {
      this.testResult = '代理地址需以 http:// 或 https:// 开头';
      return;
    }
    this.testing = true;
    this.testResult = '';
    try {
      const options: AudioTestOptions = {
        proxy: proxy,
        useBookbarnProxy: this.useBookbarnProxy,
      };
      const rsp: AdminApiResult = await AdminImportApi.testAudioConnection(options);
      if (!AdminImportApi.isOk(rsp)) {
        this.testResult = AdminImportApi.errorText(rsp).length > 0 ?
          AdminImportApi.errorText(rsp) : '音频服务连接测试失败';
        return;
      }
      this.testResult = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '音频服务连接测试成功';
      this.toast(this.testResult);
    } catch (e) {
      this.testResult = `测试失败：${e}`;
    } finally {
      this.testing = false;
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '有声书导入',
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
    if (this.gated) {
      EmptyState({
        message: `当前服务端（${ServerRegistry.profile().displayName}）不支持有声书导入`,
      });
    } else if (this.loading) {
      LoadingState({});
    } else {
      Scroll() {
        Column({ space: 12 }) {
          Text('扫描服务端有声书目录并导入书库，任务在服务器后台执行。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13)
              .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
              .width('100%');
          }

          SectionTitle({ title: '导入任务' });
          Column({ space: 10 }) {
            PrimaryButton({
              label: this.busy ? '提交中…' : (this.running ? '导入进行中…' : '开始有声书导入'),
              buttonEnabled: !this.busy && !this.running,
              onTap: () => {
                void this.startImport();
              },
            });
            SecondaryButton({
              label: '刷新状态',
              buttonEnabled: !this.running,
              onTap: () => {
                void this.refreshStatus(false);
              },
            });
          }
          .width('100%')
          .padding($r('app.float.card_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          SectionTitle({ title: '任务进度' });
          Column({ space: 8 }) {
            Text(`总数 ${this.total} · 新增 ${this.imported} · 已存在 ${this.exist} · 跳过 ${this.skipped}`)
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .width('100%');

            if (this.total > 0) {
              Progress({
                value: this.imported + this.exist + this.skipped,
                total: this.total,
                type: ProgressType.Linear,
              })
                .width('100%');
            }
            if (this.scanTotal > 0) {
              Text(`扫描库：已处理 ${this.scanDone} · 待处理 ${this.scanTodo} · 共 ${this.scanTotal}`)
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%');
            }
            if (this.statusHint.length > 0) {
              Text(this.statusHint)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%');
            }
          }
          .width('100%')
          .padding($r('app.float.card_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          SectionTitle({ title: '音频服务连通性' });
          Column({ space: 10 }) {
            SettingCell({
              title: '经由书栈代理测试',
              subtitle: '开启后由服务端走书栈代理，无需自行填写代理地址',
              showToggle: true,
              toggleOn: this.useBookbarnProxy,
              onToggle: (value: boolean) => {
                this.useBookbarnProxy = value;
              },
            });

            if (!this.useBookbarnProxy) {
              TextInput({ placeholder: '代理地址（可留空直连）', text: this.proxyText })
                .height(40)
                .borderRadius(8)
                .backgroundColor($r('app.color.page_background'))
                .onChange((value: string) => {
                  this.proxyText = value;
                });
            }

            PrimaryButton({
              label: this.testing ? '测试中…' : '测试音频服务连通性',
              buttonEnabled: !this.testing,
              onTap: () => {
                void this.testConnection();
              },
            });
            if (this.testResult.length > 0) {
              Text(this.testResult)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%');
            }
          }
          .width('100%')
          .padding($r('app.float.card_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));
        }
        .padding({ left: 16, right: 16, top: 4, bottom: 24 })
        .width('100%');
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off);
    }
  }
}
