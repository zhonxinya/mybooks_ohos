import { common } from '@kit.AbilityKit';
import {
  PageScaffold, PrimaryButton, SecondaryButton, DangerButton,
  LoadingState, EmptyState, SettingCell, FilterChips, FilterChipItem
} from '../components';
import {
  TalebookApi, ApiMessageResult, apiErrorMessage,
  EpubBeautifyRunOptions, ToolboxTaskProgressResponse, ToolboxDataResponse
} from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';
import { BookUploadService } from '../services/BookUploadService';

const TAB_RUN: number = 0;
const TAB_BG: number = 1;

@Entry
@Component
struct EpubBeautifyToolPage {
  @State selectedTab: number = TAB_RUN;
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State progressHint: string = '';
  @State running: boolean = false;
  @State previewHint: string = '';

  @State bookIdsText: string = '';
  @State preset: string = 'classic';
  @State tocStyle: string = 'elegant';
  @State suffix: string = '';
  @State paraMode: string = '';
  @State noteMark: string = '';
  @State pageTint: string = 'auto';
  @State useSystemFonts: boolean = false;
  @State dialogue: boolean = false;
  @State titleSplit: boolean = false;
  @State notes: boolean = false;
  @State bgImage: boolean = false;
  @State tocColumns: boolean = false;
  @State paraIndent: boolean = true;

  @State bgMetaHint: string = '';
  @State bgHas: boolean = false;
  @State builtinId: string = '';
  @State presetHints: string = 'classic / modern / webnovel / classical / youth / children / refined / xuanzhi / inkstone / voyage / navy / vertclassical';
  @State tocHints: string = 'elegant / cool / minimal / seal';

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
      await this.loadBgMeta();
    } finally {
      this.loading = false;
    }
  }

  private parseBookIds(): number[] {
    const raw = this.bookIdsText.replace(/，/g, ',');
    const parts = raw.split(/[,\s]+/);
    const ids: number[] = [];
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i].trim();
      if (p.length === 0) {
        continue;
      }
      const n = Number(p);
      if (n > 0) {
        ids.push(n);
      }
    }
    return ids;
  }

  private buildOptions(): EpubBeautifyRunOptions {
    const opt: EpubBeautifyRunOptions = {
      preset: this.preset.trim().length > 0 ? this.preset.trim() : 'classic',
      tocStyle: this.tocStyle.trim().length > 0 ? this.tocStyle.trim() : 'elegant',
      useSystemFonts: this.useSystemFonts,
      dialogue: this.dialogue,
      titleSplit: this.titleSplit,
      notes: this.notes,
      bgImage: this.bgImage,
      tocColumns: this.tocColumns,
      paraIndent: this.paraIndent,
    };
    if (this.suffix.trim().length > 0) {
      opt.suffix = this.suffix.trim();
    }
    if (this.paraMode.trim().length > 0) {
      opt.paraMode = this.paraMode.trim();
    }
    if (this.noteMark.trim().length > 0) {
      opt.noteMark = this.noteMark.trim();
    }
    if (this.pageTint === 'auto') {
      // 不传，交给服务端默认
    } else if (this.pageTint === 'on') {
      opt.pageTint = true;
    } else if (this.pageTint === 'off') {
      opt.pageTint = false;
    } else if (this.pageTint.trim().length > 0) {
      opt.pageTint = this.pageTint.trim();
    }
    return opt;
  }

  private async runPreview(): Promise<void> {
    if (this.busy) {
      return;
    }
    const ids = this.parseBookIds();
    if (ids.length === 0) {
      this.setMsg('请先填写至少一个书籍 ID', true);
      return;
    }
    this.busy = true;
    try {
      const rsp: ToolboxDataResponse = await TalebookApi.epubBeautifyPreview(ids[0]);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '预览失败', true);
        return;
      }
      const data = rsp.data;
      let hint = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '预览完成';
      if (data !== undefined) {
        const presets = data['presets'];
        if (Array.isArray(presets)) {
          const names: string[] = [];
          for (let i = 0; i < presets.length; i++) {
            const item = presets[i] as Record<string, Object>;
            const id = String(item['id'] ?? item['name'] ?? '');
            if (id.length > 0) {
              names.push(id);
            }
          }
          if (names.length > 0) {
            this.presetHints = names.join(' / ');
            hint = `${hint}；可用预设 ${names.length} 个`;
          }
        }
      }
      this.previewHint = hint;
      this.setMsg(hint, false);
      this.toast(hint);
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async runBeautify(): Promise<void> {
    if (this.busy || this.running) {
      return;
    }
    const ids = this.parseBookIds();
    if (ids.length === 0) {
      this.setMsg('请填写书籍 ID（多个用逗号分隔）', true);
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.epubBeautifyRun(ids, this.buildOptions());
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '启动失败', true);
        return;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已开始美化', false);
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
      const rsp: ToolboxTaskProgressResponse = await TalebookApi.epubBeautifyProgress();
      const data = rsp.data;
      const status = data !== undefined ? String(data['status'] ?? '') : '';
      const percentRaw = data !== undefined ? data['percent'] : undefined;
      const percent = percentRaw !== undefined ? Number(percentRaw) : -1;
      const msg = data !== undefined ? String(data['message'] ?? data['msg'] ?? '') :
        (rsp.msg !== undefined ? rsp.msg : '');
      const isRunning = status === 'running' || status === 'pending' || status === 'converting' ||
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
        this.setMsg(this.progressHint.length > 0 ? this.progressHint : '美化已结束', false);
      }
      this.running = false;
      this.stopPoll();
    } catch (_e) {
      if (this.running) {
        this.schedulePoll();
      }
    }
  }

  private async loadBgMeta(): Promise<void> {
    try {
      const rsp: ToolboxDataResponse = await TalebookApi.epubBeautifyBgMeta();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.bgMetaHint = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '无背景图';
        this.bgHas = false;
        return;
      }
      const data = rsp.data;
      const has = data !== undefined && (Boolean(data['has_bg']) || Boolean(data['exists']) ||
        String(data['filename'] ?? '').length > 0 || String(data['path'] ?? '').length > 0);
      this.bgHas = has;
      if (data !== undefined) {
        const name = String(data['filename'] ?? data['name'] ?? data['path'] ?? '');
        this.bgMetaHint = has
          ? (name.length > 0 ? `当前背景：${name}` : '已设置背景图')
          : (rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '尚未设置背景图');
      } else {
        this.bgMetaHint = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '尚未设置背景图';
        this.bgHas = false;
      }
    } catch (e) {
      this.bgMetaHint = `查询背景失败：${e}`;
      this.bgHas = false;
    }
  }

  private async uploadBgFile(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const picked = await BookUploadService.pickAvatarImage(context);
      if (picked === null) {
        this.toast('未选择图片');
        return;
      }
      const rsp: ToolboxDataResponse = await TalebookApi.epubBeautifyBgUpload(picked.localPath, picked.name);
      BookUploadService.removeStagedFile(picked.localPath);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '上传失败');
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '背景图已上传');
      this.bgImage = true;
      await this.loadBgMeta();
    } catch (e) {
      this.toast(`上传失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  private async uploadBuiltinBg(): Promise<void> {
    if (this.busy) {
      return;
    }
    const id = this.builtinId.trim();
    if (id.length === 0) {
      this.toast('请填写内置背景 ID');
      return;
    }
    this.busy = true;
    try {
      const rsp: ToolboxDataResponse = await TalebookApi.epubBeautifyBgUploadBuiltin(id);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '应用内置背景失败');
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已应用内置背景');
      this.bgImage = true;
      await this.loadBgMeta();
    } catch (e) {
      this.toast(`应用失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  private async deleteBg(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.epubBeautifyBgDelete();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '删除失败');
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已删除背景图');
      this.bgImage = false;
      await this.loadBgMeta();
    } catch (e) {
      this.toast(`删除失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: 'EPUB 美化',
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
      Column() {
        FilterChips({
          items: [
            { label: '运行', value: TAB_RUN },
            { label: '背景图', value: TAB_BG },
          ] as FilterChipItem[],
          selected: $selectedTab,
          onChange: (value: number) => {
            this.selectedTab = value;
          },
        });

        if (this.message.length > 0) {
          Text(this.message)
            .fontSize(13)
            .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 4 });
        }

        if (this.selectedTab === TAB_RUN) {
          this.runTab();
        } else {
          this.bgTab();
        }
      }
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  runTab() {
    Scroll() {
      Column({ space: 12 }) {
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
          TextInput({ placeholder: '书籍 ID（多个用逗号分隔）', text: this.bookIdsText })
            .height(40)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((v: string) => {
              this.bookIdsText = v;
            });
          Text(`预设：${this.presetHints}`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%');
          TextInput({ placeholder: '预设 preset', text: this.preset })
            .height(40)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((v: string) => {
              this.preset = v;
            });
          Text(`目录样式：${this.tocHints}`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%');
          TextInput({ placeholder: '目录样式 toc_style', text: this.tocStyle })
            .height(40)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((v: string) => {
              this.tocStyle = v;
            });
          TextInput({ placeholder: '输出后缀 suffix（可选）', text: this.suffix })
            .height(40)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((v: string) => {
              this.suffix = v;
            });
          TextInput({ placeholder: '段落模式 para_mode（可选）', text: this.paraMode })
            .height(40)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((v: string) => {
              this.paraMode = v;
            });
          TextInput({ placeholder: '纸色 page_tint：auto / on / off', text: this.pageTint })
            .height(40)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((v: string) => {
              this.pageTint = v;
            });
          TextInput({ placeholder: '注记标记 note_mark（可选）', text: this.noteMark })
            .height(40)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((v: string) => {
              this.noteMark = v;
            });
        }
        .width('100%')
        .padding(12)
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));

        Column() {
          SettingCell({
            title: '使用系统字体',
            showToggle: true,
            toggleOn: this.useSystemFonts,
            onToggle: (v: boolean) => {
              this.useSystemFonts = v;
            },
          });
          SettingCell({
            title: '对话样式',
            showToggle: true,
            toggleOn: this.dialogue,
            onToggle: (v: boolean) => {
              this.dialogue = v;
            },
          });
          SettingCell({
            title: '标题拆分',
            showToggle: true,
            toggleOn: this.titleSplit,
            onToggle: (v: boolean) => {
              this.titleSplit = v;
            },
          });
          SettingCell({
            title: '脚注/注记',
            showToggle: true,
            toggleOn: this.notes,
            onToggle: (v: boolean) => {
              this.notes = v;
            },
          });
          SettingCell({
            title: '启用背景图',
            showToggle: true,
            toggleOn: this.bgImage,
            onToggle: (v: boolean) => {
              this.bgImage = v;
            },
          });
          SettingCell({
            title: '目录双栏',
            showToggle: true,
            toggleOn: this.tocColumns,
            onToggle: (v: boolean) => {
              this.tocColumns = v;
            },
          });
          SettingCell({
            title: '段落缩进',
            showToggle: true,
            toggleOn: this.paraIndent,
            onToggle: (v: boolean) => {
              this.paraIndent = v;
            },
          });
        }
        .width('100%')
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));

        PrimaryButton({
          label: this.busy ? '处理中…' : (this.running ? '美化进行中…' : '开始美化'),
          buttonEnabled: !this.busy && !this.running,
          onTap: () => {
            void this.runBeautify();
          },
        });
        SecondaryButton({
          label: '预览分析（首个书籍 ID）',
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.runPreview();
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
      .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      .width('100%');
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off);
  }

  @Builder
  bgTab() {
    Scroll() {
      Column({ space: 12 }) {
        Text(this.bgMetaHint.length > 0 ? this.bgMetaHint : '背景图用于美化排版')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        Text(`原始路径：${TalebookApi.epubBeautifyBgRawPath()}`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');

        PrimaryButton({
          label: this.busy ? '处理中…' : '上传自定义背景图',
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.uploadBgFile();
          },
        });

        Column({ space: 10 }) {
          TextInput({ placeholder: '内置背景 ID', text: this.builtinId })
            .height(40)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((v: string) => {
              this.builtinId = v;
            });
          SecondaryButton({
            label: '应用内置背景',
            buttonEnabled: !this.busy,
            onTap: () => {
              void this.uploadBuiltinBg();
            },
          });
        }
        .width('100%')
        .padding(12)
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));

        SecondaryButton({
          label: '刷新背景信息',
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.loadBgMeta();
          },
        });

        if (this.bgHas) {
          DangerButton({
            label: '删除背景图',
            buttonEnabled: !this.busy,
            onTap: () => {
              void this.deleteBg();
            },
          });
        } else {
          EmptyState({ message: '当前没有背景图' });
        }
      }
      .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      .width('100%');
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off);
  }
}
