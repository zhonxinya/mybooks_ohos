/**
 * 语音实时对话共享件：人设 prompt 与 realtime 工具执行（含权限闸门）。
 * 全屏通话页与对话页内嵌语音会话共用，保证两处语义一致（提取自 AiVoiceCallPage）。
 */
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { AiService } from './AiService';
import { AiTools } from './AiTools';
import { RealtimeCallService } from './RealtimeCallService';

/** 语音场景专用人设：短、口语化、可直接朗读（不复用文字页 SYSTEM_PROMPT 的工具/书单内容）。 */
export const VOICE_SYSTEM_PROMPT: string =
  '你是阅读应用里的语音助手，正在和用户实时通话。回答口语化、简洁（一般一到三句），' +
  '会被直接朗读出来，因此不要使用 Markdown、列表、代码块或表情符号。' +
  '可以聊书、作者、阅读推荐，也可以日常问答；不确定就直说。';

/** realtime 会话 session.update 里追加的工具使用规则（与文字回路同语义的口语版）。 */
export const VOICE_TOOL_NOTE: string =
  '\n图书相关请求（找书、看书评、下载、加书单等）必须先调用工具查询再回答；' +
  '拿到工具结果后用一两句口语概括，不要逐条念 JSON，寒暄不要调用工具。';

export class AiVoiceKit {
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

  /**
   * 执行模型请求的工具（含确认闸门），结果回填 realtime 会话。
   * `uiContext` 用于确认弹窗；页面已退出时弹窗失败按拒绝收敛，绝不卡会话。
   */
  static async runTool(name: string, args: string, callId: string, uiContext: UIContext): Promise<void> {
    let output: string;
    try {
      if (AiTools.needsConfirm(name)) {
        const permission: string = AiService.loadPermission();
        if (permission === 'readonly') {
          output = '当前为只读权限模式，写操作不可执行。';
        } else if (permission === 'confirm') {
          const label: string = AiTools.toolLabel(name);
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
          output = allow ? await AiTools.execute(name, args, callId) : '用户拒绝了该操作。';
        } else {
          output = await AiTools.execute(name, args, callId);
        }
      } else {
        output = await AiTools.execute(name, args, callId);
      }
    } catch (error) {
      output = `工具执行失败：${error}`;
    }
    RealtimeCallService.sendToolResult(callId, output);
  }
}
