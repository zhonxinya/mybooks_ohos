// 语音通话页：默认 realtime WS 全双工（VAD 自动断句、开口即打断、可静音）；
// 设置页可切「轮转模式」（听→识→想→说循环，用独立自选的对话模型与播报引擎）。
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { PageScaffold, PrimaryButton, SecondaryButton } from '../components';
import { AppRouter } from '../utils/AppRouter';
import { QwenAudioService } from '../services/QwenAudioService';
import { SpeakService } from '../services/SpeakService';
import { RealtimeCallService, RealtimeCallCallbacks } from '../services/RealtimeCallService';
import { AiService, AiMessage } from '../services/AiService';
import { AiTools } from '../services/AiTools';
import { AiVoiceKit, VOICE_SYSTEM_PROMPT, VOICE_TOOL_NOTE } from '../services/AiVoiceKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'AiVoiceCall';

const ST_IDLE: string = 'idle';
const ST_CONNECTING: string = 'connecting';
const ST_LISTENING: string = 'listening';
const ST_TRANSCRIBING: string = 'transcribing';
const ST_THINKING: string = 'thinking';
const ST_SPEAKING: string = 'speaking';

@Entry
@Component
struct AiVoiceCallPage {
  @State st: string = ST_IDLE;
  @State userLine: string = '';
  @State aiLine: string = '';
  @State tip: string = '';
  @State muted: boolean = false;
  private history: AiMessage[] = [];
  /** 轮次序号：挂断/重开后旧异步链凭序号失效（多处 await 后检查）。 */
  private turnSeq: number = 0;
  /** 当前在通话的是 realtime 全双工模式（按钮布局与挂断逻辑分叉）。 */
  private rtMode: boolean = false;

  aboutToDisappear(): void {
    this.hangup();
  }

  private stateShort(): string {
    if (this.st === ST_CONNECTING) {
      return '呼叫中';
    }
    if (this.st === ST_LISTENING) {
      return this.rtMode && this.muted ? '已静音' : '聆听中';
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
      if (this.rtMode) {
        // 全双工通话中：VAD 自动轮转与打断，人工只需静音/挂断
        Row({ space: 12 }) {
          SecondaryButton({
            label: this.muted ? '取消静音' : '静音',
            fullWidth: false,
            onTap: () => {
              this.toggleMute();
            },
          }).layoutWeight(1);
          PrimaryButton({
            label: '挂断',
            fullWidth: false,
            onTap: () => {
              this.hangup();
              AppRouter.back(this.getUIContext());
            },
          }).layoutWeight(1);
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 24 });
      } else {
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
            buttonEnabled: this.st !== ST_TRANSCRIBING && this.st !== ST_THINKING && this.st !== ST_CONNECTING,
            onTap: () => {
              void this.onMain();
            },
          }).layoutWeight(1.6);
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 24 });
      }
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
      if (AiService.loadCallMode() === 'realtime') {
        await this.startRealtime();
      } else {
        await this.beginListening();
      }
      return;
    }
    if (this.rtMode) {
      return;
    }
    if (this.st === ST_LISTENING) {
      await this.finishTurn();
      return;
    }
    if (this.st === ST_SPEAKING) {
      // 打断播报：stop 让 speak 以 false 返回，轮转自然回到聆听
      this.tip = '';
      SpeakService.stop();
    }
  }

  // ————————————————— realtime 全双工 —————————————————

  private async startRealtime(): Promise<void> {
    this.st = ST_CONNECTING;
    const cb: RealtimeCallCallbacks = {
      onUserText: (t: string): void => {
        this.userLine = t;
      },
      onAiTextDelta: (d: string): void => {
        this.aiLine += d;
      },
      onAiTextDone: (t: string): void => {
        this.aiLine = t;
      },
      onSpeechStarted: (): void => {
        // 开口即打断（服务已清播放队列），回到聆听
        this.tip = '';
        this.st = ST_LISTENING;
      },
      onSpeechStopped: (): void => {
        this.aiLine = '';
        this.st = ST_THINKING;
      },
      onResponding: (): void => {
        this.st = ST_SPEAKING;
      },
      onResponseDone: (): void => {
        if (this.rtMode && this.st === ST_SPEAKING) {
          this.st = ST_LISTENING;
        }
      },
      onError: (m: string): void => {
        this.tip = m;
      },
      onClosed: (): void => {
        if (this.rtMode) {
          this.rtMode = false;
          this.muted = false;
          this.st = ST_IDLE;
          this.tip = '连接已中断，可重新拨打';
        }
      },
      onFunctionCall: (name: string, args: string, callId: string): void => {
        void AiVoiceKit.runTool(name, args, callId, this.getUIContext());
      },
    };
    // set_voice 生效通道：存配置后重开 realtime 会话（新音色进首包 session.update）
    AiVoiceKit.voiceSwitcher = (): void => {
      this.hangup();
      void this.startRealtime();
    };
    try {
      const prompt: string = VOICE_SYSTEM_PROMPT + VOICE_TOOL_NOTE;
      // 与文字回路同源：MCP 动态工具一并注入语音工具面（非 Token Plan/失败=空集）
      const mcpTools = await AiService.mcpToolset();
      await RealtimeCallService.connect(prompt, cb, AiTools.realtimeDefinitions(AiService.loadPermission(), mcpTools));
      this.rtMode = true;
      this.muted = false;
      this.st = ST_LISTENING;
    } catch (error) {
      hilog.error(0x0000, TAG, 'realtime connect: %{public}s', `${error}`);
      this.st = ST_IDLE;
      this.tip = error instanceof Error ? error.message : `连接失败：${error}`;
    }
  }

  private toggleMute(): void {
    this.muted = !this.muted;
    RealtimeCallService.setMuted(this.muted);
  }

  // ————————————————— 轮转模式（fallback，可用自选对话模型） —————————————————

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
      await SpeakService.speak(answer);
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
    this.rtMode = false;
    this.muted = false;
    this.st = ST_IDLE;
    AiVoiceKit.voiceSwitcher = null;
    RealtimeCallService.disconnect();
    SpeakService.stop();
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
