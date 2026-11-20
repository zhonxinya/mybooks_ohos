// Token Plan（千问）音频服务：录音→ASR、文本→TTS→本地播放。
// 协议均为 DashScope 原生路径（不在 compatible-mode 子路径下），实测档案见
// docs/token-plan-audio-protocol-2026-11-20.md；Key/baseUrl 复用 AiService 当前服务商配置。
import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { audio } from '@kit.AudioKit';
import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AiService } from './AiService';
import { TalebookService } from './TalebookService';

const TAG: string = 'QwenAudio';
const SAMPLE_RATE: number = 16000;
/** 单次录音上限：ASR 规格 ≤5 分钟，但通话轮转语义下 60s 足够且防内存膨胀（16k*2B*60s≈1.9MB）。 */
const MAX_RECORD_MS: number = 60000;
/** Token Plan qwen-audio-3.0-tts-plus 系音色（Cherry/Tina 等旧名会被拒）。 */
const TTS_VOICE: string = 'longanhuan_v3.6';
const TTS_FORMAT: string = 'mp3';
const TTS_SAMPLE_RATE: number = 22050;

export class QwenAudioService {
  // ————————————————— 录音（AudioCapturer 16k 单声道 S16LE） —————————————————
  private static capturer: audio.AudioCapturer | null = null;
  private static pcmChunks: Uint8Array[] = [];
  private static pcmBytes: number = 0;

  static async startRecording(): Promise<void> {
    QwenAudioService.stopRecordingCleanup();
    QwenAudioService.pcmChunks = [];
    QwenAudioService.pcmBytes = 0;
    const capturer: audio.AudioCapturer = await audio.createAudioCapturer({
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      },
      capturerInfo: { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 },
    });
    capturer.on('readData', (buffer: ArrayBuffer): void => {
      QwenAudioService.pcmChunks.push(new Uint8Array(buffer));
      QwenAudioService.pcmBytes += buffer.byteLength;
      if (QwenAudioService.pcmBytes >= SAMPLE_RATE * 2 * MAX_RECORD_MS / 1000) {
        // 到顶自动截断：页面侧不依赖此回调，stopRecording 幂等可重复调。
        QwenAudioService.stopRecording().then((): void => {});
      }
    });
    QwenAudioService.capturer = capturer;
    await capturer.start();
  }

  /** 停止录音，返回 wav 的 base64（可直接喂 transcribe）；无数据返回 ''。 */
  static async stopRecording(): Promise<string> {
    const capturer: audio.AudioCapturer | null = QwenAudioService.capturer;
    if (capturer === null) {
      return '';
    }
    QwenAudioService.capturer = null;
    try {
      await capturer.stop();
    } catch (error) {
      hilog.warn(0x0000, TAG, 'capturer stop: %{public}s', (error as BusinessError).message);
    }
    await capturer.release();
    const pcmLen: number = QwenAudioService.pcmBytes;
    if (pcmLen === 0) {
      return '';
    }
    const wav: Uint8Array = new Uint8Array(44 + pcmLen);
    const view: DataView = new DataView(wav.buffer);
    QwenAudioService.writeWavHeader(view, pcmLen);
    let offset: number = 44;
    for (let i = 0; i < QwenAudioService.pcmChunks.length; i++) {
      wav.set(QwenAudioService.pcmChunks[i], offset);
      offset += QwenAudioService.pcmChunks[i].byteLength;
    }
    QwenAudioService.pcmChunks = [];
    QwenAudioService.pcmBytes = 0;
    return new util.Base64Helper().encodeToStringSync(wav);
  }

  /** 放弃录音并释放设备（挂断/出错路径）。 */
  static stopRecordingCleanup(): void {
    const capturer: audio.AudioCapturer | null = QwenAudioService.capturer;
    QwenAudioService.capturer = null;
    if (capturer !== null) {
      capturer.stop().then((): Promise<void> => capturer.release()).catch((): void => {});
    }
    QwenAudioService.pcmChunks = [];
    QwenAudioService.pcmBytes = 0;
  }

  private static writeWavHeader(view: DataView, pcmLen: number): void {
    let p: number = 0;
    const putStr = (s: string): void => {
      for (let i = 0; i < s.length; i++) {
        view.setUint8(p, s.charCodeAt(i));
        p += 1;
      }
    };
    const putU32 = (v: number): void => {
      view.setUint32(p, v, true);
      p += 4;
    };
    const putU16 = (v: number): void => {
      view.setUint16(p, v, true);
      p += 2;
    };
    putStr('RIFF');
    putU32(36 + pcmLen);
    putStr('WAVE');
    putStr('fmt ');
    putU32(16);
    putU16(1); // PCM
    putU16(1); // mono
    putU32(SAMPLE_RATE);
    putU32(SAMPLE_RATE * 2); // byte rate
    putU16(2); // block align
    putU16(16); // bits
    putStr('data');
    putU32(pcmLen);
  }

  // ————————————————— 网络（DashScope 原生路径） —————————————————

  /** 从服务商 baseUrl（…/compatible-mode/v1）派生网关 origin。 */
  private static origin(): string {
    const baseUrl: string = AiService.loadConfig().baseUrl;
    const schemeEnd: number = baseUrl.indexOf('://');
    if (schemeEnd < 0) {
      throw new Error('Token Plan 服务商地址无效');
    }
    const hostStart: number = schemeEnd + 3;
    const pathStart: number = baseUrl.indexOf('/', hostStart);
    if (pathStart < 0) {
      return baseUrl;
    }
    return baseUrl.substring(0, pathStart);
  }

  private static apiKey(): string {
    const key: string = AiService.apiKeyFor(AiService.loadConfig().providerId);
    if (key.length === 0) {
      throw new Error('未配置 Token Plan API Key（AI 设置页填写）');
    }
    return key;
  }

  /** POST JSON，返回响应文本；非 2xx 抛「HTTP code: 响应体截断」。 */
  private static async postJson(url: string, body: string, transferMs: number): Promise<string> {
    const headers: rcp.RequestHeaders = {
      'Authorization': `Bearer ${QwenAudioService.apiKey()}`,
      'Content-Type': 'application/json',
    };
    const session: rcp.Session = rcp.createSession({
      requestConfiguration: { transfer: { timeout: { connectMs: 10000, transferMs: transferMs } } },
    });
    try {
      const request: rcp.Request = new rcp.Request(url, 'POST', headers, body);
      const response: rcp.Response = await session.fetch(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        let detail: string = '';
        const bodyBuf: ArrayBuffer | undefined = response.body;
        if (bodyBuf !== undefined) {
          detail = new util.TextDecoder().decodeToString(new Uint8Array(bodyBuf)).substring(0, 200);
        }
        throw new Error(`HTTP ${response.statusCode}: ${detail}`);
      }
      const buf: ArrayBuffer | undefined = response.body;
      if (buf === undefined) {
        return '';
      }
      return new util.TextDecoder().decodeToString(new Uint8Array(buf));
    } finally {
      session.close();
    }
  }

  /** 录音 wav base64 → 识别文本。空音频/无内容返回 ''（调用方决定重听还是提示）。 */
  static async transcribe(wavB64: string): Promise<string> {
    if (wavB64.length === 0) {
      return '';
    }
    const audioData: Record<string, Object> = { 'data': `data:audio/wav;base64,${wavB64}` };
    const contentItem: Record<string, Object> = { 'type': 'input_audio', 'input_audio': audioData };
    const contents: Record<string, Object>[] = [contentItem];
    const userMsg: Record<string, Object> = { 'role': 'user', 'content': contents };
    const messages: Record<string, Object>[] = [userMsg];
    const input: Record<string, Object> = { 'messages': messages };
    const params: Record<string, Object> = { 'format': 'wav' };
    const payload: Record<string, Object> = {
      'model': 'qwen-audio-3.0-asr-flash',
      'input': input,
      'parameters': params,
    };
    const text: string = await QwenAudioService.postJson(
      `${QwenAudioService.origin()}/api/v1/services/aigc/multimodal-generation/generation`,
      JSON.stringify(payload), 120000);
    const root = JSON.parse(text) as Record<string, Object>;
    const output = root['output'] as Record<string, Object> | undefined;
    if (output === undefined) {
      throw new Error('识别响应格式异常');
    }
    const result: string | undefined = output['text'] as string | undefined;
    return result ?? '';
  }

  /** 文本 → 语音：合成后下载 OSS 临时文件到 dataDir/tts，返回本地 mp3 路径。 */
  static async synthesize(text: string): Promise<string> {
    const ttsInput: Record<string, Object> =
      { 'text': text, 'voice': TTS_VOICE, 'format': TTS_FORMAT, 'sample_rate': TTS_SAMPLE_RATE };
    const payload: Record<string, Object> = {
      'model': 'qwen-audio-3.0-tts-plus',
      'input': ttsInput,
    };
    const resp: string = await QwenAudioService.postJson(
      `${QwenAudioService.origin()}/api/v1/services/audio/tts/SpeechSynthesizer`,
      JSON.stringify(payload), 60000);
    const root = JSON.parse(resp) as Record<string, Object>;
    const output = root['output'] as Record<string, Object> | undefined;
    const audioObj = output !== undefined ? output['audio'] as Record<string, Object> | undefined : undefined;
    const url: string = audioObj !== undefined && typeof audioObj['url'] === 'string' ? audioObj['url'] as string : '';
    if (url.length === 0) {
      throw new Error('合成响应缺少音频地址');
    }
    const headers: rcp.RequestHeaders = { 'User-Agent': 'mybooks/1.0' };
    const session: rcp.Session = rcp.createSession({
      requestConfiguration: { transfer: { timeout: { connectMs: 10000, transferMs: 60000 } } },
    });
    let data: ArrayBuffer;
    try {
      const response: rcp.Response = await session.fetch(new rcp.Request(url, 'GET', headers));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw new Error(`音频下载 HTTP ${response.statusCode}`);
      }
      const buf: ArrayBuffer | undefined = response.body;
      if (buf === undefined || buf.byteLength === 0) {
        throw new Error('音频下载为空');
      }
      data = buf;
    } finally {
      session.close();
    }
    const dir: string = `${TalebookService.dataDir()}/tts`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const path: string = `${dir}/tts_${Date.now()}.${TTS_FORMAT}`;
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, data);
    } finally {
      fs.closeSync(file);
    }
    QwenAudioService.cleanupTtsCache(dir);
    return path;
  }

  /** 播报缓存只留最近 5 个（通话轮转每轮一个文件）。 */
  private static cleanupTtsCache(dir: string): void {
    try {
      const names: string[] = fs.listFileSync(dir);
      const files: string[] = [];
      for (let i = 0; i < names.length; i++) {
        if (names[i].startsWith('tts_')) {
          files.push(names[i]);
        }
      }
      files.sort();
      while (files.length > 5) {
        const oldest: string = files.shift() ?? '';
        if (oldest.length > 0) {
          fs.unlinkSync(`${dir}/${oldest}`);
        }
      }
    } catch (error) {
      hilog.warn(0x0000, TAG, 'cleanup: %{public}s', (error as BusinessError).message);
    }
  }

  // ————————————————— 播放（AVPlayer fd 模式，同 AudioPlaybackService 惯用法） —————————————————
  private static player: media.AVPlayer | null = null;
  private static playerFile: fs.File | null = null;
  private static playingPath: string = '';
  private static playResolve: ((ok: boolean) => void) | null = null;

  /** 播放本地音频直到播完（或被 stopPlayback 打断），返回是否自然播完。 */
  static async playFile(path: string): Promise<boolean> {
    QwenAudioService.stopPlayback();
    QwenAudioService.playingPath = path;
    const player: media.AVPlayer = await media.createAVPlayer();
    QwenAudioService.player = player;
    QwenAudioService.bindPlayerEvents(player);
    const opened: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    QwenAudioService.playerFile = opened;
    player.fdSrc = { fd: opened.fd };
    return await new Promise<boolean>((resolve: (v: boolean) => void): void => {
      QwenAudioService.playResolve = resolve;
    });
  }

  private static bindPlayerEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState): void => {
      if (state === 'initialized') {
        player.prepare().catch((error: BusinessError): void => {
          hilog.error(0x0000, TAG, 'prepare: %{public}s', error.message);
          QwenAudioService.finishPlay(false);
        });
      } else if (state === 'prepared') {
        player.play().catch((error: BusinessError): void => {
          hilog.error(0x0000, TAG, 'play: %{public}s', error.message);
          QwenAudioService.finishPlay(false);
        });
      } else if (state === 'completed') {
        QwenAudioService.finishPlay(true);
      }
    });
    player.on('error', (error: BusinessError): void => {
      hilog.error(0x0000, TAG, 'player error %{public}d %{public}s', error.code, error.message);
      QwenAudioService.finishPlay(false);
    });
  }

  /** 打断当前播报（用户插话/挂断）；playFile 的等待方拿到 false。 */
  static stopPlayback(): void {
    const player: media.AVPlayer | null = QwenAudioService.player;
    if (player === null) {
      return;
    }
    QwenAudioService.player = null;
    QwenAudioService.releasePlayer(player);
    const path: string = QwenAudioService.playingPath;
    QwenAudioService.playingPath = '';
    if (path.length > 0 && fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
    QwenAudioService.finishPlay(false);
  }

  private static releasePlayer(player: media.AVPlayer): void {
    player.off('stateChange');
    player.off('error');
    player.release().catch((): void => {});
    const file: fs.File | null = QwenAudioService.playerFile;
    if (file !== null) {
      QwenAudioService.playerFile = null;
      try {
        fs.closeSync(file);
      } catch (_error) {
        // fd 可能已被播放器回收
      }
    }
  }

  private static finishPlay(completed: boolean): void {
    const resolve: ((ok: boolean) => void) | null = QwenAudioService.playResolve;
    QwenAudioService.playResolve = null;
    const player: media.AVPlayer | null = QwenAudioService.player;
    if (player !== null && completed) {
      QwenAudioService.player = null;
      QwenAudioService.releasePlayer(player);
      const path: string = QwenAudioService.playingPath;
      QwenAudioService.playingPath = '';
      if (path.length > 0 && fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    }
    if (resolve !== null) {
      resolve(completed);
    }
  }
}
