// 语音通话页（轮转模式）：听→识别→AI→播报→听 循环，Token Plan 音频链路。
// 打断=播报中点「打断」停止朗读直接回到聆听；realtime WS 全双工是后续升级项。
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { PageScaffold, PrimaryButton, SecondaryButton } from '../components';
import { AppRouter } from '../utils/AppRouter';
import { QwenAudioService } from '../services/QwenAudioService';
import { AiService, AiMessage } from '../services/AiService';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'AiVoiceCall';

const ST_IDLE: string = 'idle';
const ST_LISTENING: string = 'listening';
const ST_TRANSCRIBING: string = 'transcribing';
const ST_THINKING: string = 'thinking';
const ST_SPEAKING: string = 'speaking';

/** 语音场景专用人设：短、口语化、可直接朗读（不复用文字页 SYSTEM_PROMPT 的工具/书单内容）。 */
const VOICE_SYSTEM_PROMPT: string =
  '你是阅读应用里的语音助手，正在和用户实时通话。回答口语化、简洁（一般一到三句），' +
  '会被直接朗读出来，因此不要使用 Markdown、列表、代码块或表情符号。' +
  '可以聊书、作者、阅读推荐，也可以日常问答；不确定就直说。';

@Entry
@Component
struct AiVoiceCallPage {
  @State st: string = ST_IDLE;
  @State userLine: string = '';
  @State aiLine: string = '';
  @State tip: string = '';
  private history: AiMessage[] = [];
  /** 轮次序号：挂断/重开后旧异步链凭序号失效（多处 await 后检查）。 */
  private turnSeq: number = 0;

  aboutToDisappear(): void {
    this.hangup();
  }

  private stateShort(): string {
    if (this.st === ST_LISTENING) {
      return '聆听中';
    }
    if (this.st === ST_TRANSCRIBING) {
      return '识别中';
    }
    if (this.st === ST_THINKING) {
      return '思考中';
    }
    if (this.st === ST_SPEAKING) {
      return '说话中';
    }
    return '未开始';
  }

  private mainLabel(): string {
    if (this.st === ST_IDLE) {
      return '开始通话';
    }
    if (this.st === ST_LISTENING) {
      return '我说完了';
    }
    return '打断';
  }

  build() {
    Column() {
      PageScaffold({
        title: '语音通话',
        showBack: true,
        content: () => {
          this.body();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  body() {
    Column({ space: 18 }) {
      Blank().layoutWeight(1);
      Stack() {
        Circle()
          .width(110)
          .height(110)
          .fill(this.st === ST_LISTENING ? '#2E7D32' :
            (this.st === ST_SPEAKING ? $r('app.color.brand_primary') :
              (this.st === ST_IDLE ? $r('app.color.card_background') : $r('app.color.brand_primary_light'))));
        Text(this.stateShort())
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.st === ST_LISTENING ? Color.White : $r('app.color.text_primary'));
      }
      Column({ space: 6 }) {
        Text(this.userLine.length > 0 ? `你：${this.userLine}` : '（说点什么）')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center);
        Text(this.aiLine.length > 0 ? `AI：${this.aiLine}` : '')
          .fontSize(15)
          .fontColor($r('app.color.brand_primary'))
          .maxLines(6)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center);
      }
      .padding({ left: 28, right: 28 })
      if (this.tip.length > 0) {
        Text(this.tip)
          .fontSize(12)
          .fontColor($r('app.color.error'))
          .textAlign(TextAlign.Center)
          .padding({ left: 28, right: 28 });
      }
      Blank().layoutWeight(1);
      Row({ space: 12 }) {
        SecondaryButton({
          label: '挂断',
          fullWidth: false,
          onTap: () => {
            this.hangup();
            AppRouter.back(this.getUIContext());
          },
        }).layoutWeight(1);
        PrimaryButton({
          label: this.mainLabel(),
          buttonEnabled: this.st !== ST_TRANSCRIBING && this.st !== ST_THINKING,
          onTap: () => {
            void this.onMain();
          },
        }).layoutWeight(1.6);
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 24 });
    }
    .width('100%')
    .height('100%');
  }

  private async onMain(): Promise<void> {
    if (this.st === ST_IDLE) {
      const granted: boolean = await this.ensureMicPermission();
      if (!granted) {
        this.tip = '麦克风权限被拒绝，无法通话';
        return;
      }
      this.tip = '';
      await this.beginListening();
      return;
    }
    if (this.st === ST_LISTENING) {
      await this.finishTurn();
      return;
    }
    if (this.st === ST_SPEAKING) {
      // 打断播报：stopPlayback 让 playFile 返回，轮转自然回到聆听
      this.tip = '';
      QwenAudioService.stopPlayback();
    }
  }

  private async beginListening(): Promise<void> {
    const my: number = this.turnSeq;
    this.st = ST_LISTENING;
    this.userLine = '';
    try {
      await QwenAudioService.startRecording();
    } catch (error) {
      if (my !== this.turnSeq) {
        return;
      }
      hilog.error(0x0000, TAG, 'startRecording: %{public}s', `${error}`);
      this.tip = `录音启动失败：${error}`;
      this.st = ST_IDLE;
    }
  }

  private async finishTurn(): Promise<void> {
    const my: number = ++this.turnSeq;
    const alive = (): boolean => my === this.turnSeq;
    this.st = ST_TRANSCRIBING;
    this.tip = '';
    try {
      const wav: string = await QwenAudioService.stopRecording();
      if (!alive()) {
        return;
      }
      const heard: string = await QwenAudioService.transcribe(wav);
      if (!alive()) {
        return;
      }
      if (heard.length === 0) {
        this.tip = '没听清，再说一次';
        await this.beginListening();
        return;
      }
      this.userLine = heard;
      this.history.push({ role: 'user', content: heard });
      this.st = ST_THINKING;
      const messages: AiMessage[] = [{ role: 'system', content: VOICE_SYSTEM_PROMPT }];
      const keepFrom: number = Math.max(0, this.history.length - 12);
      for (let i = keepFrom; i < this.history.length; i++) {
        messages.push(this.history[i]);
      }
      const answer: string = await AiService.complete(messages, 512, AiService.loadVoiceConfig());
      if (!alive()) {
        return;
      }
      this.aiLine = answer;
      this.history.push({ role: 'assistant', content: answer });
      this.st = ST_SPEAKING;
      const path: string = await QwenAudioService.synthesize(answer);
      if (!alive()) {
        return;
      }
      await QwenAudioService.playFile(path);
      if (!alive()) {
        return;
      }
      await this.beginListening();
    } catch (error) {
      if (!alive()) {
        return;
      }
      hilog.error(0x0000, TAG, 'turn failed: %{public}s', `${error}`);
      this.tip = `出错了：${error}`;
      await this.beginListening();
    }
  }

  private hangup(): void {
    this.turnSeq++;
    this.st = ST_IDLE;
    QwenAudioService.stopPlayback();
    QwenAudioService.stopRecordingCleanup();
  }

  private async ensureMicPermission(): Promise<boolean> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const at = abilityAccessCtrl.createAtManager();
      const grant = await at.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
      for (let i = 0; i < grant.authResults.length; i++) {
        if (grant.authResults[i] !== 0) {
          return false;
        }
      }
      return true;
    } catch (error) {
      hilog.error(0x0000, TAG, 'permission: %{public}s', `${error}`);
      return false;
    }
  }
}
