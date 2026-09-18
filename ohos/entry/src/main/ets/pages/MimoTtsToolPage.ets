import { common } from '@kit.AbilityKit';
import {
  PageScaffold, PrimaryButton, SecondaryButton, DangerButton,
  LoadingState, EmptyState, FilterChips, FilterChipItem, TextButton, BookIdPicker
} from '../components';
import {
  TalebookApi, ApiMessageResult, apiErrorMessage,
  MimoTtsConvertRequest, MimoTtsTestRequest, MimoTtsConfigResponse,
  MimoTtsClonesResponse, MimoTtsPromptsResponse, ToolboxTaskProgressResponse
} from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';
import { BookUploadService, PickedBookFile } from '../services/BookUploadService';

const TAB_CONVERT: number = 0;
const TAB_CLONES: number = 1;
const TAB_PROMPTS: number = 2;

const DEFAULT_API_URL: string = 'https://api.xiaomimimo.com/v1/chat/completions';
const DEFAULT_MODEL: string = 'mimo-v2.5-tts';
const DEFAULT_API_TYPE: string = 'chat_completions';
const DEFAULT_AUTH: string = 'api-key';

@Entry
@Component
struct MimoTtsToolPage {
  @State selectedTab: number = TAB_CONVERT;
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;
  @State progressHint: string = '';
  @State converting: boolean = false;

  @State bookIdText: string = '';
  @State apiKey: string = '';
  @State apiUrl: string = DEFAULT_API_URL;
  @State modelName: string = DEFAULT_MODEL;
  @State apiType: string = DEFAULT_API_TYPE;
  @State voiceName: string = 'mimo_default';
  @State authType: string = DEFAULT_AUTH;
  @State voiceDesc: string = '';
  @State cloneVoice: string = '';
  @State cloneUploadName: string = '';
  @State clonePickedHint: string = '';
  private clonePicked: PickedBookFile | null = null;

  @State clones: Record<string, Object>[] = [];
  @State prompts: Record<string, Object>[] = [];
  @State promptName: string = '';
  @State promptDesc: string = '';
  @State configHint: string = '';

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
      await this.loadConfig();
      await this.refreshProgress(false);
      await this.loadClones();
      await this.loadPrompts();
    } finally {
      this.loading = false;
    }
  }

  private cfgStr(cfg: Record<string, Object> | null | undefined, key: string, fallback: string): string {
    if (cfg === undefined || cfg === null) {
      return fallback;
    }
    const v = cfg[key];
    if (v === undefined || v === null) {
      return fallback;
    }
    const s = String(v);
    return s.length > 0 ? s : fallback;
  }

  private async loadConfig(): Promise<void> {
    try {
      const rsp: MimoTtsConfigResponse = await TalebookApi.mimoTtsGetConfig();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.configHint = apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '无已保存配置';
        return;
      }
      const cfg = rsp.config;
      this.apiKey = this.cfgStr(cfg, 'api_key', this.apiKey);
      this.apiUrl = this.cfgStr(cfg, 'api_url', DEFAULT_API_URL);
      this.modelName = this.cfgStr(cfg, 'model_name', DEFAULT_MODEL);
      this.apiType = this.cfgStr(cfg, 'api_type', DEFAULT_API_TYPE);
      this.voiceName = this.cfgStr(cfg, 'voice_name', this.voiceName);
      this.authType = this.cfgStr(cfg, 'auth_type', DEFAULT_AUTH);
      this.voiceDesc = this.cfgStr(cfg, 'voice_desc', '');
      this.cloneVoice = this.cfgStr(cfg, 'clone_voice', '');
      this.configHint = '已载入服务器保存的配置';
    } catch (e) {
      this.configHint = `载入配置失败：${e}`;
    }
  }

  private async deleteConfig(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.mimoTtsDeleteConfig();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '删除配置失败');
        return;
      }
      this.apiKey = '';
      this.configHint = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已清除保存的配置';
      this.toast(this.configHint);
    } catch (e) {
      this.toast(`删除配置失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  private buildTestReq(): MimoTtsTestRequest {
    const req: MimoTtsTestRequest = {
      apiKey: this.apiKey.trim(),
    };
    if (this.voiceDesc.trim().length > 0) {
      req.voiceDesc = this.voiceDesc.trim();
    }
    if (this.apiUrl.trim().length > 0) {
      req.apiUrl = this.apiUrl.trim();
    }
    if (this.modelName.trim().length > 0) {
      req.modelName = this.modelName.trim();
    }
    if (this.apiType.trim().length > 0) {
      req.apiType = this.apiType.trim();
    }
    if (this.voiceName.trim().length > 0) {
      req.voiceName = this.voiceName.trim();
    }
    if (this.authType.trim().length > 0) {
      req.authType = this.authType.trim();
    }
    if (this.cloneVoice.trim().length > 0) {
      req.cloneVoice = this.cloneVoice.trim();
    }
    return req;
  }

  private async runTest(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.apiKey.trim().length === 0) {
      this.setMsg('请填写 API Key', true);
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.mimoTtsTest(this.buildTestReq());
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '测试失败', true);
        return;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '测试成功', false);
      this.toast(this.message);
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async runConvert(): Promise<void> {
    if (this.busy) {
      return;
    }
    const bookId = Number(this.bookIdText.trim());
    if (!(bookId > 0)) {
      this.setMsg('请填写有效的书籍 ID', true);
      return;
    }
    if (this.apiKey.trim().length === 0) {
      this.setMsg('请填写 API Key', true);
      return;
    }
    this.busy = true;
    try {
      const req: MimoTtsConvertRequest = {
        bookId: bookId,
        apiKey: this.apiKey.trim(),
      };
      if (this.voiceDesc.trim().length > 0) {
        req.voiceDesc = this.voiceDesc.trim();
      }
      if (this.apiUrl.trim().length > 0) {
        req.apiUrl = this.apiUrl.trim();
      }
      if (this.modelName.trim().length > 0) {
        req.modelName = this.modelName.trim();
      }
      if (this.apiType.trim().length > 0) {
        req.apiType = this.apiType.trim();
      }
      if (this.voiceName.trim().length > 0) {
        req.voiceName = this.voiceName.trim();
      }
      if (this.authType.trim().length > 0) {
        req.authType = this.authType.trim();
      }
      if (this.cloneVoice.trim().length > 0) {
        req.cloneVoice = this.cloneVoice.trim();
      }
      const rsp: ApiMessageResult = await TalebookApi.mimoTtsConvert(req);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '启动转换失败', true);
        return;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已开始转换', false);
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
      const rsp: ToolboxTaskProgressResponse = await TalebookApi.mimoTtsProgress();
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
    } catch (e) {
      if (!fromPoll) {
        this.progressHint = '';
      }
      if (this.converting) {
        this.schedulePoll();
      }
    }
  }

  private async loadClones(): Promise<void> {
    try {
      const rsp: MimoTtsClonesResponse = await TalebookApi.mimoTtsCloneList();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.clones = [];
        return;
      }
      this.clones = rsp.clones ?? [];
    } catch (_e) {
      this.clones = [];
    }
  }

  private async deleteClone(name: string): Promise<void> {
    if (this.busy || name.length === 0) {
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.mimoTtsCloneDelete(name);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '删除失败');
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已删除克隆音色');
      if (this.cloneVoice === name) {
        this.cloneVoice = '';
      }
      await this.loadClones();
    } catch (e) {
      this.toast(`删除失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  private async loadPrompts(): Promise<void> {
    try {
      const rsp: MimoTtsPromptsResponse = await TalebookApi.mimoTtsPromptList();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.prompts = [];
        return;
      }
      this.prompts = rsp.prompts ?? [];
    } catch (_e) {
      this.prompts = [];
    }
  }

  private async savePrompt(): Promise<void> {
    if (this.busy) {
      return;
    }
    const name = this.promptName.trim();
    const desc = this.promptDesc.trim();
    if (name.length === 0 || desc.length === 0) {
      this.toast('请填写提示词名称和内容');
      return;
    }
    this.busy = true;
    try {
      const rsp = await TalebookApi.mimoTtsPromptSave(name, desc);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '保存失败');
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已保存提示词');
      this.voiceDesc = desc;
      await this.loadPrompts();
    } catch (e) {
      this.toast(`保存失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  private async deletePrompt(name: string): Promise<void> {
    if (this.busy || name.length === 0) {
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.mimoTtsPromptDelete(name);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '删除失败');
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已删除提示词');
      await this.loadPrompts();
    } catch (e) {
      this.toast(`删除失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  private applyPrompt(item: Record<string, Object>): void {
    const name = String(item['name'] ?? '');
    const desc = String(item['desc'] ?? item['description'] ?? item['prompt'] ?? '');
    if (name.length > 0) {
      this.promptName = name;
    }
    if (desc.length > 0) {
      this.promptDesc = desc;
      this.voiceDesc = desc;
    }
    this.selectedTab = TAB_CONVERT;
    this.toast('已应用提示词到音色描述');
  }


  private async pickCloneAudio(): Promise<void> {
    if (this.busy) {
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const picked = await BookUploadService.pickAudioClone(context);
      if (picked === null) {
        this.toast('未选择文件，或格式/大小不符合（仅 mp3/wav，≤7MB）');
        this.clonePicked = null;
        this.clonePickedHint = '';
        return;
      }
      this.clonePicked = picked;
      this.clonePickedHint = `${picked.name} · ${BookUploadService.formatSize(picked.size)}`;
      if (this.cloneUploadName.trim().length === 0) {
        const base = picked.name;
        const dot = base.lastIndexOf('.');
        this.cloneUploadName = dot > 0 ? base.substring(0, dot) : base;
      }
    } catch (e) {
      this.toast(`选择文件失败：${e}`);
    }
  }

  private async uploadCloneAudio(): Promise<void> {
    if (this.busy) {
      return;
    }
    const voiceName = this.cloneUploadName.trim();
    if (voiceName.length === 0) {
      this.toast('请填写克隆音色名称');
      return;
    }
    if (this.clonePicked === null) {
      this.toast('请先选择音频文件');
      return;
    }
    const picked = this.clonePicked;
    this.busy = true;
    try {
      const rsp = await TalebookApi.mimoTtsCloneUpload(picked.localPath, picked.name, voiceName);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '上传失败');
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '克隆音色已上传');
      this.cloneVoice = voiceName;
      BookUploadService.removeStagedFile(picked.localPath);
      this.clonePicked = null;
      this.clonePickedHint = '';
      await this.loadClones();
    } catch (e) {
      this.toast(`上传失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  private useClone(name: string): void {
    this.cloneVoice = name;
    this.selectedTab = TAB_CONVERT;
    this.toast(`已选择克隆音色：${name}`);
  }

  build() {
    Column() {
      PageScaffold({
        title: 'Mimo TTS',
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
            { label: '转换', value: TAB_CONVERT },
            { label: '克隆音色', value: TAB_CLONES },
            { label: '提示词', value: TAB_PROMPTS },
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

        if (this.selectedTab === TAB_CONVERT) {
          this.convertTab();
        } else if (this.selectedTab === TAB_CLONES) {
          this.clonesTab();
        } else {
          this.promptsTab();
        }
      }
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  convertTab() {
    Scroll() {
      Column({ space: 12 }) {
        Text(this.configHint.length > 0 ? this.configHint : '填写 API 与音色参数')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        if (this.progressHint.length > 0 || this.converting) {
          Text(this.converting ? `进度：${this.progressHint}` : `上次：${this.progressHint}`)
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .width('100%');
        }

        Column({ space: 10 }) {
          BookIdPicker({ bookIdText: $bookIdText });
        TextInput({ placeholder: 'API Key', text: this.apiKey })
      .type(InputType.Password)
      .height(40)
      .borderRadius(8)
      .backgroundColor($r('app.color.page_background'))
      .onChange((v: string) => {
        this.apiKey = v;
      });
        TextInput({ placeholder: 'API URL', text: this.apiUrl })
      .height(40)
      .borderRadius(8)
      .backgroundColor($r('app.color.page_background'))
      .onChange((v: string) => {
        this.apiUrl = v;
      });
        TextInput({ placeholder: '模型 model_name', text: this.modelName })
      .height(40)
      .borderRadius(8)
      .backgroundColor($r('app.color.page_background'))
      .onChange((v: string) => {
        this.modelName = v;
      });
        TextInput({ placeholder: 'API 类型 (chat_completions / audio_speech)', text: this.apiType })
      .height(40)
      .borderRadius(8)
      .backgroundColor($r('app.color.page_background'))
      .onChange((v: string) => {
        this.apiType = v;
      });
        TextInput({ placeholder: '认证类型 (api-key / bearer)', text: this.authType })
      .height(40)
      .borderRadius(8)
      .backgroundColor($r('app.color.page_background'))
      .onChange((v: string) => {
        this.authType = v;
      });
        TextInput({ placeholder: '预设音色 voice_name', text: this.voiceName })
      .height(40)
      .borderRadius(8)
      .backgroundColor($r('app.color.page_background'))
      .onChange((v: string) => {
        this.voiceName = v;
      });
        TextInput({ placeholder: '克隆音色名 clone_voice（可选）', text: this.cloneVoice })
      .height(40)
      .borderRadius(8)
      .backgroundColor($r('app.color.page_background'))
      .onChange((v: string) => {
        this.cloneVoice = v;
      });
        TextInput({ placeholder: '音色描述 / 提示词 voice_desc', text: this.voiceDesc })
      .height(40)
      .borderRadius(8)
      .backgroundColor($r('app.color.page_background'))
      .onChange((v: string) => {
        this.voiceDesc = v;
      });
        }

        .width('100%')
        .padding(12)
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
          label: '测试连接',
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.runTest();
          },
        });
        SecondaryButton({
          label: '刷新进度',
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.refreshProgress(false);
          },
        });
        SecondaryButton({
          label: '重新载入配置',
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.loadConfig();
          },
        });
        DangerButton({
          label: '清除服务器保存的配置',
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.deleteConfig();
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
  clonesTab() {
    Column({ space: 8 }) {
      Column({ space: 10 }) {
        Text('选择 mp3/wav（≤7MB），填写音色名后上传')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        TextInput({ placeholder: '克隆音色名称', text: this.cloneUploadName })
          .height(40)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .onChange((v: string) => {
            this.cloneUploadName = v;
          });
        if (this.clonePickedHint.length > 0) {
          Text(`已选：${this.clonePickedHint}`)
            .fontSize(12)
            .fontColor($r('app.color.brand_primary'))
            .width('100%');
        }
        SecondaryButton({
          label: this.busy ? '处理中…' : '选择音频文件',
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.pickCloneAudio();
          },
        });
        PrimaryButton({
          label: this.busy ? '上传中…' : '上传克隆音色',
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.uploadCloneAudio();
          },
        });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4 });

      SecondaryButton({
        label: this.busy ? '刷新中…' : '刷新克隆列表',
        buttonEnabled: !this.busy,
        onTap: () => {
          void this.loadClones();
        },
      });

      if (this.clones.length === 0) {
        EmptyState({ message: '暂无克隆音色' });
      } else {
        List({ space: 8 }) {
          ForEach(this.clones, (item: Record<string, Object>) => {
            ListItem() {
              Column({ space: 6 }) {
                Text(String(item['name'] ?? ''))
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%');
                Text(`${String(item['ext'] ?? '')} · ${String(item['size'] ?? '')}`)
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%');
                Row({ space: 12 }) {
                  TextButton({
                    label: '选用',
                    onTap: () => {
                      this.useClone(String(item['name'] ?? ''));
                    },
                  });
                  TextButton({
                    label: '路径',
                    onTap: () => {
                      const n = String(item['name'] ?? '');
                      this.toast(TalebookApi.mimoTtsCloneAudioPath(n));
                    },
                  });
                  TextButton({
                    label: '删除',
                    tone: 'danger',
                    onTap: () => {
                      void this.deleteClone(String(item['name'] ?? ''));
                    },
                  });
                }
                .width('100%');
              }
              .width('100%')
              .padding(12)
              .borderRadius($r('app.float.card_radius'))
              .backgroundColor($r('app.color.card_background'));
            }
          }, (item: Record<string, Object>) => `clone-${String(item['name'] ?? '')}`);
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 });
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ top: 8 });
  }

  @Builder
  promptsTab() {
    Column({ space: 8 }) {
      Column({ space: 10 }) {
        TextInput({ placeholder: '提示词名称', text: this.promptName })
          .height(40)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .onChange((v: string) => {
            this.promptName = v;
          });
        TextInput({ placeholder: '提示词内容', text: this.promptDesc })
          .height(40)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .onChange((v: string) => {
            this.promptDesc = v;
          });
        PrimaryButton({
          label: this.busy ? '保存中…' : '保存提示词',
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.savePrompt();
          },
        });
      }
      .width('100%')
      .padding({ left: 16, right: 16 });

      SecondaryButton({
        label: '刷新列表',
        buttonEnabled: !this.busy,
        onTap: () => {
          void this.loadPrompts();
        },
      });

      if (this.prompts.length === 0) {
        EmptyState({ message: '暂无自定义提示词' });
      } else {
        List({ space: 8 }) {
          ForEach(this.prompts, (item: Record<string, Object>) => {
            ListItem() {
              Column({ space: 6 }) {
                Text(String(item['name'] ?? ''))
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%');
                Text(String(item['desc'] ?? item['description'] ?? item['prompt'] ?? ''))
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%');
                Row({ space: 12 }) {
                  TextButton({
                    label: '应用',
                    onTap: () => {
                      this.applyPrompt(item);
                    },
                  });
                  TextButton({
                    label: '删除',
                    tone: 'danger',
                    onTap: () => {
                      void this.deletePrompt(String(item['name'] ?? ''));
                    },
                  });
                }
                .width('100%');
              }
              .width('100%')
              .padding(12)
              .borderRadius($r('app.float.card_radius'))
              .backgroundColor($r('app.color.card_background'));
            }
          }, (item: Record<string, Object>) => `prompt-${String(item['name'] ?? '')}`);
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 });
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ top: 8 });
  }
}
