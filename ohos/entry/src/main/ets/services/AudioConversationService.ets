// 语音对话（全屏通话模式）的能力层。ASR/TTS 均走系统 CoreSpeechKit：
// 网关实测无 /audio/speech 与 /audio/transcriptions（404），「只走 API/系统能力」约束下的唯一通道。
// 当前实现 probe() 能力探测（t1）；识别会话封装（t2）在此基础上扩展。
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ReaderTtsService } from './ReaderTtsService';

const TAG: string = 'AudioConversation';
/** 探测采样时长：足够触发 VAD 起始，又不至于让调试等待太久。 */
const PROBE_LISTEN_MS: number = 4000;
/** finish() 后等 onComplete/onError 的兜底上限（模拟器引擎可能不回回调）。 */
const PROBE_SETTLE_MS: number = 8000;

/** RecognitionListener 要求实现全部 5 个方法，ArkTS 对象字面量做不了半实现，用类桥接回调。 */
class ProbeListener implements speechRecognizer.RecognitionListener {
  onStartCb: (sessionId: string) => void = () => {};
  onResultCb: (text: string, isFinal: boolean) => void = () => {};
  onSettleCb: (outcome: string) => void = () => {};
  private settled: boolean = false;

  private settle(outcome: string): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    this.onSettleCb(outcome);
  }

  onStart(sessionId: string, eventMessage: string): void {
    hilog.info(0x0000, TAG, 'asr onStart %{public}s %{public}s', sessionId, eventMessage);
    this.onStartCb(sessionId);
  }

  onEvent(sessionId: string, eventCode: number, eventMessage: string): void {
    hilog.info(0x0000, TAG, 'asr onEvent %{public}d %{public}s', eventCode, eventMessage);
  }

  onResult(sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void {
    hilog.info(0x0000, TAG, 'asr onResult final=%{public}s %{public}s', `${result.isFinal}`, result.result);
    this.onResultCb(result.result, result.isFinal);
  }

  onComplete(sessionId: string, eventMessage: string): void {
    this.settle(`complete(${eventMessage})`);
  }

  onError(sessionId: string, errorCode: number, errorMessage: string): void {
    hilog.error(0x0000, TAG, 'asr onError %{public}d %{public}s', errorCode, errorMessage);
    this.settle(`error ${errorCode}(${errorMessage})`);
  }
}

export class AudioConversationService {
  /**
   * 能力探测（一次性诊断，非通话链路）：
   * ① TTS 朗读一句验证出声；② speechRecognizer.createEngine → startListening →
   * AudioCapturer 16k PCM 流喂 writeAudio → finish，汇总回调证据为可读字符串。
   * 任何一步不可用都如实返回原因，不抛异常（调用方是 UI Toast）。
   */
  static async probe(): Promise<string> {
    const parts: string[] = [];
    // —— TTS ——
    // hiai voice 进程冷启动时 createEngine 会超时(50008)，首次失败等 1.5s 再试。
    const tts = new ReaderTtsService();
    let ttsStarted = false;
    let ttsError = '';
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        ttsStarted = await tts.start(['音频能力探测开始'], 1.0, () => {});
        if (ttsStarted) {
          break;
        }
      } catch (error) {
        ttsError = (error as BusinessError).message ?? '';
      }
      await AudioConversationService.sleep(1500);
    }
    parts.push(`TTS=${ttsStarted ? 'started' : `fail${ttsError.length > 0 ? `(${ttsError})` : ''}`}`);
    // —— ASR ——
    // online 语义反直觉：d.ts 明确 0=在线、1=离线（本地引擎），模拟器只能 1。
    let engine: speechRecognizer.SpeechRecognitionEngine | null = null;
    try {
      engine = await speechRecognizer.createEngine({ language: 'zh-CN', online: 1 });
    } catch (error) {
      const e = error as BusinessError;
      parts.push(`ASR=create_fail_${e.code}(${e.message})`);
      return parts.join(' | ');
    }
    let capturer: audio.AudioCapturer | null = null;
    try {
      const heard: string[] = [];
      let startedSession = false;
      const listener = new ProbeListener();
      listener.onStartCb = (_sid: string): void => {
        startedSession = true;
      };
      listener.onResultCb = (text: string, isFinal: boolean): void => {
        heard.push(`${isFinal ? 'F' : 'P'}:${text}`);
      };
      engine.setListener(listener);
      const sessionId = 'probe_1';
      engine.startListening({
        sessionId: sessionId,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 },
      });
      // 麦克风采集与识别解耦：readData 原样灌流，引擎不可用时采集也照样起（分开归因）。
      capturer = await audio.createAudioCapturer({
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
        },
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 },
      });
      let fedBytes = 0;
      capturer.on('readData', (buffer: ArrayBuffer): void => {
        fedBytes += buffer.byteLength;
        try {
          engine?.writeAudio(sessionId, new Uint8Array(buffer));
        } catch (error) {
          hilog.warn(0x0000, TAG, 'writeAudio failed: %{public}s', (error as BusinessError).message);
        }
      });
      await capturer.start();
      await AudioConversationService.sleep(PROBE_LISTEN_MS);
      await capturer.stop();
      const settled = await new Promise<string>((resolve: (v: string) => void) => {
        const timer = setTimeout((): void => {
          resolve('timeout');
        }, PROBE_SETTLE_MS);
        listener.onSettleCb = (outcome: string): void => {
          clearTimeout(timer);
          resolve(outcome);
        };
        engine?.finish(sessionId);
      });
      await capturer.release();
      capturer = null;
      parts.push(`ASR=engine_ok onStart=${startedSession} fed=${fedBytes}B settle=${settled} heard=${heard.length > 0 ? heard.join(';') : 'none'}`);
    } catch (error) {
      const e = error as BusinessError;
      parts.push(`ASR=run_fail_${e.code}(${e.message})`);
    } finally {
      try {
        engine.shutdown();
      } catch (_error) {
        // shutdown 失败不影响探测结论
      }
      if (capturer !== null) {
        capturer.release().catch((): void => {});
      }
    }
    return parts.join(' | ');
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}
