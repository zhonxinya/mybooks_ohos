import { common } from '@kit.AbilityKit';
import {
  PageScaffold, LoadingState, EmptyState, SectionTitle, PrimaryButton, SecondaryButton
} from '../components';
import {
  AdminImportApi, BatchAddRunResponse, BatchAddStatusResponse
} from '../services/AdminImportApi';
import { BookUploadService, PickedBookFile } from '../services/BookUploadService';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';

/** 状态轮询间隔（与导入管理页保持一致） */
const POLL_INTERVAL_MS: number = 3000;

/**
 * 批量添加实体书（mybooks 专有）：选择 CSV → POST /api/admin/batch_add/run → 轮询 /api/admin/batch_add/status。
 * CSV 须含 `isbn` 字段，且以 Tab 作为分隔符（上游 BatchAddRun 校验）。
 */
@Entry
@Component
struct AdminBatchAddPage {
  @State loading: boolean = true;
  @State picking: boolean = false;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State fileName: string = '';
  @State filePath: string = '';
  @State running: boolean = false;
  @State total: number = 0;
  @State processed: number = 0;
  @State success: number = 0;
  @State failed: number = 0;
  @State invalid: number = 0;
  @State scanTotal: number = 0;
  @State scanDone: number = 0;
  @State scanTodo: number = 0;
  @State statusHint: string = '';
  private gated: boolean = !ServerRegistry.supports(ServerFeature.ADMIN_BATCH_ADD);
  private pollTimer: number = -1;

  aboutToAppear(): void {
    void this.bootstrap();
  }

  aboutToDisappear(): void {
    this.stopPoll();
    if (this.filePath.length > 0) {
      BookUploadService.removeStagedFile(this.filePath);
    }
  }

  private toast(text: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: text });
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

  private async pickCsv(): Promise<void> {
    if (this.picking || this.running) {
      return;
    }
    this.picking = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const file: PickedBookFile | null =
        await BookUploadService.pickStagedFile(context, ['.csv'], 'batch_add_csv');
      if (file === null) {
        return;
      }
      if (this.filePath.length > 0) {
        BookUploadService.removeStagedFile(this.filePath);
      }
      this.fileName = file.name;
      this.filePath = file.localPath;
      this.setMsg('', false);
    } catch (e) {
      this.setMsg(`选择文件失败：${e}`, true);
    } finally {
      this.picking = false;
    }
  }

  private async startRun(): Promise<void> {
    if (this.busy || this.running) {
      return;
    }
    if (this.filePath.length === 0) {
      this.setMsg('请先选择 CSV 文件', true);
      return;
    }
    this.busy = true;
    try {
      const rsp: BatchAddRunResponse =
        await AdminImportApi.runBatchAdd(this.filePath, this.fileName);
      if (!AdminImportApi.isOk(rsp)) {
        this.setMsg(AdminImportApi.errorText(rsp).length > 0 ?
          AdminImportApi.errorText(rsp) : '启动批量添加失败', true);
        return;
      }
      this.total = rsp.total !== undefined ? rsp.total : 0;
      this.processed = 0;
      this.success = 0;
      this.failed = 0;
      this.invalid = 0;
      this.statusHint = '任务已提交，等待服务端处理…';
      this.setMsg(`已开始批量添加，共 ${this.total} 条`, false);
      this.toast('已开始批量添加');
      // 服务端已保存临时 CSV，本地暂存文件可释放
      BookUploadService.removeStagedFile(this.filePath);
      this.filePath = '';
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
      const rsp: BatchAddStatusResponse = await AdminImportApi.getBatchAddStatus();
      if (!AdminImportApi.isOk(rsp)) {
        this.statusHint = AdminImportApi.errorText(rsp).length > 0 ?
          AdminImportApi.errorText(rsp) : '状态获取失败';
        return;
      }
      const wasRunning = this.running;
      this.running = rsp.batch_adding === true;
      const status = rsp.status;
      if (status !== undefined) {
        this.total = status.total !== undefined ? status.total : 0;
        this.processed = status.processed !== undefined ? status.processed : 0;
        this.success = status.success !== undefined ? status.success : 0;
        this.failed = status.failed !== undefined ? status.failed : 0;
        this.invalid = status.invalid !== undefined ? status.invalid : 0;
      }
      const summary = rsp.summary;
      if (summary !== undefined) {
        this.scanTotal = summary.total !== undefined ? summary.total : 0;
        this.scanDone = summary.done !== undefined ? summary.done : 0;
        this.scanTodo = summary.todo !== undefined ? summary.todo : 0;
      }
      if (this.running) {
        this.statusHint = `处理中 ${this.processed}/${this.total}`;
      } else if (wasRunning) {
        this.statusHint = `任务已结束：成功 ${this.success}，失败 ${this.failed}，无效 ${this.invalid}`;
        this.toast('批量添加任务已结束');
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

  build() {
    Column() {
      PageScaffold({
        title: '批量添加实体书',
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
        message: `当前服务端（${ServerRegistry.profile().displayName}）不支持批量添加实体书`,
      });
    } else if (this.loading) {
      LoadingState({});
    } else {
      Scroll() {
        Column({ space: 12 }) {
          Text('从 CSV 批量添加实体书。CSV 需包含 isbn 字段，且以 Tab 作为分隔符。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13)
              .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
              .width('100%');
          }

          SectionTitle({ title: 'CSV 文件' });
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.doc_text'))
                .fontSize(20)
                .fontColor([$r('app.color.brand_primary')]);
              Text(this.fileName.length > 0 ? this.fileName : '尚未选择文件')
                .fontSize(14)
                .fontColor(this.fileName.length > 0 ?
                  $r('app.color.text_primary') : $r('app.color.text_tertiary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1);
            }
            .width('100%');

            SecondaryButton({
              label: this.picking ? '选择中…' : '选择 CSV 文件',
              buttonEnabled: !this.picking && !this.running,
              onTap: () => {
                void this.pickCsv();
              },
            });
            PrimaryButton({
              label: this.busy ? '提交中…' : '开始批量添加',
              buttonEnabled: !this.busy && !this.running && this.filePath.length > 0,
              onTap: () => {
                void this.startRun();
              },
            });
          }
          .width('100%')
          .padding($r('app.float.card_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          SectionTitle({ title: '任务进度' });
          Column({ space: 8 }) {
            Text(`总数 ${this.total} · 已处理 ${this.processed} · 成功 ${this.success}`
              + ` · 失败 ${this.failed} · 无效 ${this.invalid}`)
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .width('100%');

            if (this.total > 0) {
              Progress({ value: this.processed, total: this.total, type: ProgressType.Linear })
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

            SecondaryButton({
              label: this.running ? '正在轮询状态…' : '刷新状态',
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
