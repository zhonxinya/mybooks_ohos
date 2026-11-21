// 语音通话 realtime 全双工服务：qwen-audio-3.0-realtime-plus（DashScope/OpenAI Realtime 协议）。
// 麦克风 16k PCM 持续上行（input_audio_buffer.append），服务端 VAD 自动断句，
// 下行 24k PCM 经 AudioRenderer 拉模式队列播放；用户开口（speech_started）即清空播放队列实现打断。
// 协议实测档案：docs/token-plan-audio-protocol-2026-11-20.md §4。
import { webSocket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AiService } from './AiService';
import type { AiMessage } from './AiService';

const TAG: string = 'RealtimeCall';
const REALTIME_MODEL: string = 'qwen-audio-3.0-realtime-plus';
const REALTIME_VOICE: string = 'longanqian';
/** 下行播放采样率：realtime 输出固定 24k s16le mono。 */
const PLAY_RATE: number = 24000;

export interface RealtimeCallCallbacks {
  /** 用户一句话的最终转写文本。 */
  onUserText: (text: string) => void;
  /**
   * ASR 中间结果（累计全文，非增量；speech_started 时先回调空串清占位）。
   * 对话页内嵌语音用它做「实时信息流」；可选，通话页等旧消费方不实现即无行为变化。
   */
  onUserTextDelta?: (text: string) => void;
  /** AI 回复增量/完结字幕文本。 */
  onAiTextDelta: (delta: string) => void;
  onAiTextDone: (full: string) => void;
  /** 用户开口打断：本服务已清空待播音频，页面切回聆听。 */
  onSpeechStarted: () => void;
  /** 用户说完（服务端开始组织回复）。 */
  onSpeechStopped: () => void;
  /** 首帧 AI 音频到达，页面切「说话中」。 */
  onResponding: () => void;
  /** 本轮回复结束。 */
  onResponseDone: () => void;
  /**
   * 模型请求调用工具（已在 session 里注册）。页面执行（含确认闸门）后
   * 调 sendToolResult 回填结果并续流；期间可显示「查询中」。
   */
  onFunctionCall: (name: string, args: string, callId: string) => void;
  onError: (message: string) => void;
  onClosed: () => void;
}

export class RealtimeCallService {
  private static ws: webSocket.WebSocket | null = null;
  private static capturer: audio.AudioCapturer | null = null;
  private static renderer: audio.AudioRenderer | null = null;
  private static callbacks: RealtimeCallCallbacks | null = null;
  /** 待播 PCM 字节队列（audio.delta 到达顺序）。 */
  private static playChunks: Uint8Array[] = [];
  private static playBytes: number = 0;
  /** 打断代数：speech_started 自增，避免清空与渲染回调的竞态误判。 */
  private static playGen: number = 0;
  private static responding: boolean = false;
  private static aiTranscript: string = '';
  /** 本句 ASR 中间结果累计（speech_started 清零，completed 后作废）。 */
  private static userTranscript: string = '';
  private static closed: boolean = false;
  private static base64: util.Base64Helper = new util.Base64Helper();
  private static decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

  /** 播放队列水位（字节），hilog/用例观察打断生效。 */
  static getPlayBytes(): number {
    return RealtimeCallService.playBytes;
  }

  private static muted: boolean = false;
  /** 有工具结果待回填续流；用户在此期间开口则交给 VAD 自动起轮，不再抢 response.create。 */
  private static toolWaitResponse: boolean = false;

  /** 回填工具执行结果（output 为人话摘要或原始 JSON 均可，模型自行消化）。 */
  static sendToolResult(callId: string, output: string): void {
    if (RealtimeCallService.ws === null || RealtimeCallService.closed) {
      return;
    }
    const item: Record<string, Object> = {
      'type': 'function_call_output', 'call_id': callId, 'output': output,
    };
    const create: Record<string, Object> = { 'type': 'conversation.item.create', 'item': item };
    RealtimeCallService.sendJson(create);
    if (RealtimeCallService.toolWaitResponse) {
      RealtimeCallService.toolWaitResponse = false;
      RealtimeCallService.sendJson({ 'type': 'response.create' } as Record<string, Object>);
    }
  }

  /** 静音：停止上行麦克风帧（VAD 收不到我，但对方讲话与播放不受影响）。 */
  static setMuted(on: boolean): void {
    RealtimeCallService.muted = on;
  }

  /**
   * 连接并进入可对话状态；失败经 onError 汇报并抛错（页面提示回退）。
   * `tools` 传 AiTools.definitions()（OpenAI function 形态，网关实测接受）；空数组=不带工具。
   * `history` 为可选文字对话历史：连接后逐条 conversation.item.create 注入，语音接得上上下文。
   */
  static async connect(instructions: string, callbacks: RealtimeCallCallbacks, tools: Object[],
    history: AiMessage[] = []): Promise<void> {
    RealtimeCallService.disconnect();
    RealtimeCallService.callbacks = callbacks;
    RealtimeCallService.closed = false;
    RealtimeCallService.playChunks = [];
    RealtimeCallService.playBytes = 0;
    RealtimeCallService.responding = false;
    RealtimeCallService.aiTranscript = '';
    RealtimeCallService.userTranscript = '';
    RealtimeCallService.muted = false;
    RealtimeCallService.toolWaitResponse = false;

    const ws: webSocket.WebSocket = webSocket.createWebSocket();
    RealtimeCallService.ws = ws;
    ws.on('message', (err: BusinessError, data: string | ArrayBuffer): void => {
      if (err !== null && err !== undefined) {
        return;
      }
      const text: string = typeof data === 'string' ? data :
        RealtimeCallService.decoder.decodeToString(new Uint8Array(data));
      RealtimeCallService.handleEvent(text);
    });
    ws.on('close', (): void => {
      if (!RealtimeCallService.closed) {
        RealtimeCallService.notify((c: RealtimeCallCallbacks): void => c.onClosed());
      }
    });
    ws.on('error', (err: BusinessError): void => {
      hilog.error(0x0000, TAG, 'ws error: %{public}s', err === undefined || err === null ? '' : err.message);
    });

    const url: string = `${RealtimeCallService.wsOrigin()}/api-ws/v1/realtime?model=${REALTIME_MODEL}`;
    const header: Record<string, string> = { 'Authorization': `Bearer ${RealtimeCallService.apiKey()}` };
    const options: webSocket.WebSocketRequestOptions = { header: header };
    await new Promise<void>((resolve: () => void, reject: (e: Error) => void): void => {
      ws.connect(url, options, (err: BusinessError): void => {
        if (err !== null && err !== undefined) {
          reject(new Error(`连接实时网关失败：${err.message}`));
          return;
        }
        resolve();
      });
    });
    // 服务端先推 session.created，收到后才允许 session.update（官方示例时序）
    await RealtimeCallService.waitForCreated();
    const turn: Record<string, Object> = {
      'type': 'server_vad',
      'threshold': 0.5,
      'silence_duration_ms': 600,
    };
    const session: Record<string, Object> = {
      'modalities': ['audio', 'text'],
      'voice': REALTIME_VOICE,
      'instructions': instructions,
      'input_audio_format': 'pcm',
      'output_audio_format': 'pcm',
      'turn_detection': turn,
    };
    if (tools.length > 0) {
      session['tools'] = tools;
    }
    const update: Record<string, Object> = { 'type': 'session.update', 'session': session };
    RealtimeCallService.sendJson(update);
    // 文字历史注入：只带 user/assistant 非空文本，system/图片轮跳过
    for (let i = 0; i < history.length; i++) {
      const role: string = history[i].role;
      const content: string = history[i].content;
      if (content.length === 0 || (role !== 'user' && role !== 'assistant')) {
        continue;
      }
      const part: Record<string, Object> = {
        'type': role === 'user' ? 'input_text' : 'output_text',
        'text': content,
      };
      const item: Record<string, Object> = { 'type': 'message', 'role': role, 'content': [part] };
      const seed: Record<string, Object> = { 'type': 'conversation.item.create', 'item': item };
      RealtimeCallService.sendJson(seed);
    }
    await RealtimeCallService.startMic();
    await RealtimeCallService.startRenderer();
  }

  static disconnect(): void {
    RealtimeCallService.closed = true;
    const capturer: audio.AudioCapturer | null = RealtimeCallService.capturer;
    RealtimeCallService.capturer = null;
    if (capturer !== null) {
      capturer.stop().then((): Promise<void> => capturer.release()).catch((): void => {});
    }
    const renderer: audio.AudioRenderer | null = RealtimeCallService.renderer;
    RealtimeCallService.renderer = null;
    if (renderer !== null) {
      renderer.stop().then((): Promise<void> => renderer.release()).catch((): void => {});
    }
    const ws: webSocket.WebSocket | null = RealtimeCallService.ws;
    RealtimeCallService.ws = null;
    if (ws !== null) {
      try {
        ws.off('message');
        ws.off('close');
        ws.off('error');
        ws.close();
      } catch (_error) {
      }
    }
    RealtimeCallService.playChunks = [];
    RealtimeCallService.playBytes = 0;
    RealtimeCallService.callbacks = null;
  }

  // ————————————————— 事件分发 —————————————————

  private static createdResolve: (() => void) | null = null;

  private static waitForCreated(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      RealtimeCallService.createdResolve = resolve;
    });
  }

  private static handleEvent(text: string): void {
    if (text.length === 0) {
      return;
    }
    let event: Record<string, Object>;
    try {
      event = JSON.parse(text) as Record<string, Object>;
    } catch (_error) {
      return;
    }
    const type: string = String(event['type'] ?? '');
    if (type === 'session.created') {
      const resolve: (() => void) | null = RealtimeCallService.createdResolve;
      RealtimeCallService.createdResolve = null;
      if (resolve !== null) {
        resolve();
      }
    } else if (type === 'input_audio_buffer.speech_started') {
      // 打断：立刻丢队列，之后到达的本轮 audio.delta 也随 responding=false 丢弃入队但会被下次清空
      RealtimeCallService.bargeIn();
      RealtimeCallService.toolWaitResponse = false;
      RealtimeCallService.userTranscript = '';
      RealtimeCallService.notify((c: RealtimeCallCallbacks): void => {
        if (c.onUserTextDelta !== undefined) {
          c.onUserTextDelta('');
        }
      });
      RealtimeCallService.notify((c: RealtimeCallCallbacks): void => c.onSpeechStarted());
    } else if (type === 'input_audio_buffer.speech_stopped') {
      RealtimeCallService.notify((c: RealtimeCallCallbacks): void => c.onSpeechStopped());
    } else if (type === 'conversation.item.input_audio_transcription.delta') {
      // OpenAI 语义：text 为本段增量；页面拿累计全文实时刷新（final 以 completed 为准）
      RealtimeCallService.userTranscript += String(event['text'] ?? '');
      const acc: string = RealtimeCallService.userTranscript;
      RealtimeCallService.notify((c: RealtimeCallCallbacks): void => {
        if (c.onUserTextDelta !== undefined) {
          c.onUserTextDelta(acc);
        }
      });
    } else if (type === 'conversation.item.input_audio_transcription.completed') {
      RealtimeCallService.userTranscript = '';
      const transcript: string = String(event['transcript'] ?? '');
      if (transcript.length > 0) {
        RealtimeCallService.notify((c: RealtimeCallCallbacks): void => c.onUserText(transcript));
      }
    } else if (type === 'response.audio_transcript.delta') {
      const delta: string = String(event['delta'] ?? '');
      RealtimeCallService.aiTranscript += delta;
      RealtimeCallService.notify((c: RealtimeCallCallbacks): void => c.onAiTextDelta(delta));
    } else if (type === 'response.audio_transcript.done') {
      const full: string = typeof event['transcript'] === 'string' ?
        event['transcript'] as string : RealtimeCallService.aiTranscript;
      RealtimeCallService.aiTranscript = '';
      RealtimeCallService.notify((c: RealtimeCallCallbacks): void => c.onAiTextDone(full));
    } else if (type === 'response.audio.delta') {
      const delta: string = String(event['delta'] ?? '');
      if (delta.length > 0) {
        RealtimeCallService.enqueueAudio(delta);
      }
    } else if (type === 'response.function_call_arguments.done') {
      const name: string = String(event['name'] ?? '');
      const callId: string = String(event['call_id'] ?? '');
      const args: string = String(event['arguments'] ?? '{}');
      // 本轮响应已因 function_call 结束（response.done）；回填后需手动续一轮
      RealtimeCallService.toolWaitResponse = true;
      RealtimeCallService.notify((c: RealtimeCallCallbacks): void => c.onFunctionCall(name, args, callId));
    } else if (type === 'response.done') {
      RealtimeCallService.notify((c: RealtimeCallCallbacks): void => c.onResponseDone());
    } else if (type === 'error') {
      const err = event['error'] as Record<string, Object> | undefined;
      const message: string = err !== undefined && err !== null ? String(err['message'] ?? '实时服务错误') : '实时服务错误';
      RealtimeCallService.notify((c: RealtimeCallCallbacks): void => c.onError(message));
    }
  }

  private static enqueueAudio(deltaB64: string): void {
    let bytes: Uint8Array;
    try {
      bytes = RealtimeCallService.base64.decodeSync(deltaB64);
    } catch (error) {
      hilog.warn(0x0000, TAG, 'audio decode: %{public}s', (error as BusinessError).message);
      return;
    }
    RealtimeCallService.playChunks.push(bytes);
    RealtimeCallService.playBytes += bytes.byteLength;
    if (!RealtimeCallService.responding) {
      RealtimeCallService.responding = true;
      RealtimeCallService.notify((c: RealtimeCallCallbacks): void => c.onResponding());
    }
  }

  /** 清空待播音频（打断/异常时），拉模式回调随即补静音。 */
  private static bargeIn(): void {
    RealtimeCallService.playChunks = [];
    RealtimeCallService.playBytes = 0;
    RealtimeCallService.playGen++;
    RealtimeCallService.responding = false;
  }

  // ————————————————— 麦克风上行 —————————————————

  private static async startMic(): Promise<void> {
    // VOICE_COMMUNICATION 走系统回声消除，免扬声器外放回灌触发 VAD 自激
    const capturer: audio.AudioCapturer = await audio.createAudioCapturer({
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      },
      capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION, capturerFlags: 0 },
    });
    capturer.on('readData', (buffer: ArrayBuffer): void => {
      const ws: webSocket.WebSocket | null = RealtimeCallService.ws;
      if (ws === null || RealtimeCallService.closed || RealtimeCallService.muted) {
        return;
      }
      const b64: string = RealtimeCallService.base64.encodeToStringSync(new Uint8Array(buffer));
      const payload: Record<string, Object> = { 'type': 'input_audio_buffer.append', 'audio': b64 };
      RealtimeCallService.sendJson(payload);
    });
    RealtimeCallService.capturer = capturer;
    await capturer.start();
  }

  // ————————————————— 24k PCM 拉模式播放 —————————————————

  private static async startRenderer(): Promise<void> {
    const renderer: audio.AudioRenderer = await audio.createAudioRenderer({
      streamInfo: {
        samplingRate: PLAY_RATE,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      },
      rendererInfo: {
        rendererFlags: 0,
        usage: audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION,
      },
    });
    renderer.on('writeData', (buffer: ArrayBuffer): void => {
      const target: Uint8Array = new Uint8Array(buffer);
      let written: number = 0;
      while (written < target.length && RealtimeCallService.playChunks.length > 0) {
        const head: Uint8Array = RealtimeCallService.playChunks[0];
        const need: number = target.length - written;
        const take: number = head.byteLength <= need ? head.byteLength : need;
        target.set(head.subarray(0, take), written);
        written += take;
        RealtimeCallService.playBytes -= take;
        if (take === head.byteLength) {
          RealtimeCallService.playChunks.shift();
        } else {
          RealtimeCallService.playChunks[0] = head.subarray(take);
        }
      }
      if (written < target.length) {
        target.fill(0, written);
      }
    });
    RealtimeCallService.renderer = renderer;
    await renderer.start();
  }

  // ————————————————— 通道辅助 —————————————————

  private static sendJson(payload: Record<string, Object>): void {
    const ws: webSocket.WebSocket | null = RealtimeCallService.ws;
    if (ws === null) {
      return;
    }
    ws.send(JSON.stringify(payload), (err: BusinessError): void => {
      if (err !== null && err !== undefined) {
        hilog.warn(0x0000, TAG, 'send failed: %{public}s', err.message);
      }
    });
  }

  private static notify(action: (c: RealtimeCallCallbacks) => void): void {
    const callbacks: RealtimeCallCallbacks | null = RealtimeCallService.callbacks;
    if (callbacks !== null) {
      action(callbacks);
    }
  }

  /** Token Plan 网关 http(s) origin → ws(s)。 */
  private static wsOrigin(): string {
    const baseUrl: string = AiService.loadVoiceConfig().baseUrl;
    const schemeEnd: number = baseUrl.indexOf('://');
    if (schemeEnd < 0) {
      throw new Error('Token Plan 服务商地址无效');
    }
    const hostStart: number = schemeEnd + 3;
    const pathStart: number = baseUrl.indexOf('/', hostStart);
    const origin: string = pathStart < 0 ? baseUrl : baseUrl.substring(0, pathStart);
    return origin.startsWith('https') ? origin.replace('https', 'wss') : origin.replace('http', 'ws');
  }

  private static apiKey(): string {
    const key: string = AiService.apiKeyFor(AiService.loadVoiceConfig().providerId);
    if (key.length === 0) {
      throw new Error('未配置 Token Plan API Key（AI 设置页填写）');
    }
    return key;
  }
}
