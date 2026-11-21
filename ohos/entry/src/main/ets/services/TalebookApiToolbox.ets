/**
 * TalebookApi 工具箱域（拆分自 TalebookApi.ets，800 行门禁）：插件商店与生命周期、mimoTts 转码/克隆/提示词、epub 美化/压缩/拆分、繁简转换、TXT 编码、文本替换、Bookbarn 接收端。
 */
import { TalebookCoreService } from './TalebookCoreService';
import { AdminToolListResponse, ApiMessageResult, BookBarnApplyTokenResponse, EpubBeautifyRunOptions, MimoTtsClonesResponse, MimoTtsConfigResponse, MimoTtsConvertRequest, MimoTtsPromptsResponse, MimoTtsTestRequest, ToolboxDataResponse, ToolboxStoreIndexResponse, ToolboxTaskProgressResponse } from './TalebookApiTypes';

export class TalebookApiToolbox {
  static async getAdminToolList(includeDisabled: boolean = false): Promise<AdminToolListResponse> {
    const path = includeDisabled ? '/api/toolbox/list?include_disabled=1' : '/api/toolbox/list';
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as AdminToolListResponse;
  }

  /** 启用/禁用工具（POST /api/toolbox/:id/enable|disable）。 */
  static async adminToolAction(toolId: string, action: string): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.adminToolAction(toolId, action);
    return JSON.parse(raw) as ApiMessageResult;
  }

  static async enableToolboxTool(toolId: string): Promise<ApiMessageResult> {
    return TalebookApiToolbox.adminToolAction(toolId, 'enable');
  }

  static async disableToolboxTool(toolId: string): Promise<ApiMessageResult> {
    return TalebookApiToolbox.adminToolAction(toolId, 'disable');
  }

  /** 卸载工具（DELETE /api/toolbox/:id）。 */
  static async uninstallToolboxTool(toolId: string): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookDelete(`/api/toolbox/${toolId}`);
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 工具商店索引（GET /api/toolbox/store/index）。 */
  static async getToolboxStoreIndex(refresh: boolean = false): Promise<ToolboxStoreIndexResponse> {
    const path = refresh ? '/api/toolbox/store/index?refresh=1' : '/api/toolbox/store/index';
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as ToolboxStoreIndexResponse;
  }

  /** 从商店安装/更新工具（POST /api/toolbox/:id/install）。 */
  static async installToolboxStoreTool(toolId: string): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost(`/api/toolbox/${toolId}/install`, '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /**
   * 通用工具箱 GET：path 为 `/api/toolbox/` 之后的后缀，如 `mimo_tts/progress`。
   * 覆盖各工具细接口的查询/进度类路由。
   */
  static async toolboxGet(path: string): Promise<Record<string, Object>> {
    const normalized = path.startsWith('/') ? path.substring(1) : path;
    const raw = await TalebookCoreService.talebookGet(`/api/toolbox/${normalized}`);
    return JSON.parse(raw) as Record<string, Object>;
  }

  /**
   * 通用工具箱 POST：path 为 `/api/toolbox/` 之后的后缀。
   * 覆盖各工具细接口的启动/提交类路由。
   */
  static async toolboxPost(path: string, body: Record<string, Object> = {}): Promise<Record<string, Object>> {
    const normalized = path.startsWith('/') ? path.substring(1) : path;
    const raw = await TalebookCoreService.talebookPost(`/api/toolbox/${normalized}`,
      JSON.stringify(body));
    return JSON.parse(raw) as Record<string, Object>;
  }

  /** 通用工具箱上传（multipart），如 minify_pdf/upload、install/upload。 */
  static async toolboxUpload(
    path: string,
    localPath: string,
    fieldName: string,
    fileName: string,
    fields: Record<string, Object> = {},
  ): Promise<Record<string, Object>> {
    const normalized = path.startsWith('/') ? path.substring(1) : path;
    const raw = await TalebookCoreService.talebookUploadFile(
      `/api/toolbox/${normalized}`, localPath, fieldName, fileName, JSON.stringify(fields));
    return JSON.parse(raw) as Record<string, Object>;
  }

  /** 古书下载（POST /api/toolbox/rare_book_downloader）。 */
  static async rareBookDownload(url: string): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/rare_book_downloader',
      JSON.stringify({ 'url': url } as Record<string, Object>));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 合并格式（POST /api/toolbox/merge_formats/merge）。 */
  static async mergeBookFormats(sourceId: number, targetId: number): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'source_id': sourceId, 'target_id': targetId };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/merge_formats/merge',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 书名语言检测（POST /api/toolbox/review_book_language）。 */
  static async reviewBookLanguage(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/review_book_language', '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 作者清理/替换（POST /api/toolbox/author_clean，action: clean|replace）。 */
  static async authorClean(
    action: string,
    authorName: string,
    newAuthorName: string = '',
  ): Promise<ApiMessageResult> {
    const body: Record<string, Object> = {
      'action': action,
      'author_name': authorName,
    };
    if (newAuthorName.length > 0) {
      body['new_author_name'] = newAuthorName;
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/author_clean',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }


  // ---- mimo_tts ----

  /** MiMo TTS 转换（POST /api/toolbox/mimo_tts/convert）。 */
  static async mimoTtsConvert(req: MimoTtsConvertRequest): Promise<ApiMessageResult> {
    const body: Record<string, Object> = {
      'book_id': req.bookId,
      'api_key': req.apiKey,
    };
    if (req.voiceDesc !== undefined) {
      body['voice_desc'] = req.voiceDesc;
    }
    if (req.apiUrl !== undefined) {
      body['api_url'] = req.apiUrl;
    }
    if (req.modelName !== undefined) {
      body['model_name'] = req.modelName;
    }
    if (req.apiType !== undefined) {
      body['api_type'] = req.apiType;
    }
    if (req.voiceName !== undefined) {
      body['voice_name'] = req.voiceName;
    }
    if (req.authType !== undefined) {
      body['auth_type'] = req.authType;
    }
    if (req.cloneVoice !== undefined) {
      body['clone_voice'] = req.cloneVoice;
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/mimo_tts/convert',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** MiMo TTS 进度（GET /api/toolbox/mimo_tts/progress）。 */
  static async mimoTtsProgress(): Promise<ToolboxTaskProgressResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/mimo_tts/progress');
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  /** MiMo TTS 已保存配置（GET /api/toolbox/mimo_tts/config）。 */
  static async mimoTtsGetConfig(): Promise<MimoTtsConfigResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/mimo_tts/config');
    return JSON.parse(raw) as MimoTtsConfigResponse;
  }

  /** 清除 MiMo TTS 已保存配置（DELETE /api/toolbox/mimo_tts/config）。 */
  static async mimoTtsDeleteConfig(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookDelete('/api/toolbox/mimo_tts/config');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** MiMo TTS 连接测试（POST /api/toolbox/mimo_tts/test）。 */
  static async mimoTtsTest(req: MimoTtsTestRequest): Promise<ApiMessageResult> {
    const body: Record<string, Object> = {
      'api_key': req.apiKey,
    };
    if (req.voiceDesc !== undefined) {
      body['voice_desc'] = req.voiceDesc;
    }
    if (req.apiUrl !== undefined) {
      body['api_url'] = req.apiUrl;
    }
    if (req.modelName !== undefined) {
      body['model_name'] = req.modelName;
    }
    if (req.apiType !== undefined) {
      body['api_type'] = req.apiType;
    }
    if (req.voiceName !== undefined) {
      body['voice_name'] = req.voiceName;
    }
    if (req.authType !== undefined) {
      body['auth_type'] = req.authType;
    }
    if (req.cloneVoice !== undefined) {
      body['clone_voice'] = req.cloneVoice;
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/mimo_tts/test',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 上传克隆音色（POST /api/toolbox/mimo_tts/clone/upload，multipart field=file）。 */
  static async mimoTtsCloneUpload(
    localPath: string,
    fileName: string,
    voiceName: string,
  ): Promise<ToolboxDataResponse> {
    const fields: Record<string, Object> = { 'voice_name': voiceName };
    const raw = await TalebookCoreService.talebookUploadFile(
      '/api/toolbox/mimo_tts/clone/upload', localPath, 'file', fileName, JSON.stringify(fields));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** 克隆音色列表（GET /api/toolbox/mimo_tts/clone/list）。 */
  static async mimoTtsCloneList(): Promise<MimoTtsClonesResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/mimo_tts/clone/list');
    return JSON.parse(raw) as MimoTtsClonesResponse;
  }

  /** 删除克隆音色（POST /api/toolbox/mimo_tts/clone/delete）。 */
  static async mimoTtsCloneDelete(voiceName: string): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'voice_name': voiceName };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/mimo_tts/clone/delete',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 克隆音色音频二进制路径（GET /api/toolbox/mimo_tts/clone/audio）。 */
  static mimoTtsCloneAudioPath(voiceName: string): string {
    return `/api/toolbox/mimo_tts/clone/audio?voice_name=${encodeURIComponent(voiceName)}`;
  }

  /** 音色提示词列表（GET /api/toolbox/mimo_tts/prompt/list）。 */
  static async mimoTtsPromptList(): Promise<MimoTtsPromptsResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/mimo_tts/prompt/list');
    return JSON.parse(raw) as MimoTtsPromptsResponse;
  }

  /** 保存音色提示词（POST /api/toolbox/mimo_tts/prompt/save）。 */
  static async mimoTtsPromptSave(name: string, desc: string): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = { 'name': name, 'desc': desc };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/mimo_tts/prompt/save',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** 删除音色提示词（POST /api/toolbox/mimo_tts/prompt/delete）。 */
  static async mimoTtsPromptDelete(name: string): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'name': name };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/mimo_tts/prompt/delete',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  // ---- epub_beautify ----

  /** EPUB 美化预览（POST /api/toolbox/epub_beautify/preview）。 */
  static async epubBeautifyPreview(bookId: number): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = { 'book_id': bookId };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/epub_beautify/preview',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** EPUB 美化运行（POST /api/toolbox/epub_beautify/run）；bookIds 长度 1 即单本。 */
  static async epubBeautifyRun(
    bookIds: number[],
    options?: EpubBeautifyRunOptions,
  ): Promise<ApiMessageResult> {
    const body: Record<string, Object> = {
      'book_ids': bookIds as Object,
    };
    if (options !== undefined) {
      if (options.preset !== undefined) {
        body['preset'] = options.preset;
      }
      if (options.tocStyle !== undefined) {
        body['toc_style'] = options.tocStyle;
      }
      if (options.useSystemFonts !== undefined) {
        body['use_system_fonts'] = options.useSystemFonts;
      }
      if (options.suffix !== undefined) {
        body['suffix'] = options.suffix;
      }
      if (options.fontOverrides !== undefined) {
        body['font_overrides'] = options.fontOverrides;
      }
      if (options.tocDepth !== undefined) {
        body['toc_depth'] = options.tocDepth;
      }
      if (options.cleanup !== undefined) {
        body['cleanup'] = options.cleanup;
      }
      if (options.paletteOverrides !== undefined) {
        body['palette_overrides'] = options.paletteOverrides;
      }
      if (options.pageTint !== undefined) {
        body['page_tint'] = options.pageTint as Object;
      }
      if (options.dialogue !== undefined) {
        body['dialogue'] = options.dialogue;
      }
      if (options.titleSplit !== undefined) {
        body['title_split'] = options.titleSplit;
      }
      if (options.paraMode !== undefined) {
        body['para_mode'] = options.paraMode;
      }
      if (options.paraIndent !== undefined) {
        body['para_indent'] = options.paraIndent;
      }
      if (options.paraGap !== undefined) {
        body['para_gap'] = options.paraGap;
      }
      if (options.tocColumns !== undefined) {
        body['toc_columns'] = options.tocColumns;
      }
      if (options.notes !== undefined) {
        body['notes'] = options.notes;
      }
      if (options.noteMark !== undefined) {
        body['note_mark'] = options.noteMark;
      }
      if (options.bgImage !== undefined) {
        body['bg_image'] = options.bgImage;
      }
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/epub_beautify/run',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** EPUB 美化进度（GET /api/toolbox/epub_beautify/progress）。 */
  static async epubBeautifyProgress(): Promise<ToolboxTaskProgressResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/epub_beautify/progress');
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  /** 上传 EPUB 美化背景图（POST /api/toolbox/epub_beautify/bg_upload，multipart file）。 */
  static async epubBeautifyBgUpload(
    localPath: string,
    fileName: string,
  ): Promise<ToolboxDataResponse> {
    const raw = await TalebookCoreService.talebookUploadFile(
      '/api/toolbox/epub_beautify/bg_upload', localPath, 'file', fileName, '{}');
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** 选用内置背景图（POST /api/toolbox/epub_beautify/bg_upload，form: builtin_id）。 */
  static async epubBeautifyBgUploadBuiltin(builtinId: string): Promise<ToolboxDataResponse> {
    const form = `builtin_id=${encodeURIComponent(builtinId)}`;
    const raw = await TalebookCoreService.talebookPostForm(
      '/api/toolbox/epub_beautify/bg_upload', form);
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** EPUB 美化背景图元信息（GET /api/toolbox/epub_beautify/bg_meta）。 */
  static async epubBeautifyBgMeta(): Promise<ToolboxDataResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/epub_beautify/bg_meta');
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** EPUB 美化背景图二进制路径（GET /api/toolbox/epub_beautify/bg_raw）。 */
  static epubBeautifyBgRawPath(): string {
    return '/api/toolbox/epub_beautify/bg_raw';
  }

  /** 删除 EPUB 美化背景图（POST /api/toolbox/epub_beautify/bg_delete）。 */
  static async epubBeautifyBgDelete(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/epub_beautify/bg_delete', '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  // ---- minify_pdf ----

  /** PDF 瘦身上传（POST /api/toolbox/minify_pdf/upload）。 */
  static async minifyPdfUpload(localPath: string, fileName: string): Promise<ToolboxDataResponse> {
    const raw = await TalebookCoreService.talebookUploadFile(
      '/api/toolbox/minify_pdf/upload', localPath, 'file', fileName, '{}');
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** PDF 瘦身处理（POST /api/toolbox/minify_pdf/process）。 */
  static async minifyPdfProcess(
    filename: string,
    params?: Record<string, Object>,
  ): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'filename': filename };
    if (params !== undefined) {
      body['params'] = params;
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/minify_pdf/process',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** PDF 瘦身进度（GET /api/toolbox/minify_pdf/progress?filename=）。 */
  static async minifyPdfProgress(filename: string): Promise<ToolboxTaskProgressResponse> {
    const path = `/api/toolbox/minify_pdf/progress?filename=${encodeURIComponent(filename)}`;
    const raw = await TalebookCoreService.talebookGet(path);
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  /** PDF 瘦身下载路径（GET /api/toolbox/minify_pdf/download?filename=）。 */
  static minifyPdfDownloadPath(filename: string): string {
    return `/api/toolbox/minify_pdf/download?filename=${encodeURIComponent(filename)}`;
  }

  // ---- formats_pruning ----

  /** 格式精简启动（POST /api/toolbox/formats_pruning/start）。 */
  static async formatsPruningStart(deleteFormats: string[]): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'delete': deleteFormats as Object };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/formats_pruning/start',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 格式精简进度（GET /api/toolbox/formats_pruning/progress）。 */
  static async formatsPruningProgress(): Promise<ToolboxTaskProgressResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/formats_pruning/progress');
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  // ---- epub_fixer ----

  /** EPUB 修复（POST /api/toolbox/epub_fixer/fix）。 */
  static async epubFixerFix(bookId: number, backup: boolean = false): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'book_id': bookId, 'backup': backup };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/epub_fixer/fix',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  // ---- epub_split ----

  /** EPUB 拆分章节列表（POST /api/toolbox/epub_split/chapters）。 */
  static async epubSplitChapters(bookId: number): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = { 'book_id': bookId };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/epub_split/chapters',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** EPUB 拆分生成（POST /api/toolbox/epub_split/generate）。 */
  static async epubSplitGenerate(
    bookId: number,
    chapters: number[],
    useFirstChapterCover: boolean = false,
  ): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = {
      'book_id': bookId,
      'chapters': chapters as Object,
      'use_first_chapter_cover': useFirstChapterCover,
    };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/epub_split/generate',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  // ---- chinese_converter ----

  /** 繁简转换（POST /api/toolbox/chinese_converter/convert）。 */
  static async chineseConverterConvert(
    bookId: number,
    direction: string = 't2s',
    mode: string = 'book',
    convertTitle: boolean = true,
    useA5: boolean = false,
    backup: boolean = false,
  ): Promise<ApiMessageResult> {
    const body: Record<string, Object> = {
      'book_id': bookId,
      'direction': direction,
      'mode': mode,
      'convert_title': convertTitle,
      'use_a5': useA5,
      'backup': backup,
    };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/chinese_converter/convert',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 繁简转换进度（GET /api/toolbox/chinese_converter/progress）。 */
  static async chineseConverterProgress(): Promise<ToolboxTaskProgressResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/chinese_converter/progress');
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  // ---- txt_encoding_fixer ----

  /** TXT 编码分析（POST /api/toolbox/txt_encoding_fixer/analyze）。 */
  static async txtEncodingFixerAnalyze(bookId: number): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = { 'book_id': bookId };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/txt_encoding_fixer/analyze',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** TXT 编码修复（POST /api/toolbox/txt_encoding_fixer/fix）。 */
  static async txtEncodingFixerFix(bookId: number): Promise<ApiMessageResult> {
    const body: Record<string, Object> = { 'book_id': bookId };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/txt_encoding_fixer/fix',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** TXT 编码修复进度（GET /api/toolbox/txt_encoding_fixer/progress）。 */
  static async txtEncodingFixerProgress(): Promise<ToolboxTaskProgressResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/txt_encoding_fixer/progress');
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  // ---- text_replace ----

  /** 正文替换预览（POST /api/toolbox/text_replace/preview）。 */
  static async textReplacePreview(
    bookId: number,
    pattern: string,
    replacement: string = '',
    useRegex: boolean = false,
    format: string = '',
  ): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = {
      'book_id': bookId,
      'pattern': pattern,
      'replacement': replacement,
      'use_regex': useRegex,
    };
    if (format.length > 0) {
      body['format'] = format;
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/text_replace/preview',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** 正文替换执行（POST /api/toolbox/text_replace/run）。 */
  static async textReplaceRun(
    bookId: number,
    pattern: string,
    replacement: string = '',
    useRegex: boolean = false,
    suffix: string = '',
    format: string = '',
  ): Promise<ApiMessageResult> {
    const body: Record<string, Object> = {
      'book_id': bookId,
      'pattern': pattern,
      'replacement': replacement,
      'use_regex': useRegex,
    };
    if (suffix.length > 0) {
      body['suffix'] = suffix;
    }
    if (format.length > 0) {
      body['format'] = format;
    }
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/text_replace/run',
      JSON.stringify(body));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 正文替换进度（GET /api/toolbox/text_replace/progress）。 */
  static async textReplaceProgress(): Promise<ToolboxTaskProgressResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/text_replace/progress');
    return JSON.parse(raw) as ToolboxTaskProgressResponse;
  }

  // ---- bookbarn_acceptor ----

  /** 书仓接收器状态（GET /api/toolbox/bookbarn_acceptor/status）。 */
  static async bookbarnAcceptorStatus(): Promise<ToolboxDataResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/toolbox/bookbarn_acceptor/status');
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** 书仓接收开关（POST /api/toolbox/bookbarn_acceptor/toggle）。 */
  static async bookbarnAcceptorToggle(enabled: boolean): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = { 'enabled': enabled };
    const raw = await TalebookCoreService.talebookPost('/api/toolbox/bookbarn_acceptor/toggle',
      JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  /** 申请书仓 Token（POST /api/toolbox/bookbarn_acceptor/apply_token）。 */
  static async bookbarnAcceptorApplyToken(): Promise<BookBarnApplyTokenResponse> {
    const raw = await TalebookCoreService.talebookPost(
      '/api/toolbox/bookbarn_acceptor/apply_token', '{}');
    return JSON.parse(raw) as BookBarnApplyTokenResponse;
  }

  /** 设置书仓采集小时（POST /api/toolbox/bookbarn_acceptor/set_collection_hour）。 */
  static async bookbarnAcceptorSetCollectionHour(hour: number): Promise<ToolboxDataResponse> {
    const body: Record<string, Object> = { 'hour': hour };
    const raw = await TalebookCoreService.talebookPost(
      '/api/toolbox/bookbarn_acceptor/set_collection_hour', JSON.stringify(body));
    return JSON.parse(raw) as ToolboxDataResponse;
  }

  // ---- install uploads ----

  /** 本地上传安装工具包（POST /api/toolbox/install/upload）。 */
}

