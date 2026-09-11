import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import {
  PageScaffold, PrimaryButton, SecondaryButton, SettingCell, LoadingState
} from '../components';
import {
  TalebookApi, ApiMessageResult, apiErrorMessage,
  ToolboxDataResponse, ToolboxTaskProgressResponse
} from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';
import { BookUploadService } from '../services/BookUploadService';

@Entry
@Component
struct MinifyPdfToolPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State progressHint: string = '';
  @State processing: boolean = false;

  @State uploadedFilename: string = '';
  @State uploadInfo: string = '';
  @State mode: string = 'color'; // color | gray | bw
  @State maxWidthText: string = '1200';
  @State qualifyText: string = '50';
  @State maxBrightnessText: string = '200';
  @State skipPages: string = '';
  @State dropPages: string = '';
  @State autoContrast: boolean = true;
  @State downloadPath: string = '';

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
    if (!this.processing || this.uploadedFilename.length === 0) {
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
    } finally {
      this.loading = false;
    }
  }

  private cycleMode(): void {
    if (this.mode === 'color') {
      this.mode = 'gray';
    } else if (this.mode === 'gray') {
      this.mode = 'bw';
    } else {
      this.mode = 'color';
    }
  }

  private modeLabel(): string {
    if (this.mode === 'gray') {
      return '灰度 gray';
    }
    if (this.mode === 'bw') {
      return '黑白 bw';
    }
    return '彩色 color';
  }

  private buildParams(): Record<string, Object> {
    const params: Record<string, Object> = {
      'bw': this.mode === 'bw',
      'gray': this.mode === 'gray',
      'auto': this.autoContrast,
    };
    const maxWidth = Number(this.maxWidthText.trim());
    if (maxWidth > 0) {
      params['max_width'] = maxWidth;
    }
    const qualify = Number(this.qualifyText.trim());
    if (qualify > 0) {
      params['qualify'] = qualify;
    }
    if (this.skipPages.trim().length > 0) {
      params['skip_pages'] = this.skipPages.trim();
    }
    if (this.dropPages.trim().length > 0) {
      params['drop_pages'] = this.dropPages.trim();
    }
    if (this.mode === 'gray') {
      const bright = Number(this.maxBrightnessText.trim());
      if (bright > 0) {
        params['max_brightness'] = bright;
      }
    }
    return params;
  }

  private async pickAndUpload(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const picked = await BookUploadService.pickPdfFile(context);
      if (picked === null) {
        this.toast('未选择 PDF');
        return;
      }
      const rsp: ToolboxDataResponse = await TalebookApi.minifyPdfUpload(picked.localPath, picked.name);
      BookUploadService.removeStagedFile(picked.localPath);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '上传失败', true);
        return;
      }
      const data = rsp.data;
      let filename = picked.name;
      if (data !== undefined) {
        const f = String(data['filename'] ?? '');
        if (f.length > 0) {
          filename = f;
        }
        const pages = data['page_count'];
        const size = data['file_size'];
        const bits: string[] = [];
        if (pages !== undefined) {
          bits.push(`页数 ${pages}`);
        }
        if (size !== undefined) {
          bits.push(BookUploadService.formatSize(Number(size)));
        }
        this.uploadInfo = bits.length > 0 ? bits.join(' · ') : '已上传';
      } else {
        this.uploadInfo = '已上传';
      }
      this.uploadedFilename = filename;
      this.downloadPath = '';
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : `已上传 ${filename}`, false);
      this.toast(this.message);
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async startProcess(): Promise<void> {
    if (this.busy || this.processing) {
      return;
    }
    if (this.uploadedFilename.length === 0) {
      this.setMsg('请先上传 PDF', true);
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.minifyPdfProcess(
        this.uploadedFilename, this.buildParams());
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '启动压缩失败', true);
        return;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已开始压缩', false);
      this.processing = true;
      this.schedulePoll();
      await this.refreshProgress(false);
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async refreshProgress(fromPoll: boolean): Promise<void> {
    if (this.uploadedFilename.length === 0) {
      return;
    }
    try {
      const rsp: ToolboxTaskProgressResponse =
        await TalebookApi.minifyPdfProgress(this.uploadedFilename);
      const data = rsp.data;
      const status = data !== undefined ? String(data['status'] ?? '') : '';
      const percentRaw = data !== undefined ? data['percent'] : undefined;
      const percent = percentRaw !== undefined ? Number(percentRaw) : -1;
      const msg = data !== undefined ? String(data['message'] ?? data['msg'] ?? '') :
        (rsp.msg !== undefined ? rsp.msg : '');
      const running = status === 'running' || status === 'pending' || status === 'processing' ||
        (percent >= 0 && percent < 100 && status !== 'done' && status !== 'finished' &&
          status !== 'success' && status !== 'failed' && status !== 'error' && status.length > 0);

      if (rsp.err !== undefined && rsp.err !== 'ok' && !running) {
        this.progressHint = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '';
        this.processing = false;
        this.stopPoll();
        return;
      }

      const pct = percent >= 0 ? ` ${percent}%` : '';
      this.progressHint = (msg.length > 0 ? msg : (status.length > 0 ? status : '无进行中任务')) + pct;

      if (running) {
        this.processing = true;
        this.schedulePoll();
        return;
      }

      if (fromPoll && this.processing) {
        this.setMsg(this.progressHint.length > 0 ? this.progressHint : '压缩已结束', false);
        this.downloadPath = TalebookApi.minifyPdfDownloadPath(this.uploadedFilename);
      }
      // 完成时也给出下载路径
      if (status === 'done' || status === 'finished' || status === 'success' || percent >= 100) {
        this.downloadPath = TalebookApi.minifyPdfDownloadPath(this.uploadedFilename);
      }
      this.processing = false;
      this.stopPoll();
    } catch (_e) {
      if (this.processing) {
        this.schedulePoll();
      }
    }
  }

  private clearUpload(): void {
    this.uploadedFilename = '';
    this.uploadInfo = '';
    this.downloadPath = '';
    this.progressHint = '';
    this.processing = false;
    this.stopPoll();
  }

  build() {
    Column() {
      PageScaffold({
        title: 'PDF 压缩',
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
          if (this.progressHint.length > 0 || this.processing) {
            Text(this.processing ? `进度：${this.progressHint}` : `上次：${this.progressHint}`)
              .fontSize(13)
              .fontColor($r('app.color.brand_primary'))
              .width('100%');
          }

          if (this.uploadedFilename.length === 0) {
            PrimaryButton({
              label: this.busy ? '上传中…' : '选择并上传 PDF',
              buttonEnabled: !this.busy,
              onTap: () => {
                void this.pickAndUpload();
              },
            });
          } else {
            Column({ space: 6 }) {
              Text(`已上传：${this.uploadedFilename}`)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .width('100%');
              if (this.uploadInfo.length > 0) {
                Text(this.uploadInfo)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%');
              }
              SecondaryButton({
                label: '重新选择',
                buttonEnabled: !this.busy && !this.processing,
                onTap: () => {
                  this.clearUpload();
                },
              });
            }
            .width('100%')
            .padding(12)
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));

            Column() {
              SettingCell({
                title: '压缩模式',
                subtitle: this.modeLabel(),
                showChevron: true,
                onTap: () => {
                  this.cycleMode();
                },
              });
              SettingCell({
                title: '自动对比度',
                showToggle: true,
                toggleOn: this.autoContrast,
                onToggle: (v: boolean) => {
                  this.autoContrast = v;
                },
              });
            }
            .width('100%')
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));

            Column({ space: 10 }) {
              TextInput({ placeholder: '最大宽度 max_width', text: this.maxWidthText })
                .height(40)
                .borderRadius(8)
                .backgroundColor($r('app.color.page_background'))
                .onChange((v: string) => {
                  this.maxWidthText = v;
                });
              TextInput({ placeholder: '质量 qualify', text: this.qualifyText })
                .height(40)
                .borderRadius(8)
                .backgroundColor($r('app.color.page_background'))
                .onChange((v: string) => {
                  this.qualifyText = v;
                });
              if (this.mode === 'gray') {
                TextInput({ placeholder: '最大亮度 max_brightness', text: this.maxBrightnessText })
                  .height(40)
                  .borderRadius(8)
                  .backgroundColor($r('app.color.page_background'))
                  .onChange((v: string) => {
                    this.maxBrightnessText = v;
                  });
              }
              TextInput({ placeholder: '跳过页 skip_pages（可选）', text: this.skipPages })
                .height(40)
                .borderRadius(8)
                .backgroundColor($r('app.color.page_background'))
                .onChange((v: string) => {
                  this.skipPages = v;
                });
              TextInput({ placeholder: '丢弃页 drop_pages（可选）', text: this.dropPages })
                .height(40)
                .borderRadius(8)
                .backgroundColor($r('app.color.page_background'))
                .onChange((v: string) => {
                  this.dropPages = v;
                });
            }
            .width('100%')
            .padding(12)
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));

            PrimaryButton({
              label: this.busy ? '处理中…' : (this.processing ? '压缩进行中…' : '开始压缩'),
              buttonEnabled: !this.busy && !this.processing,
              onTap: () => {
                void this.startProcess();
              },
            });
            SecondaryButton({
              label: '刷新进度',
              buttonEnabled: !this.busy && this.uploadedFilename.length > 0,
              onTap: () => {
                void this.refreshProgress(false);
              },
            });

            if (this.downloadPath.length > 0) {
              Column({ space: 6 }) {
                Text('下载路径（相对服务器）')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%');
                Text(this.downloadPath)
                  .fontSize(12)
                  .fontColor($r('app.color.brand_primary'))
                  .width('100%');
                SecondaryButton({
                  label: '复制路径到提示',
                  buttonEnabled: true,
                  onTap: () => {
                    this.toast(this.downloadPath);
                  },
                });
              }
              .width('100%')
              .padding(12)
              .borderRadius($r('app.float.card_radius'))
              .backgroundColor($r('app.color.card_background'));
            }
          }
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
