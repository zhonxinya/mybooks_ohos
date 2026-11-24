/**
 * AiService 网关工具回路（拆分自 AiService.ets）：chatViaGateway 直连 JSON-RPC 形态、
 * runToolLoop 多轮编排（含 ask_user/确认闸门）、流式增量累积与解析。
 */
import { OpenAI } from '@iuroc/openai';
import { rcp } from '@kit.RemoteCommunicationKit';
import type { ChatCompletionChunk } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import type { ChatCompletionCreateParamsBase } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import { AiTools } from './AiTools';
import type { AiPermissionMode } from './AiTools';
import type { AiToolDefinition } from './AiToolsDefs';
import type { AiMessage, AiConfig, AiAbortHandle } from './AiService';
import type { AiSessionHolder } from './AiServiceHttp';
import { AiServiceConfig, MAX_TOOL_ROUNDS, MAX_GATEWAY_ATTEMPTS, MAX_TOOL_SLOTS, TOOL_FOLD_KEEP, TOOL_FOLD_HEAD } from './AiServiceConfig';
import { AiServiceHttp } from './AiServiceHttp';
import { mergeUsage, parseUsage, TRACE_FULL_ROUNDS } from './AiChatModel';
import type { AiTokenUsage, ToolTraceCall, ToolTraceRound } from './AiChatModel';

export class AiServiceGateway {
  /**
   * AiMessage → 协议消息（#1623 统一回放点，两通道共用）：带 toolTrace 的 assistant
   * 气泡展开为 assistant(tool_calls)+tool×N 历史，再跟最终文本 assistant——模型因此
   * 看得到「上一轮已经做过什么」，不会重复执行写操作。
   * 中断轮次可能缺尾部 result，tool_calls 按已记录的 calls 生成（天然截断，协议合法）。
   */
  static messagesToGw(messages: AiMessage[]): GatewayMessage[] {
    const out: GatewayMessage[] = [];
    // #1628：全局轮数计数——仅最近 TRACE_FULL_ROUNDS 轮全量展开，更早轮压成一行摘要省 token
    let totalRounds: number = 0;
    for (let i = 0; i < messages.length; i++) {
      const t: ToolTraceRound[] | undefined = messages[i].toolTrace;
      if (t !== undefined) {
        totalRounds += t.length;
      }
    }
    let seen: number = 0;
    for (let i = 0; i < messages.length; i++) {
      const m: AiMessage = messages[i];
      const trace: ToolTraceRound[] | undefined = m.toolTrace;
      // #1624：user 泡的痕迹=该问题之后的工具轮，展开排在问题文本后
      if (m.role === 'user') {
        out.push({ role: m.role, content: AiServiceHttp.gatewayContent(m) });
      }
      if (trace !== undefined) {
        for (let r = 0; r < trace.length; r++) {
          const rt: ToolTraceRound = trace[r];
          const full: boolean = seen >= totalRounds - TRACE_FULL_ROUNDS;
          seen++;
          if (!full) {
            // 旧轮：模型仍知道「做过什么」，但不背全量 payload 的 token
            const names: string[] = [];
            for (let c = 0; c < rt.calls.length; c++) {
              names.push(rt.calls[c].name);
            }
            out.push({ role: 'assistant', content: `早前工具轮已执行：${names.join('、')}（详情略）` });
            continue;
          }
          const calls: Record<string, Object>[] = [];
          for (let c = 0; c < rt.calls.length; c++) {
            const fn: Record<string, Object> = { 'name': rt.calls[c].name, 'arguments': rt.calls[c].args };
            calls.push({ 'id': rt.calls[c].id, 'type': 'function', 'function': fn });
          }
          out.push({ role: 'assistant', content: rt.text, tool_calls: calls });
          for (let c = 0; c < rt.calls.length; c++) {
            out.push({ role: 'tool', content: rt.calls[c].result, tool_call_id: rt.calls[c].id });
          }
        }
      }
      const finalContent: Object = AiServiceHttp.gatewayContent(m);
      // 错误泡回放 content 为空：有痕迹时不再推空 assistant 文本消息（图文数组恒非空不受影响）
      const emptyFinal: boolean = typeof finalContent === 'string' && finalContent.length === 0;
      if (m.role !== 'user' && (!emptyFinal || trace === undefined)) {
        out.push({ role: m.role, content: finalContent });
      }
    }
    return out;
  }

  static async chatViaGateway(config: AiConfig, apiKey: string, messages: AiMessage[],
    maxTokens: number, session: rcp.Session, tools: AiToolDefinition[] | null,
    permission: AiPermissionMode,
    isAborted: (() => boolean) | null,
    onTool: ((label: string, name: string) => void) | null,
    onConfirm: ((label: string, argsSummary: string) => Promise<boolean>) | null,
    onResult: ((name: string, label: string, text: string, callId: string) => void) | null,
    onReasoning: ((text: string) => void) | null,
    onAsk: ((question: string, options: string[]) => Promise<string>) | null,
    usageBox: AiTokenUsage[] | null,
    traceBox: ToolTraceRound[] | null): Promise<string> {
    const headers: rcp.RequestHeaders = {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'x-opencode-session': AiServiceHttp.opencodeSessionId(),
    };
    const gwMessages: GatewayMessage[] = AiServiceGateway.messagesToGw(messages);
    const url: string = `${AiServiceHttp.normalizeBaseUrl(config.baseUrl)}/chat/completions`;
    // 网关传输：整包 fetch + 退避重试（网络抖动/429/5xx），null=用户中断
    const transport = async (attach: AiToolDefinition[] | null): Promise<GatewayReply | null> => {
      const payload: Record<string, Object> = {
        'model': config.model,
        'messages': gwMessages,
        'stream': false,
        'temperature': config.temperature,
        'max_tokens': maxTokens,
      };
      if (attach !== null && attach.length > 0) {
        payload['tools'] = attach;
      }
      const effort: string = AiServiceConfig.loadReasoningEffort();
      if (effort !== 'default') {
        payload['reasoning_effort'] = effort;
      }
      AiServiceHttp.applyNativeSearch(payload, config);
      const request: rcp.Request = new rcp.Request(url, 'POST', headers, JSON.stringify(payload));
      // 单轮请求失败直接 throw 会让整条多轮回复报废——
      // 用户侧表现为「工具调用失败不重试、会话中断」。退避重试，其余 4xx 无意义不重试。
      let statusCode: number = 0;
      let text: string = '';
      let lastError: string = '';
      for (let attempt = 0; attempt < MAX_GATEWAY_ATTEMPTS; attempt++) {
        if (attempt > 0) {
          if (isAborted !== null && isAborted()) {
            return null;
          }
          await AiServiceHttp.sleep(attempt * 1000);
        }
        try {
          const response: rcp.Response = await session.fetch(request);
          statusCode = response.statusCode;
          text = AiServiceHttp.responseBodyText(response.body);
        } catch (error) {
          lastError = AiServiceHttp.friendlyMessage(error instanceof Error ? error.message : String(error));
          continue;
        }
        if (statusCode >= 200 && statusCode < 300) {
          break;
        }
        if (statusCode !== 429 && statusCode < 500) {
          throw new Error(AiServiceHttp.httpErrorText(statusCode, text));
        }
        lastError = AiServiceHttp.httpErrorText(statusCode, text);
      }
      if (statusCode < 200 || statusCode >= 300) {
        throw new Error(lastError);
      }
      const reply: GatewayReply = AiServiceGateway.parseGatewayReply(text);
      // 跨工具轮用量累加进盒（#1514）：与 sessionBox 同法，签名不再扩散
      if (usageBox !== null && reply.usage !== null) {
        if (usageBox.length === 0) {
          usageBox.push({ prompt: 0, completion: 0, total: 0 });
        }
        mergeUsage(usageBox[0], reply.usage);
      }
      return reply;
    };
    try {
      return await AiServiceGateway.runToolLoop(gwMessages, transport, tools, permission, isAborted,
        onTool, onConfirm, onResult, onReasoning, onAsk, traceBox);
    } finally {
      session.close();
      // 中断/异常可能留下未取配对条目，回路收尾一律清理
      AiTools.clearPendingBooks();
    }
  }

  /**
   * 上下文预算：折叠旧 tool 结果。回路每轮全量重发 gwMessages，tool 结果随轮次线性堆积
   * （板上实测 3 本书逐本搜索单轮入 token 11 万+，自动续段后更甚）。最近 TOOL_FOLD_KEEP
   * 条保持全文，更早的截到 TOOL_FOLD_HEAD 字符并附「可重查」提示——旧结果模型已消化，
   * 头部片段足够引用 id/关键行；确需全文时重新调用工具即可。幂等：已折叠条目跳过；
   * 只动字符串 content，多模态数组原样保留。
   */
  static foldStaleToolResults(gwMessages: GatewayMessage[]): void {
    let seen: number = 0;
    for (let i = gwMessages.length - 1; i >= 0; i--) {
      const m: GatewayMessage = gwMessages[i];
      if (m.role !== 'tool') {
        continue;
      }
      seen++;
      if (seen <= TOOL_FOLD_KEEP || typeof m.content !== 'string') {
        continue;
      }
      const content: string = m.content;
      if (content.length <= TOOL_FOLD_HEAD || content.indexOf('…（已折叠 ') >= 0) {
        continue;
      }
      m.content = `${content.substring(0, TOOL_FOLD_HEAD)}…（已折叠 ${content.length - TOOL_FOLD_HEAD} 字符，如需完整内容可重新调用工具查询）`;
    }
  }

  /**
   * function calling 回路主体（网关整包与 SDK 流式两个传输层共用）：
   * 请求 → 有 tool_calls 则执行并回填上下文 → 再请求，直到文本回答或用户中断
   * （任务总轮次不设上限，段预算触顶自动续段）。
   * transport 返回 null 表示用户已中断。
   */
  static async runToolLoop(gwMessages: GatewayMessage[],
    transport: (attach: AiToolDefinition[] | null) => Promise<GatewayReply | null>,
    tools: AiToolDefinition[] | null, permission: AiPermissionMode,
    isAborted: (() => boolean) | null,
    onTool: ((label: string, name: string) => void) | null,
    onConfirm: ((label: string, argsSummary: string) => Promise<boolean>) | null,
    onResult: ((name: string, label: string, text: string, callId: string) => void) | null,
    onReasoning: ((text: string) => void) | null,
    onAsk: ((question: string, options: string[]) => Promise<string>) | null,
    traceBox: ToolTraceRound[] | null): Promise<string> {
    // 分段预算：每段 12 轮 + 1 轮收尾；触顶且模型仍在调工具时无限自动续段
    // （不设任务总轮次上限），而不是把半截任务甩回用户
    let limit: number = MAX_TOOL_ROUNDS;
    let segmentStart: number = 0;
    let autoContinues: number = 0;
    for (let round = 0; round <= limit; round++) {
      if (isAborted !== null && isAborted()) {
        return '';
      }
      // 本轮发送前折叠过期 tool 结果（上下文预算；幂等操作，仅改写旧条目尾部）
      AiServiceGateway.foldStaleToolResults(gwMessages);
      // 每段剩 3 轮时提醒模型收敛：多数截断本可避免（软着陆只是兜底，别靠它）
      if (round - segmentStart === MAX_TOOL_ROUNDS - 3) {
        gwMessages.push({
          role: 'user',
          content: '（内部提示）本轮预算的工具调用仅剩 3 轮。请尽快汇总已获得的结果准备最终回答，不要再发起非必要的工具调用。',
        });
      }
      // 每段最后一轮不带 tools，逼模型给最终回答而不是继续调工具
      const attach: AiToolDefinition[] | null = round - segmentStart < MAX_TOOL_ROUNDS ? tools : null;
      const reply: GatewayReply | null = await transport(attach);
      if (reply === null) {
        return '';
      }
      if (reply.reasoning.length > 0 && onReasoning !== null && !reply.reasoningStreamed) {
        // 整包模式（rcp/网关 transport）：本轮思考一次性给出；SDK 流式轮已在批内增量上报
        onReasoning(reply.reasoning);
      }
      if (reply.calls !== null && reply.calls.length > 0) {
        if (round - segmentStart === MAX_TOOL_ROUNDS) {
          // 不限制任务轮次（用户指令 2026-11-24）：段预算触顶且模型仍在调工具时
          // **无限自动续段**——预算滚动重开、任务上下文原样延续，直到模型自己给出
          // 文本回答或用户中断；旧的 5 段续段上限与 60 轮硬报错已移除。
          // 死循环兜底只剩三层：段尾强制无 tools 收尾轮 + 每段收敛提示 + 用户中断。
          autoContinues += 1;
          segmentStart = round + 1;
          limit = segmentStart + MAX_TOOL_ROUNDS;
          gwMessages.push({
            role: 'user',
            content: '（内部提示）工具调用预算已自动续期，请继续原任务，不要道歉也不要从头重做已完成的步骤。',
          });
          if (onResult !== null) {
            // 直接以完成态入活动时间线（endActivity 无 doing 条目时补记），
            // 不走 onTool 避免留下永不翻转的「进行中」项
            onResult('auto_continue', `工具轮次已用满，自动继续（第 ${autoContinues + 1} 段）`, '', '');
          }
          continue;
        }
        const calls: Record<string, Object>[] = [];
        for (let i = 0; i < reply.calls.length; i++) {
          const c: GatewayToolCall = reply.calls[i];
          const fn: Record<string, Object> = { 'name': c.name, 'arguments': c.arguments };
          const call: Record<string, Object> = { 'id': c.id, 'type': 'function', 'function': fn };
          calls.push(call);
        }
        gwMessages.push({ role: 'assistant', content: reply.content, tool_calls: calls });
        // #1623 痕迹登记：round 随轮开始入箱，calls 逐项补 result；
        // 中断产生的半轮在回放时按已记录 calls 截断，协议仍合法。
        // #1662：本轮思考随行记录，历史按轮拆块显示（不再全挤气泡顶部一个思维块）
        const rt: ToolTraceRound = { text: reply.content, calls: [],
          reasoning: reply.reasoning.length > 0 ? reply.reasoning : undefined };
        if (traceBox !== null) {
          traceBox.push(rt);
        }
        // 同轮全是免确认（只读）工具 → Promise.all 并发：网络类工具单项要几秒，
        // 串行白白叠加等待。含写工具保持串行——确认闸门与执行顺序必须和模型输出一致。
        let allAuto: boolean = true;
        for (let i = 0; i < reply.calls.length; i++) {
          // ask_user 需要停下来等用户点选，不能与其他工具并发执行
          if (AiTools.needsConfirm(reply.calls[i].name) || reply.calls[i].name === 'ask_user') {
            allAuto = false;
            break;
          }
        }
        if (allAuto) {
          const labels: string[] = [];
          const tasks: Promise<string>[] = [];
          for (let i = 0; i < reply.calls.length; i++) {
            const c: GatewayToolCall = reply.calls[i];
            const l: string = AiServiceHttp.toolLabelFor(c.name);
            labels.push(l);
            if (onTool !== null) {
              onTool(l, c.name);
            }
            tasks.push(AiServiceHttp.toolRunFor(c.name, c.arguments, c.id));
          }
          const results: string[] = await Promise.all(tasks);
          for (let i = 0; i < results.length; i++) {
            gwMessages.push({ role: 'tool', content: results[i], tool_call_id: reply.calls[i].id });
            rt.calls.push({ id: reply.calls[i].id, name: reply.calls[i].name,
              args: reply.calls[i].arguments, result: results[i] });
            if (onResult !== null) {
              onResult(reply.calls[i].name, labels[i], results[i], reply.calls[i].id);
            }
          }
          if (isAborted !== null && isAborted()) {
            return '';
          }
          continue;
        }
        for (let i = 0; i < reply.calls.length; i++) {
          const c: GatewayToolCall = reply.calls[i];
          let label: string = AiServiceHttp.toolLabelFor(c.name);
          if (c.name === 'ask_user') {
            // 反问工具不落执行器：把问题与选项抛给界面等待点选，答复作为工具结果回填。
            // 没人能答（无卡片渠道/异常）按跳过处理，模型据此收敛而不是反复追问。
            if (onTool !== null) {
              onTool(label, c.name);
            }
            let answer: string = '';
            if (onAsk !== null) {
              const parsed: AskPayload = AiServiceGateway.parseAskArgs(c.arguments);
              try {
                answer = await onAsk(parsed.question, parsed.options);
              } catch (_error) {
                answer = '';
              }
            }
            const askResult: string = answer.length > 0
              ? `用户选择了「${answer}」`
              : '用户跳过了该问题（未作答）。请基于已有信息谨慎继续，不要反复追问';
            gwMessages.push({ role: 'tool', content: askResult, tool_call_id: c.id });
            rt.calls.push({ id: c.id, name: c.name, args: c.arguments, result: askResult });
            if (onResult !== null) {
              onResult(c.name, label, askResult, c.id);
            }
            if (isAborted !== null && isAborted()) {
              return '';
            }
            continue;
          }
          if (AiTools.needsConfirm(c.name)) {
            if (permission === 'readonly') {
              // 只读模式 tools 里本就没有写工具；走到这里说明模型幻觉调用，回路层同样挡下
              const blocked: string = '当前为只读权限模式，写操作不可执行';
              gwMessages.push({ role: 'tool', content: blocked, tool_call_id: c.id });
              rt.calls.push({ id: c.id, name: c.name, args: c.arguments, result: blocked });
              if (onResult !== null) {
                onResult(c.name, label, blocked, c.id);
              }
              continue;
            }
            if (permission === 'confirm') {
              // 写工具先过用户确认闸门；没人能确认（onConfirm 缺省）就一律拒绝
              let approved: boolean = false;
              if (onConfirm !== null) {
                approved = await onConfirm(label, c.arguments);
              }
              if (!approved) {
                gwMessages.push({ role: 'tool', content: '用户拒绝了该操作', tool_call_id: c.id });
                rt.calls.push({ id: c.id, name: c.name, args: c.arguments, result: '用户拒绝了该操作' });
                if (onResult !== null) {
                  onResult(c.name, label, '用户拒绝了该操作', c.id);
                }
                continue;
              }
            } else {
              // 自动放行：不弹确认，活动时间线标注执行方式
              label = `${label}（自动执行）`;
            }
          }
          if (onTool !== null) {
            onTool(label, c.name);
          }
          const result: string = await AiServiceHttp.toolRunFor(c.name, c.arguments, '');
          gwMessages.push({ role: 'tool', content: result, tool_call_id: c.id });
          rt.calls.push({ id: c.id, name: c.name, args: c.arguments, result: result });
          if (onResult !== null) {
            onResult(c.name, label, result, c.id);
          }
          if (isAborted !== null && isAborted()) {
            return '';
          }
        }
        continue;
      }
      if (reply.content.length === 0) {
        throw new Error('AI 返回内容为空，请检查模型是否可用');
      }
      return reply.content;
    }
    return '';
  }

  /**
   * 解析 ask_user 参数：问题 + 候选项。options 约定为顿号分隔串，但模型常交英文逗号/
   * 分号甚至 JSON 数组，这里全部归一为顿号再拆分，最多取 6 项、去空白。
   */
  static parseAskArgs(argsJson: string): AskPayload {
    let question: string = '';
    const options: string[] = [];
    try {
      const obj: Record<string, Object> = JSON.parse(argsJson) as Record<string, Object>;
      const qRaw: Object | undefined = obj['question'];
      if (typeof qRaw === 'string') {
        question = qRaw as string;
      }
      let text: string = '';
      const oRaw: Object | undefined = obj['options'];
      if (typeof oRaw === 'string') {
        text = oRaw as string;
      } else if (Array.isArray(oRaw)) {
        const parts: string[] = [];
        for (const it of oRaw as Object[]) {
          if (typeof it === 'string') {
            parts.push(it as string);
          }
        }
        text = parts.join('、');
      }
      text = text.replace(/，/g, '、').replace(/,/g, '、')
        .replace(/；/g, '、').replace(/;/g, '、');
      for (const seg of text.split('、')) {
        const s: string = seg.trim();
        if (s.length > 0 && options.length < 6) {
          options.push(s);
        }
      }
    } catch (_error) {
      // 参数坏 JSON：返回空壳，卡片只剩问题文案，用户仍可跳过
    }
    return { question: question, options: options };
  }

  /**
   * SDK 流式传输层：单轮 stream 请求，正文经 onDelta 打字机回调，
   * 同时运行时累积 tool_calls 分片（SDK onData 的 chunk 是 JSON.parse 透传，
   * 与 reasoning_content 同源——类型层没声明不等于运行时没带）。
   * 分片按 OpenAI 标准：首片带 id/name，后续片按 index 续 arguments。
   * 返回 null 表示用户中断。
   */
  /**
   * 解析一批流式 chunk：正文/思考累积回调，tool_calls 按 index 归槽。
   * 全部访问前判空、index 钳制——服务商畸形分片（缺 delta、负/巨 index）
   * 在这里抛异常等于原生回调栈崩溃，绝不允许外逃。
   */
  static consumeStreamChunks(chunks: ChatCompletionChunk[], slots: GatewayToolCall[],
    reply: GatewayReply, onDelta: (text: string) => void,
    onReasoning: ((text: string) => void) | null): void {
    let piece: string = '';
    let think: string = '';
    for (let i = 0; i < chunks.length; i++) {
      const chunk: Object | undefined = chunks[i] as Object;
      if (chunk === undefined || chunk === null || typeof chunk !== 'object') {
        continue;
      }
      const choices: Object | undefined = (chunk as Record<string, Object>)['choices'];
      if (!Array.isArray(choices) || (choices as Object[]).length === 0) {
        // include_usage 尾包（#1514）：choices 为空、usage 在顶层；跨轮在 reply.usage 上累加
        const u = parseUsage((chunk as Record<string, Object>)['usage']);
        if (u !== null) {
          if (reply.usage === null) {
            const zero: AiTokenUsage = { prompt: 0, completion: 0, total: 0 };
            reply.usage = zero;
          }
          mergeUsage(reply.usage, u);
        }
        continue;
      }
      const first: Object = (choices as Object[])[0];
      if (first === undefined || first === null || typeof first !== 'object') {
        continue;
      }
      const deltaRaw: Object | undefined = (first as Record<string, Object>)['delta'];
      if (deltaRaw === undefined || deltaRaw === null || typeof deltaRaw !== 'object') {
        // 尾包常见形态：只有 finish_reason 没有 delta
        continue;
      }
      const deltaObj: Record<string, Object> = deltaRaw as Record<string, Object>;
      const content: Object | undefined = deltaObj['content'];
      if (typeof content === 'string') {
        piece += content;
      }
      const reasoning: Object | undefined = deltaObj['reasoning_content'];
      if (typeof reasoning === 'string') {
        think += reasoning;
      }
      const tcs: Object | undefined = deltaObj['tool_calls'];
      if (Array.isArray(tcs)) {
        const list: Object[] = tcs as Object[];
        for (let j = 0; j < list.length; j++) {
          const tc: Object = list[j];
          if (tc === null || typeof tc !== 'object') {
            continue;
          }
          const rec: Record<string, Object> = tc as Record<string, Object>;
          const idxRaw: Object | undefined = rec['index'];
          let idx: number = typeof idxRaw === 'number' ? idxRaw : slots.length;
          if (idx < 0 || idx >= MAX_TOOL_SLOTS) {
            // 非法 index（异常流/乱码）：并入末槽，slots 绝不无界扩容
            idx = slots.length > 0 ? slots.length - 1 : 0;
          }
          const fn: Object | undefined = rec['function'];
          const fnRec: Record<string, Object> | null =
            fn !== undefined && fn !== null && typeof fn === 'object' ? fn as Record<string, Object> : null;
          const idPiece: string = typeof rec['id'] === 'string' ? rec['id'] as string : '';
          const namePiece: string = fnRec !== null && typeof fnRec['name'] === 'string' ?
            fnRec['name'] as string : '';
          const argPiece: string = fnRec !== null && typeof fnRec['arguments'] === 'string' ?
            fnRec['arguments'] as string : '';
          while (slots.length <= idx) {
            slots.push({ id: '', name: '', arguments: '' });
          }
          if (idPiece.length > 0) {
            slots[idx].id = idPiece;
          }
          if (namePiece.length > 0) {
            slots[idx].name += namePiece;
          }
          slots[idx].arguments += argPiece;
        }
      }
    }
    // #1667：本函数按批调用、think 是批内增量——回调=增量语义（store 拼接显示）；
    // reply 每轮新建，+= 聚合出本轮整段供痕迹按轮固化（与 transport 整包对齐）
    if (think.length > 0 && onReasoning !== null) {
      onReasoning(think);
    }
    reply.reasoning += think;
    if (piece.length > 0) {
      reply.content += piece;
      onDelta(piece);
    }
  }

  static sdkStreamRound(client: OpenAI, config: AiConfig, gwMessages: GatewayMessage[],
    maxTokens: number, attach: AiToolDefinition[] | null, handle: AiAbortHandle,
    onDelta: (text: string) => void, onReasoning: ((text: string) => void) | null,
    sessionBox: AiSessionHolder[]): Promise<GatewayReply | null> {
    return new Promise<GatewayReply | null>((resolve, reject): void => {
      const reply: GatewayReply = { content: '', calls: null, reasoning: '', usage: null };
      const slots: GatewayToolCall[] = [];
      let settled: boolean = false;
      const streamOptions: Record<string, Object> = { 'include_usage': true };
      const payload: Record<string, Object> = {
        'model': config.model,
        'messages': gwMessages,
        'stream': true,
        'stream_options': streamOptions,
        'temperature': config.temperature,
        'max_tokens': maxTokens,
      };
      if (attach !== null && attach.length > 0) {
        payload['tools'] = attach;
      }
      const effort: string = AiServiceConfig.loadReasoningEffort();
      if (effort !== 'default') {
        payload['reasoning_effort'] = effort;
      }
      AiServiceHttp.applyNativeSearch(payload, config);
      const result = client.chat.completions.create(
        payload as Object as ChatCompletionCreateParamsBase, {
          onData: (chunks: ChatCompletionChunk[]): void => {
            if (handle.aborted || settled) {
              return;
            }
            // 本回调是 SDK（napi）→JS 的落点：这里抛出的未捕获异常不会进
            // Promise 链，而是沿原生栈直接终止应用（用户侧=聊天崩溃退出）。
            // 故解析整体包底：畸形 chunk 只丢当条，宁可少一段打字机。
            try {
              AiServiceGateway.consumeStreamChunks(chunks, slots, reply, onDelta, onReasoning);
            } catch (_error) {
              // 服务商畸形分片静默跳过
            }
          },
          onError: (error: Error): void => {
            if (!settled) {
              settled = true;
              reject(new Error(AiServiceHttp.friendlyMessage(error.message)));
            }
          },
        });
      sessionBox[0] = result.session as AiSessionHolder;
      result.response.then((response): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (handle.aborted) {
          resolve(null);
          return;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          reject(new Error(AiServiceHttp.httpErrorText(response.statusCode,
            AiServiceHttp.responseText(response.body))));
          return;
        }
        reply.calls = slots.length > 0 ? slots : null;
        // #1667：思考已随 onData 分批增量上报（consumeStreamChunks），标记防整包双计
        reply.reasoningStreamed = true;
        resolve(reply);
      }).catch((error: Error): void => {
        if (!settled) {
          settled = true;
          reject(new Error(AiServiceHttp.friendlyMessage(error.message)));
        }
      });
    });
  }

  /** 解析网关整包响应：正文 + tool_calls（不依赖 SDK 的 ChatCompletionMessage 类型）。 */
  static parseGatewayReply(raw: string): GatewayReply {
    const reply: GatewayReply = { content: '', calls: null, reasoning: '', usage: null };
    if (raw.length === 0) {
      return reply;
    }
    let root: Record<string, Object>;
    try {
      root = JSON.parse(raw) as Record<string, Object>;
    } catch (_error) {
      throw new Error('AI 响应解析失败');
    }
    const errorObj = root['error'] as Record<string, Object> | undefined;
    if (errorObj !== undefined) {
      const message = errorObj['message'];
      if (typeof message === 'string') {
        throw new Error(message as string);
      }
    }
    // 整包通道的 usage 在顶层（#1514）：早于 choices 检查取，异常包也不丢计量
    reply.usage = parseUsage(root['usage']);
    const choices = root['choices'] as Object[] | undefined;
    if (choices === undefined || choices.length === 0) {
      return reply;
    }
    const first = choices[0] as Record<string, Object>;
    const message = first['message'] as Record<string, Object> | undefined;
    if (message === undefined) {
      return reply;
    }
    const content = message['content'];
    reply.content = typeof content === 'string' ? content as string : '';
    const reasoning = message['reasoning_content'];
    reply.reasoning = typeof reasoning === 'string' ? reasoning as string : '';
    const rawCalls = message['tool_calls'] as Object[] | undefined;
    if (rawCalls === undefined || rawCalls.length === 0) {
      return reply;
    }
    const calls: GatewayToolCall[] = [];
    for (let i = 0; i < rawCalls.length; i++) {
      const c = rawCalls[i] as Record<string, Object>;
      const fn = c['function'] as Record<string, Object> | undefined;
      if (fn === undefined) {
        continue;
      }
      const id = c['id'];
      const name = fn['name'];
      const args = fn['arguments'];
      calls.push({
        id: typeof id === 'string' ? id as string : '',
        name: typeof name === 'string' ? name as string : '',
        arguments: typeof args === 'string' ? args as string : '{}',
      });
    }
    reply.calls = calls.length > 0 ? calls : null;
    return reply;
  }

  /** 容错用户输入：去掉末尾 `/chat/completions` 与多余斜杠，SDK 只接受 base URL。 */
}

/**
 * 网关通道专用消息：只有 chatViaGateway 直连时会用到 tool_calls / tool_call_id，
 * 字段名对齐 OpenAI 协议（回填给服务端时必须一致）。
 */
export interface GatewayMessage {
  role: string;
  /** 纯文本或 OpenAI 多模态 content 数组（带图时）。 */
  content?: Object;
  tool_calls?: Record<string, Object>[];
  tool_call_id?: string;
}

/** 响应里的一条工具调用（已拍平 function 嵌套）。 */
export interface GatewayToolCall {
  id: string;
  name: string;
  arguments: string;
}

/** 整包响应的解析结果。 */
export interface GatewayReply {
  content: string;
  calls: GatewayToolCall[] | null;
  /** 推理模型的思考过程（OpenAI 兼容字段 reasoning_content，整包模式一次给全）。 */
  reasoning: string;
  /** #1667：SDK 流式轮已按批增量回调 onReasoning，runToolLoop 不得再整包重发（双计）。 */
  reasoningStreamed?: boolean;
  /** 本次请求的 token 用量（#1514）；服务商没回传 usage 时为 null。 */
  usage: AiTokenUsage | null;
}


/** ask_user 参数解析结果：问题 + 拆好的候选项。 */
export interface AskPayload {
  question: string;
  options: string[];
}

