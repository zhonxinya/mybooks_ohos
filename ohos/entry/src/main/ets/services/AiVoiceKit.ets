/**
 * 语音实时对话共享件：人设 prompt 与 realtime 工具执行（含权限闸门）。
 * 全屏通话页与对话页内嵌语音会话共用，保证两处语义一致（提取自 AiVoiceCallPage）。
 */
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { AiService } from './AiService';
import { AiTools } from './AiTools';
import { RealtimeCallService } from './RealtimeCallService';

/** 音色条目：id=网关 voice 参数值，label=设置页/AI 可见的中文名。 */
export interface AiVoiceTimbre {
  id: string;
  label: string;
}

/** realtime（qwen-audio-3.0-realtime 系）官方音色池；voice 仅会话首包生效，切换靠重建会话。 */
export const REALTIME_TIMBRES: AiVoiceTimbre[] = [
  { id: 'longanqian', label: '龙安浅（女声·默认）' },
  { id: 'longanlingxin', label: '龙安灵心（女声·知心温暖）' },
  { id: 'longanlingxi', label: '龙安灵溪（女声·可爱甜美）' },
  { id: 'longanxiaoxin', label: '龙安晓心（女声·亲切活泼）' },
  { id: 'longanlufeng', label: '龙安麓风（男声·明亮开朗）' },
];

/** 播报 TTS（qwen-audio-3.0-tts-plus）音色池：longanhuan_v3.6 板上实测可用，其余为文档 plus 系统音色。 */
export const TTS_TIMBRES: AiVoiceTimbre[] = [
  { id: 'longanhuan_v3.6', label: '龙安欢（女声·默认）' },
  { id: 'longanlingxin', label: '龙安灵心（女声·知心温暖）' },
  { id: 'longanlufeng', label: '龙安麓风（男声·明亮开朗）' },
];

export function timbreLabel(pool: AiVoiceTimbre[], id: string): string {
  for (let i = 0; i < pool.length; i++) {
    if (pool[i].id === id) {
      return pool[i].label;
    }
  }
  return id;
}

export function isKnownTimbre(pool: AiVoiceTimbre[], id: string): boolean {
  for (let i = 0; i < pool.length; i++) {
    if (pool[i].id === id) {
      return true;
    }
  }
  return false;
}

/** 语音场景专用人设：短、口语化、可直接朗读（不复用文字页 SYSTEM_PROMPT 的工具/书单内容）。 */
export const VOICE_SYSTEM_PROMPT: string =
  '你是阅读应用里的语音助手，正在和用户实时通话。回答口语化、简洁（一般一到三句），' +
  '会被直接朗读出来，因此不要使用 Markdown、列表、代码块或表情符号。' +
  '可以聊书、作者、阅读推荐，也可以日常问答；不确定就直说。' +
  '语气要随内容自然变化：讲悬疑紧张些、聊日常轻快些、安慰人时柔和些。';

/** realtime 会话 session.update 里追加的工具使用规则（与文字回路同语义的口语版）。 */
export const VOICE_TOOL_NOTE: string =
  '\n图书相关请求（找书、看书评、下载、加书单等）必须先调用工具查询再回答；' +
  '拿到工具结果后用一两句口语概括，不要逐条念 JSON，寒暄不要调用工具。' +
  '\n当场景明显适合另一种声线（如给孩子讲故事、用户点名要男声/温柔声、角色扮演）时，' +
  '可调用 set_voice 更换你的音色；换音色会让会话短暂重连，一小时内别反复换。' +
  '\n听到明确的偏好或纠正（「我喜欢…」「不对，其实是…」）时，用 save_memory 随手记一条简短事实，' +
  '与文字对话共用同一份长期记忆；遵守写操作确认规则，不重复记已有记忆。';

export class AiVoiceKit {
  /**
   * set_voice 生效通道：voice 只能在会话首包 session.update 设置（网关忽略后续修改），
   * 所以换音色=存配置+重建会话。页面在会话启动时注册重建闭包，挂断/离场清空。
   */
  static voiceSwitcher: (() => void) | null = null;

  /** 执行 set_voice：校验音色池→持久化→返回给模型的口语文案。非法音色返回错误说明不保存。 */
  static applySetVoice(argsJson: string): string {
    let voice: string = '';
    try {
      const obj: Record<string, Object> = JSON.parse(argsJson) as Record<string, Object>;
      voice = String(obj['voice'] ?? '');
    } catch (_error) {
      return 'set_voice 参数不是合法 JSON。';
    }
    if (!isKnownTimbre(REALTIME_TIMBRES, voice)) {
      const ids: string[] = [];
      for (let i = 0; i < REALTIME_TIMBRES.length; i++) {
        ids.push(`${REALTIME_TIMBRES[i].id}（${REALTIME_TIMBRES[i].label}）`);
      }
      return `音色 ${voice.length > 0 ? voice : '（空）'} 不可用。可选：${ids.join('、')}`;
    }
    AiService.saveRealtimeTimbre(voice);
    return `已切换到音色 ${timbreLabel(REALTIME_TIMBRES, voice)}，会话马上重连，新音色从下一句开始生效。`;
  }

  /** 申请麦克风权限（realtime 上行必需）；拒绝/异常返回 false，由页面提示。 */
  static async ensureMicPermission(uiContext: UIContext): Promise<boolean> {
    try {
      const context = uiContext.getHostContext() as common.UIAbilityContext;
      const at = abilityAccessCtrl.createAtManager();
      const grant = await at.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
      for (let i = 0; i < grant.authResults.length; i++) {
        if (grant.authResults[i] !== 0) {
          return false;
        }
      }
      return true;
    } catch (_error) {
      return false;
    }
  }

  /** 向语音侧过程显示上报一次活动（doing/done/rejected/failed）；页面没接线就静默跳过。 */
  private static report(onActivity: ((label: string, state: string) => void) | undefined,
    label: string, state: string): void {
    if (onActivity !== undefined) {
      onActivity(label, state);
    }
  }

  /**
   * 执行模型请求的工具（含确认闸门），结果回填 realtime 会话。
   * `uiContext` 用于确认弹窗；页面已退出时弹窗失败按拒绝收敛，绝不卡会话。
   * `onActivity`：语音侧工具过程显示接线。文字回路有活动时间线，语音页原本没有
   * 工具状态的落点，由两个页面各按自己的 UI 语义消费（通话页字幕行/对话页状态横幅）。
   */
  static async runTool(name: string, args: string, callId: string, uiContext: UIContext,
    onActivity?: (label: string, state: string) => void): Promise<void> {
    if (name === 'set_voice') {
      // 音色切换不经文字回路 dispatch：直接落配置并触发会话重建（重建闭包自带挂断+重开）
      AiVoiceKit.report(onActivity, '切换音色', 'doing');
      let out: string;
      try {
        out = AiVoiceKit.applySetVoice(args);
      } catch (error) {
        out = `set_voice 执行失败：${error}`;
      }
      RealtimeCallService.sendToolResult(callId, out);
      AiVoiceKit.report(onActivity, '切换音色',
        out.indexOf('已切换到音色') === 0 ? 'done' : 'failed');
      const switcher: (() => void) | null = AiVoiceKit.voiceSwitcher;
      if (out.indexOf('已切换到音色') === 0 && switcher !== null) {
        switcher();
      }
      return;
    }
    const label: string = AiService.toolLabelFor(name);
    AiVoiceKit.report(onActivity, label, 'doing');
    let output: string;
    let state: string = 'done';
    try {
      if (AiTools.needsConfirm(name)) {
        const permission: string = AiService.loadPermission();
        if (permission === 'readonly') {
          output = '当前为只读权限模式，写操作不可执行。';
          state = 'rejected';
        } else if (permission === 'confirm') {
          let allow: boolean = false;
          try {
            const dialog = await uiContext.getPromptAction().showDialog({
              title: '确认执行',
              message: `语音通话中，AI 请求执行：${label}\n${args.length > 200 ? `${args.substring(0, 200)}…` : args}`,
              buttons: [
                { text: '拒绝', color: '#F44336' },
                { text: '允许', color: '#4CAF50' },
              ],
            });
            allow = dialog.index === 1;
          } catch (_error) {
            allow = false;
          }
          output = allow ? await AiService.toolRunFor(name, args, callId) : '用户拒绝了该操作。';
          state = allow ? 'done' : 'rejected';
        } else {
          output = await AiService.toolRunFor(name, args, callId);
        }
      } else {
        output = await AiService.toolRunFor(name, args, callId);
      }
    } catch (error) {
      output = `工具执行失败：${error}`;
      state = 'failed';
    }
    RealtimeCallService.sendToolResult(callId, output);
    AiVoiceKit.report(onActivity, label, state);
  }
}
