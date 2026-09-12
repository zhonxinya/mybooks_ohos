import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { PageScaffold, LoadingState, EmptyState, PrimaryButton, SecondaryButton, IconCircleButton } from '../components';
import { TalebookApi } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';
import { BookUploadService } from '../services/BookUploadService';

interface SelectOptionDef {
  text: string;
  value: Object;
}

/** 「书籍分类」卡片：BOOK_NAV 的一行（分类名 + 可选标签，标签用 / 分隔） */
interface CategoryEntry {
  name: string;
  tags: string;
}

interface FieldDef {
  key: string;
  label: string;
  kind: string;
  options?: SelectOptionDef[];
  danger?: boolean;
  secret?: boolean;
}

interface FieldGroupDef {
  key: string;
  label: string;
  fields: FieldDef[];
}

interface CardDef {
  title: string;
  subtitle?: string;
  fields: FieldDef[];
  groups?: FieldGroupDef[];
}

interface SnsItem {
  text?: string;
  value?: string;
  link?: string;
}

function text(key: string, label: string, danger: boolean = false, secret: boolean = false): FieldDef {
  return { key: key, label: label, kind: 'text', danger: danger, secret: secret };
}

function numberField(key: string, label: string): FieldDef {
  return { key: key, label: label, kind: 'number' };
}

function textarea(key: string, label: string): FieldDef {
  return { key: key, label: label, kind: 'textarea' };
}

function bool(key: string, label: string, danger: boolean = false): FieldDef {
  return { key: key, label: label, kind: 'bool', danger: danger };
}

function select(key: string, label: string, options: SelectOptionDef[], danger: boolean = false): FieldDef {
  return { key: key, label: label, kind: 'select', options: options, danger: danger };
}

function nums(values: number[]): SelectOptionDef[] {
  const list: SelectOptionDef[] = [];
  for (let i = 0; i < values.length; i++) {
    list.push({ text: String(values[i]), value: values[i] });
  }
  return list;
}

function options(pairs: SelectOptionDef[]): SelectOptionDef[] {
  return pairs;
}

const SMTP_ENCRYPTION: SelectOptionDef[] = options([
  { text: 'SSL', value: 'SSL' },
  { text: 'TLS', value: 'TLS' },
]);

const LANGUAGE_OPTIONS: SelectOptionDef[] = options([
  { text: '中文', value: 'zh' },
  { text: '繁體中文', value: 'zh-TW' },
  { text: 'English', value: 'en' },
]);

const INDEX_PAGE_TYPES: SelectOptionDef[] = options([
  { text: '默认首页', value: 'index' },
  { text: '所有图书', value: 'all' },
  { text: '分类浏览', value: 'categories' },
]);

const EPUB_VIEWERS: SelectOptionDef[] = options([
  { text: 'EPUB Reader（纯本地，简洁清爽，仅支持EPUB）', value: 'epubjs.html' },
  { text: 'MyReader（完整功能，多端数据同步）', value: 'MyReader' },
]);

const BOOK_NAME_FORMATS: SelectOptionDef[] = options([
  { text: '使用拼音字母目录名（兼容性高）', value: 'en' },
  { text: '使用中文目录名（UTF8编码，更美观）', value: 'utf8' },
]);

const STAMP_POSITIONS: SelectOptionDef[] = options([
  { text: '左上', value: 'top-left' },
  { text: '上居中', value: 'top-center' },
  { text: '右上', value: 'top-right' },
  { text: '居左', value: 'center-left' },
  { text: '居中', value: 'center' },
  { text: '居右', value: 'center-right' },
  { text: '左下', value: 'bottom-left' },
  { text: '下居中', value: 'bottom-center' },
  { text: '右下', value: 'bottom-right' },
]);

const META_SOURCE_LABELS: Record<string, string> = {
  'douban': '豆瓣',
  'baidu': '百度百科',
  'google': 'Google',
  'amazon': 'Amazon',
  'xinhua': '新华书店',
  'youshu': '优书网',
  'douban_v2': '豆瓣V2',
  'ujxsw': '悠久小说网',
  'neodb': 'NeoDB',
};

const DEFAULT_META_SOURCES: string[] = ['douban', 'baidu', 'google', 'amazon', 'xinhua', 'youshu', 'ujxsw'];

function buildCards(): CardDef[] {
  const favicons: SelectOptionDef[] = [{ text: '默认图标（不做变更）', value: 'favicon_0' }];
  for (let i = 1; i < 9; i++) {
    favicons.push({ text: `图标 ${i}`, value: `favicon_${i}` });
  }
  const hours: SelectOptionDef[] = [];
  for (let i = 0; i < 24; i++) {
    hours.push({ text: String(i), value: i });
  }

  const basicInfo: CardDef = {
    title: '基础信息',
    fields: [
      text('site_title', '网站标题'),
      select('site_icon', '网站图标', favicons),
      textarea('HEADER', '网站公告'),
      textarea('FOOTER', '网站脚注'),
      text('FOOTER_WATERMARK', '脚注水印'),
      select('site_language', '语言切换', LANGUAGE_OPTIONS),
      select('INDEX_PAGE_TYPE', '首页类型', INDEX_PAGE_TYPES),
      select('MAIN_PAGE_RANDOM_COUNT', '首页 - 随机推荐图书数量（为0时隐藏）', nums([0, 12, 24, 48, 96, 192, 768])),
      select('MAIN_PAGE_RECENT_COUNT', '首页 - 新书推荐显示数量', nums([12, 24, 48, 96, 192])),
      select('DEFAULT_PAGE_SIZE', '书籍列表中分页大小', nums([60, 100, 200, 500, 1000])),
      bool('HIDE_PROJECT_LINKS', '隐藏脚注中的项目链接'),
    ],
    groups: [
      {
        key: 'INVITE_MODE',
        label: '开启私人图书馆模式',
        fields: [
          text('INVITE_CODE', '访问码'),
          textarea('INVITE_MESSAGE', '提示语'),
        ],
      },
    ],
  };

  const reader: CardDef = {
    title: '浏览与阅读',
    fields: [
      select('EPUB_VIEWER', '阅读器', EPUB_VIEWERS),
      bool('ENABLE_PHYSICAL_BOOKS', '启用添加实体书功能'),
      bool('ENABLE_DATA_SYNC', '启用MyReader数据同步功能'),
      bool('USE_DYNAMIC_COVER', '启用动态封面（根据书籍信息自动生成封面图片）'),
      bool('ENABLE_AUTHOR_INFO', '显示作者详情信息（头像及简介）'),
      bool('ALLOW_USER_DISABLE_STATISTIC', '允许用户自行关闭阅读及下载数据采集'),
      bool('ENABLE_HOMEPAGE_READING_STATS', '在首页显示阅读统计 Banner'),
      bool('ENABLE_HOMEPAGE_READING_BOOKS', '在首页显示在读书籍'),
      bool('ENABLE_HOMEPAGE_BOOKLISTS', '在首页展示书单推荐'),
      bool('ENABLE_BOOK_REVIEW', '允许用户对书籍进行评论及评分'),
      bool('REVIEW_REQUIRES_APPROVAL', '评论需要审核后才能展示（仅在允许评论时生效）'),
      bool('ENABLE_BOOK_RECOMMEND_TO_OTHERS', '在首页展示其他用户评论过的书籍'),
      bool('ENABLE_SHARED_NOTES', '阅读时支持查看其他用户的划线与笔记'),
    ],
  };

  const userSettings: CardDef = {
    title: '用户设置',
    fields: [
      bool('ALLOW_GUEST_READ', '允许访客在线阅读及播放有声书'),
      bool('ALLOW_GUEST_DOWNLOAD', '允许任意下载（访客无需注册和登录）'),
      bool('ALLOW_GUEST_PUSH', '允许访客推送到阅读设备'),
      bool('ALLOW_GUEST_UPLOAD', '允许访客上传书籍（请确保清楚开启后的风险）'),
      bool('ALLOW_NEW_USER_MANAGE_BOOK', '新注册用户默认启用书籍管理权限'),
      bool('ALLOW_NEW_USER_PUSH_BOOK', '新注册用户默认启用推送到阅读设备权限'),
    ],
    groups: [
      {
        key: 'ALLOW_READ_RANGE_SETTING',
        label: '开启用户的阅读范围控制（范围的详细配置请在网页端设置）',
        fields: [],
      },
      {
        key: 'ALLOW_REGISTER',
        label: '允许访客以邮箱注册账号',
        fields: [
          text('SIGNUP_MAIL_TITLE', '激活邮件标题'),
          textarea('SIGNUP_MAIL_CONTENT', '激活邮件正文'),
          text('RESET_MAIL_TITLE', '重置密码邮件标题'),
          textarea('RESET_MAIL_CONTENT', '重置密码邮件正文'),
          bool('ENABLE_AUTO_NEW_USER_APPROVAL', '启用新用户注册的自动审批'),
        ],
      },
      {
        key: 'ENABLE_DOWNLOAD_QUOTA',
        label: '开启用户每日下载配额限制',
        fields: [
          numberField('GLOBAL_DOWNLOAD_QUOTA', '全局每日下载配额（0表示不限制）'),
        ],
      },
    ],
  };

  const bookBarn: CardDef = {
    title: '书栈服务',
    subtitle: '书栈所提供的均为网上公开信息，开启后支持获取作者信息及书籍标签信息。',
    fields: [
      bool('ENABLE_BOOKBARN', '启用书栈服务'),
      text('BOOKBARN_TOKEN', '授权Token', false, true),
      select('BOOKBARN_COLLECTION_HOUR', '获取书栈图书列表的时间（整点）', hours),
      bool('ENABLE_RECEIVING_BOOKS', '允许接收书栈推送的图书'),
      bool('USE_BOOKBARN_PROXY', '使用书栈代理服务（公众号后台私信授权后开通）'),
      text('BOOK2AUDIO_PROXY', '语音代理服务器地址（EdgeTTS 代理）'),
    ],
  };

  const bookTags: CardDef = {
    title: '书籍分类',
    subtitle: '配置首页「分类浏览」展示的分类；可绑定标签，仅当书籍带有其中任一标签时归入该分类。',
    fields: [],
  };

  const importUpload: CardDef = {
    title: '导入与上传',
    fields: [
      text('scan_upload_path', '批量导入扫描目录'),
      text('MAX_UPLOAD_SIZE', '文件上传字节数限制（例如100MB或100KB）', true),
      text('CHUNK_UPLOAD_SIZE', '分片上传阈值（0表示不启用，分片最小20MB，例如50MB）'),
      bool('PDF_TILE_WITH_FILE_NAME', '添加PDF文件时书名直接使用文件名'),
      bool('ENABLE_TXT_TO_TXTZ_PLUGIN', '启用TXT转TXTZ插件（导入TXT耗时较长）', true),
      bool('REMOVE_IMPORTED_FILE', '导入完成后删除源文件（开启监控导入后将失效）'),
      bool('KEEP_UPLOAD_SOURCE_FILE', '上传后保留暂存源文件'),
      bool('SEND_MAIL_FOR_NEW_BOOKS', '上传及导入后发送邮箱提醒（15分钟合并发送）'),
      bool('BATCH_ADD_IN_FORCE', '批量添加实体书时强制添加无法识别的ISBN书籍'),
      bool('IMPORT_CATEGORY_WITH_FOLDER', '使用第一级目录为自定义类别名称'),
    ],
    groups: [
      {
        key: 'IMPORT_BY_INOTIFY',
        label: '监控导入目录，自动进行导入',
        fields: [
          bool('UPDATE_CATEGORY_WITH_FOLDER_RENAME', '目录重命名或文件移动时更新已导入书籍的类别'),
        ],
      },
    ],
  };

  const advanced: CardDef = {
    title: '高级配置项',
    fields: [
      text('static_host', 'CDN域名', true),
      select('BOOK_NAMES_FORMAT', '目录和文件名模式', BOOK_NAME_FORMATS, true),
      text('cookie_secret', 'COOKIE随机密钥', false, true),
      text('push_title', '邮件推送的标题'),
      text('push_content', '邮件推送的内容'),
      numberField('convert_timeout', '书籍转换格式的最大超时时间（秒）'),
      bool('ENABLE_WEBDAV_SERVICE', '启用WebDAV服务'),
      bool('WEBDAV_SYNC_FOLDER', 'WebDAV中支持阅读器可写目录'),
      bool('ENABLE_OPDS_SERVICE', '启用OPDS目录服务'),
      bool('ENABLE_OPDS_AUTH', '启用OPDS目录服务认证'),
      bool('ENABLE_PODCAST_SERVICE', '启用Podcast订阅服务'),
      bool('ENABLE_TOOLBOX_DEV_MODE', '启用工具箱开发者模式'),
      bool('ENABLE_TOOLBOX_STORE', '启用工具箱商店'),
      bool('autoreload', '更新配置后自动重启服务器'),
      bool('LOG_LEVEL_DEBUG', '启用调试日志记录', true),
      bool('ENABLE_AUDIO_CONVERSION_LOG', '启用有声书转换日志记录'),
      bool('ENABLE_AUDIO_SUBTITLE', '转换有声书时生成同名字幕文件'),
      bool('AUTO_CHECKING_NEW_VERSION', '自动检测更新'),
    ],
  };

  const extended: CardDef = {
    title: '扩展功能',
    fields: [
      bool('ENABLE_STAMP_FEATURE', '启用封面加盖图章功能'),
      select('STAMP_POSITION', '图章位置', STAMP_POSITIONS),
    ],
  };

  return [basicInfo, reader, userSettings, bookBarn, bookTags, importUpload, advanced, extended];
}

const CARDS: CardDef[] = buildCards();

@Entry
@Component
struct AdminSettingsPage {
  @State loading: boolean = true;
  @State loadError: string = '';
  @State saving: boolean = false;
  @State version: number = 0;
  @State expandedKeys: string[] = ['基础信息'];
  @State sysInfoSummary: string = '';
  @State adminTokenPreview: string = '';
  @State stampExists: boolean = false;
  @State stampBusy: boolean = false;
  @State sslBusy: boolean = false;
  @State tokenBusy: boolean = false;
  @State bookbarnBusy: boolean = false;
  @State releaseNotes: string = '';
  @State thanksNames: string[] = [];
  @State categoryEntries: CategoryEntry[] = [];
  @State newCategoryName: string = '';
  @State newCategoryTags: string = '';
  @State selectedSourceNames: string[] = [];
  private settings: Record<string, Object> = {};
  private snsItems: SnsItem[] = [];
  private siteUrl: string = '';

  aboutToAppear(): void {
    void this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      if (!TalebookService.hasAuthCredentials()) {
        this.loadError = '请先在「设置 → Talebook 服务器」配置地址并登录管理员账号';
        return;
      }
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.getAdminSettings();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.loadError = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err;
        return;
      }
      if (rsp.settings === undefined) {
        this.loadError = '设置数据为空';
        return;
      }
      this.settings = rsp.settings;
      this.categoryEntries = this.parseCategories(this.str('BOOK_NAV'));
      this.selectedSourceNames = this.selectedSources().slice();
      this.snsItems = (rsp.sns ?? []) as SnsItem[];
      this.siteUrl = rsp.site_url !== undefined ? rsp.site_url : '';
      if (!Array.isArray(this.settings['SOCIALS'])) {
        this.settings['SOCIALS'] = [];
      }
      if (!Array.isArray(this.settings['FRIENDS'])) {
        this.settings['FRIENDS'] = [];
      }
      if (this.str('site_icon').length === 0) {
        this.settings['site_icon'] = 'favicon_0';
      }
      void this.refreshSysInfo();
      void this.refreshStampStatus();
      void this.refreshServerNotes();
    } catch (e) {
      this.loadError = `加载设置失败：${e}`;
    } finally {
      this.loading = false;
      this.version++;
    }
  }

  private isExpanded(key: string): boolean {
    return this.expandedKeys.indexOf(key) >= 0;
  }

  private toggleExpand(key: string): void {
    if (this.isExpanded(key)) {
      this.expandedKeys = this.expandedKeys.filter((k: string) => k !== key);
    } else {
      const next: string[] = [];
      for (let i = 0; i < this.expandedKeys.length; i++) {
        next.push(this.expandedKeys[i]);
      }
      next.push(key);
      this.expandedKeys = next;
    }
  }

  private async refreshSysInfo(): Promise<void> {
    try {
      const rsp = await TalebookApi.getSysInfo();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.sysInfoSummary = '';
        return;
      }
      const d = rsp.data ?? {};
      const parts: string[] = [];
      const keys: string[] = ['platform', 'version', 'python', 'calibre', 'uptime'];
      for (let i = 0; i < keys.length; i++) {
        const v = d[keys[i]];
        if (v !== undefined && String(v).length > 0) {
          parts.push(`${keys[i]}: ${String(v)}`);
        }
      }
      if (parts.length === 0) {
        const allKeys = Object.keys(d);
        for (let i = 0; i < allKeys.length && i < 4; i++) {
          parts.push(`${allKeys[i]}: ${String(d[allKeys[i]])}`);
        }
      }
      this.sysInfoSummary = parts.join(' · ');
    } catch (_e) {
      this.sysInfoSummary = '';
    }
  }

  private async refreshStampStatus(): Promise<void> {
    try {
      const rsp = await TalebookApi.getStampStatus();
      this.stampExists = rsp.exists === true;
    } catch (_e) {
      this.stampExists = false;
    }
  }

  /** 服务端更新说明与致谢名单（失败静默，不阻塞页面）。 */
  private async refreshServerNotes(): Promise<void> {
    try {
      this.releaseNotes = await TalebookApi.getReleaseNotes();
    } catch (_e) {
      this.releaseNotes = '';
    }
    try {
      const rsp = await TalebookApi.getThanksNotes();
      this.thanksNames = rsp.names ?? [];
    } catch (_e) {
      this.thanksNames = [];
    }
  }

  private async uploadStampImage(): Promise<void> {
    if (this.stampBusy) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const file = await BookUploadService.pickStagedFile(context, ['.png'], 'stamp');
    if (file === null) {
      return;
    }
    this.stampBusy = true;
    try {
      const rsp = await TalebookApi.uploadStamp(file.localPath, file.name);
      BookUploadService.removeStagedFile(file.localPath);
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '图章已上传');
        await this.refreshStampStatus();
      } else {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : String(rsp.err));
      }
    } catch (e) {
      this.toast(`上传失败：${e}`);
    } finally {
      this.stampBusy = false;
    }
  }

  private async generateToken(): Promise<void> {
    if (this.tokenBusy) {
      return;
    }
    this.tokenBusy = true;
    try {
      const rsp = await TalebookApi.generateAdminToken();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : String(rsp.err));
        return;
      }
      this.adminTokenPreview = rsp.token !== undefined ? rsp.token : '';
      this.toast(this.adminTokenPreview.length > 0 ? 'Token 已生成' : '已生成（空 Token）');
    } catch (e) {
      this.toast(`生成失败：${e}`);
    } finally {
      this.tokenBusy = false;
    }
  }

  private copyText(text: string): void {
    if (text.length === 0) {
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data);
    this.toast('已复制到剪贴板');
  }

  private async uploadSslPair(): Promise<void> {
    if (this.sslBusy) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    this.toast('请选择证书文件（.crt / .pem）');
    const crt = await BookUploadService.pickStagedFile(
      context, ['.crt', '.pem', '.cer'], 'ssl_crt');
    if (crt === null) {
      return;
    }
    this.toast('请选择私钥文件（.key / .pem）');
    const key = await BookUploadService.pickStagedFile(
      context, ['.key', '.pem'], 'ssl_key');
    if (key === null) {
      BookUploadService.removeStagedFile(crt.localPath);
      return;
    }
    this.sslBusy = true;
    try {
      const rsp = await TalebookApi.uploadAdminSsl(
        crt.localPath, crt.name, key.localPath, key.name);
      BookUploadService.removeStagedFile(crt.localPath);
      BookUploadService.removeStagedFile(key.localPath);
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : 'SSL 已上传');
      } else {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : String(rsp.err));
      }
    } catch (e) {
      this.toast(`SSL 上传失败：${e}`);
    } finally {
      this.sslBusy = false;
    }
  }

  private applyBookbarn(): void {
    this.getUIContext().showAlertDialog({
      title: '申请书栈 Token',
      message: '将向书栈服务申请并回写授权 Token，是否继续？',
      primaryButton: {
        value: '申请',
        action: () => {
          void this.doApplyBookbarn();
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private async doApplyBookbarn(): Promise<void> {
    if (this.bookbarnBusy) {
      return;
    }
    this.bookbarnBusy = true;
    try {
      const rsp = await TalebookApi.applyBookbarnToken();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : String(rsp.err));
        return;
      }
      if (rsp.token !== undefined && rsp.token.length > 0) {
        this.settings['BOOKBARN_TOKEN'] = rsp.token;
        this.version++;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '书栈 Token 已申请');
    } catch (e) {
      this.toast(`申请失败：${e}`);
    } finally {
      this.bookbarnBusy = false;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private save(): void {
    if (this.saving) {
      return;
    }
    this.saving = true;
    TalebookApi.saveAdminSettings(this.settings)
      .then((rsp) => {
        this.saving = false;
        if (rsp.err === undefined || rsp.err === 'ok') {
          this.toast('保存成功！可能需要5~10秒生效');
        } else {
          this.toast(`保存失败：${rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err}`);
        }
      })
      .catch((e: Object) => {
        this.saving = false;
        this.toast(`保存失败：${e}`);
      });
  }

  private restartServer(): void {
    this.getUIContext().showAlertDialog({
      title: '确认重启服务',
      message: '确定要立即重启服务吗？当前正在执行的后台任务（如导入、转换、联网更新信息等）将会被中断。',
      primaryButton: {
        value: '确认重启',
        action: () => {
          TalebookApi.restartAdminServer()
            .then((rsp) => {
              this.toast(rsp.err === 'ok' ? '服务正在重启，请稍后刷新页面' :
                `重启失败：${rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err}`);
            })
            .catch((e: Object) => this.toast(`重启失败：${e}`));
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private testEmail(): void {
    const server = this.str('smtp_server');
    const username = this.str('smtp_username');
    const password = this.str('smtp_password');
    const encryption = this.str('smtp_encryption');
    if (server.length === 0 || username.length === 0) {
      this.toast('请先填写 SMTP 服务器与用户名');
      return;
    }
    this.toast('测试邮件发送中…');
    TalebookApi.testAdminMail(server, username, password, encryption)
      .then((rsp) => {
        if (rsp.err === 'ok') {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '测试邮件已发送');
        } else {
          this.toast(`测试失败：${rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err}`);
        }
      })
      .catch((e: Object) => this.toast(`测试失败：${e}`));
  }

  private testAI(): void {
    const apiUrl = this.str('AI_API_URL');
    const apiKey = this.str('AI_DEEPSEEK_API_KEY');
    const apiModel = this.str('AI_MODEL');
    if (apiUrl.length === 0 || apiKey.length === 0 || apiModel.length === 0) {
      this.toast('请先填写 AI 接口地址、API 密钥与模型');
      return;
    }
    this.toast('AI 连接测试中…');
    TalebookApi.testAdminAI(apiUrl, apiKey, apiModel)
      .then((rsp) => {
        if (rsp.err === 'ok') {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : 'AI服务连接测试成功');
        } else {
          this.toast(`测试失败：${rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err}`);
        }
      })
      .catch((e: Object) => this.toast(`测试失败：${e}`));
  }

  private str(key: string): string {
    const value = this.settings[key];
    if (value === null || value === undefined) {
      return '';
    }
    return String(value);
  }

  private bool(key: string): boolean {
    return Boolean(this.settings[key]);
  }

  private setBool(key: string, value: boolean): void {
    this.settings[key] = value;
    this.version++;
  }

  private setText(key: string, value: string): void {
    this.settings[key] = value;
  }

  /** 解析 BOOK_NAV：每行「分类名」或「分类名=标签1/标签2」，忽略空行。 */
  private parseCategories(raw: string): CategoryEntry[] {
    const result: CategoryEntry[] = [];
    const lines = raw.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const eq = line.indexOf('=');
      if (eq >= 0) {
        result.push({ name: line.slice(0, eq).trim(), tags: line.slice(eq + 1).trim() });
      } else {
        result.push({ name: line, tags: '' });
      }
    }
    return result;
  }

  /** 分类列表回写为 BOOK_NAV 文本；需点击保存后生效。 */
  private syncCategories(): void {
    const lines: string[] = [];
    for (let i = 0; i < this.categoryEntries.length; i++) {
      const entry = this.categoryEntries[i];
      lines.push(entry.tags.length > 0 ? `${entry.name}=${entry.tags}` : entry.name);
    }
    this.setText('BOOK_NAV', lines.join('\n'));
  }

  private addCategory(): void {
    const name = this.newCategoryName.trim();
    const tags = this.newCategoryTags.trim();
    if (name.length === 0) {
      this.toast('请填写分类名称');
      return;
    }
    if (this.categoryEntries.some((entry: CategoryEntry) => entry.name === name)) {
      this.toast('该分类已存在');
      return;
    }
    this.categoryEntries = this.categoryEntries.concat([{ name: name, tags: tags }]);
    this.newCategoryName = '';
    this.newCategoryTags = '';
    this.syncCategories();
  }

  private removeCategory(name: string): void {
    this.categoryEntries = this.categoryEntries.filter((entry: CategoryEntry) => entry.name !== name);
    this.syncCategories();
  }

  private numStr(key: string): string {
    const value = this.settings[key];
    if (value === null || value === undefined) {
      return '';
    }
    return String(value);
  }

  private setNum(key: string, value: string): void {
    const n = parseInt(value, 10);
    this.settings[key] = isNaN(n) ? 0 : n;
  }

  private selectOptions(field: FieldDef): SelectOption[] {
    const list: SelectOption[] = [];
    if (field.options !== undefined) {
      for (let i = 0; i < field.options.length; i++) {
        list.push({ value: field.options[i].text });
      }
    }
    return list;
  }

  private selectLabel(field: FieldDef): string {
    const current = this.settings[field.key];
    if (field.options !== undefined) {
      for (let i = 0; i < field.options.length; i++) {
        if (String(field.options[i].value) === String(current ?? '')) {
          return field.options[i].text;
        }
      }
    }
    return this.str(field.key);
  }

  private selectIndex(field: FieldDef): number {
    const current = String(this.settings[field.key] ?? '');
    if (field.options !== undefined) {
      for (let i = 0; i < field.options.length; i++) {
        if (String(field.options[i].value) === current) {
          return i;
        }
      }
    }
    return 0;
  }

  private onPick(field: FieldDef, index: number): void {
    if (field.options === undefined || index < 0 || index >= field.options.length) {
      return;
    }
    this.settings[field.key] = field.options[index].value;
    this.version++;
  }

  private socials(): Record<string, Object>[] {
    const list = this.settings['SOCIALS'];
    return Array.isArray(list) ? list as Record<string, Object>[] : [];
  }

  private socialEnabled(value: string): boolean {
    const list = this.socials();
    for (let i = 0; i < list.length; i++) {
      if (String(list[i]['value'] ?? '') === value) {
        return true;
      }
    }
    return false;
  }

  private toggleSocial(item: SnsItem, on: boolean): void {
    const value = String(item.value ?? '');
    let list = this.socials();
    if (on) {
      for (let i = 0; i < list.length; i++) {
        if (String(list[i]['value'] ?? '') === value) {
          return;
        }
      }
      const record: Record<string, Object> = {
        'text': item.text !== undefined ? item.text : '',
        'value': item.value !== undefined ? item.value : '',
        'link': item.link !== undefined ? item.link : '',
      };
      list.push(record);
    } else {
      list = list.filter((s: Record<string, Object>) => String(s['value'] ?? '') !== value);
      this.settings['SOCIALS'] = list;
    }
    this.version++;
  }

  private socialAuthKey(value: string, suffix: string): string {
    return `SOCIAL_AUTH_${value.toUpperCase()}_${suffix}`;
  }

  private friends(): Record<string, Object>[] {
    const list = this.settings['FRIENDS'];
    return Array.isArray(list) ? list as Record<string, Object>[] : [];
  }

  private addFriend(): void {
    this.friends().push({ 'text': '', 'href': '' });
    this.version++;
  }

  private removeFriend(index: number): void {
    this.friends().splice(index, 1);
    this.version++;
  }

  private allMetaSources(): string[] {
    const list = this.settings['META_ALL_SOURCES'];
    if (Array.isArray(list) && list.length > 0) {
      return list as string[];
    }
    return DEFAULT_META_SOURCES;
  }

  private selectedSources(): string[] {
    const list = this.settings['META_SELECTED_SOURCES'];
    if (Array.isArray(list)) {
      return list as string[];
    }
    return this.allMetaSources().slice();
  }

  private metaSourceLabel(source: string): string {
    const label = META_SOURCE_LABELS[source];
    return label !== undefined ? label : source;
  }

  private toggleSource(source: string): void {
    const next = this.selectedSourceNames.slice();
    const index = next.indexOf(source);
    if (index >= 0) {
      next.splice(index, 1);
    } else {
      next.push(source);
    }
    // 用新数组触发 @State 更新，同时写回 settings 供保存提交
    this.selectedSourceNames = next;
    this.settings['META_SELECTED_SOURCES'] = next;
    this.version++;
  }

  private labelColor(danger?: boolean): ResourceColor {
    return danger === true ? $r('app.color.error') : $r('app.color.text_primary');
  }

  build() {
    Column() {
      PageScaffold({
        title: '管理设置',
        showBack: true,
        content: () => {
          this.pageContent();
        },
      })
        .layoutWeight(1);
      this.saveBar();
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'));
  }

  @Builder
  saveBar() {
    Row({ space: 12 }) {
      SecondaryButton({
        label: '重启服务',
        buttonEnabled: !this.saving && !this.loading,
        fullWidth: false,
        onTap: () => this.restartServer(),
      }).layoutWeight(1);
      PrimaryButton({
        label: this.saving ? '保存中…' : '保存设置',
        buttonEnabled: !this.saving && !this.loading,
        fullWidth: false,
        onTap: () => this.save(),
      }).layoutWeight(1);
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 12 });
  }

  @Builder
  pageContent() {
    if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      Column({ space: 12 }) {
        EmptyState({ message: this.loadError });
        SecondaryButton({
          label: '重新加载',
          onTap: () => {
            void this.load();
          },
        });
      }
      .width('100%')
      .padding(24);
    } else {
      Scroll() {
        Column({ space: 12 }) {
          if (this.sysInfoSummary.length > 0) {
            Column({ space: 4 }) {
              Text('系统信息')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'));
              Text(this.sysInfoSummary)
                .fontSize(13)
                .fontColor($r('app.color.text_primary'));
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding($r('app.float.card_padding'))
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));
          }
          this.serverNotesCard();
          ForEach(CARDS, (card: CardDef) => {
            this.cardView(card);
          }, (card: CardDef) => `${card.title}-${this.version}`);
          this.socialCard();
          this.emailCard();
          this.friendsCard();
          this.sourcesCard();
          this.aiCard();
        }
        .width('100%')
        .padding($r('app.float.page_padding'));
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off);
    }
  }

  /** 「书籍分类」编辑器：分类逐行展示与删除，底部新增。 */
  @Builder
  categoryEditor() {
    Column({ space: 10 }) {
      Row() {
        Text(`已配置分类（${this.categoryEntries.length}）`)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        Text('修改后需点击保存生效')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'));
      }
      .width('100%');

      if (this.categoryEntries.length === 0) {
        Text('暂无分类，使用下方输入框添加')
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 12 });
      } else {
        Column({ space: 8 }) {
          ForEach(this.categoryEntries, (entry: CategoryEntry) => {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text(entry.name)
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                if (entry.tags.length > 0) {
                  Text(`标签：${entry.tags}`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis });
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);
              IconCircleButton({
                icon: $r('sys.symbol.trash'),
                variant: 'soft',
                iconSize: 14,
                buttonSize: 30,
                onTap: () => this.removeCategory(entry.name),
              });
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.page_background'));
          }, (entry: CategoryEntry) => entry.name);
        }
        .width('100%');
      }

      Column({ space: 8 }) {
        TextInput({ text: this.newCategoryName, placeholder: '分类名称' })
          .width('100%')
          .height(40)
          .onChange((value: string) => {
            this.newCategoryName = value;
          });
        TextInput({ text: this.newCategoryTags, placeholder: '绑定标签（可选），多个用 / 分隔' })
          .width('100%')
          .height(40)
          .onChange((value: string) => {
            this.newCategoryTags = value;
          });
        Row() {
          Blank();
          SecondaryButton({
            label: '添加分类',
            compact: true,
            fullWidth: false,
            onTap: () => {
              this.addCategory();
            },
          });
        }
        .width('100%');
      }
      .width('100%')
      .padding({ top: 4 });
    }
    .width('100%');
  }

  /** 服务端更新说明与致谢名单（无数据时不渲染）。 */
  @Builder
  serverNotesCard() {
    if (this.releaseNotes.length > 0 || this.thanksNames.length > 0) {
      Column({ space: 10 }) {
        Text('服务端信息')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'));
        if (this.releaseNotes.length > 0) {
          Column({ space: 4 }) {
            Text('更新说明')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'));
            Text(this.releaseNotes)
              .fontSize(13)
              .fontColor($r('app.color.text_primary'));
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start);
        }
        if (this.thanksNames.length > 0) {
          Column({ space: 4 }) {
            Text('致谢名单')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'));
            Text(this.thanksNames.join('、'))
              .fontSize(13)
              .fontColor($r('app.color.text_primary'));
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start);
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding($r('app.float.card_padding'))
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));
    }
  }

  @Builder
  cardView(card: CardDef) {
    Column({ space: 10 }) {
      Row() {
        Text(card.title)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        SymbolGlyph(this.isExpanded(card.title) ?
          $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(16)
          .fontColor([$r('app.color.text_tertiary')]);
      }
      .width('100%')
      .onClick(() => this.toggleExpand(card.title));
      if (this.isExpanded(card.title)) {
        if (card.subtitle !== undefined && card.subtitle.length > 0) {
          Text(card.subtitle)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'));
        }
        ForEach(card.fields, (field: FieldDef) => {
          this.fieldView(field);
        }, (field: FieldDef) => field.key);
        if (card.groups !== undefined) {
          ForEach(card.groups, (group: FieldGroupDef) => {
            Row() {
              Text(group.label)
                .fontSize(15)
                .fontColor(this.labelColor());
              Blank();
              Toggle({ type: ToggleType.Switch, isOn: this.bool(group.key) })
                .onChange((value: boolean) => this.setBool(group.key, value));
            }
            .width('100%');
            if (this.bool(group.key) && group.fields.length > 0) {
              Column({ space: 10 }) {
                ForEach(group.fields, (field: FieldDef) => {
                  this.fieldView(field);
                }, (field: FieldDef) => field.key);
              }
              .width('100%')
              .padding({ left: 16 })
              .border({ width: { left: 2 }, color: { left: $r('app.color.divider') } });
            }
          }, (group: FieldGroupDef) => group.key);
        }
        if (card.title === '书籍分类') {
          this.categoryEditor();
        }
        if (card.title === '扩展功能') {
          Text(this.stampExists ? '当前已有图章文件' : '尚未上传图章')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'));
          SecondaryButton({
            label: this.stampBusy ? '上传中…' : '上传图章 PNG',
            compact: true,
            fullWidth: false,
            buttonEnabled: !this.stampBusy,
            onTap: () => {
              void this.uploadStampImage();
            },
          });
        }
        if (card.title === '高级配置项') {
          if (this.adminTokenPreview.length > 0) {
            Text(this.adminTokenPreview)
              .fontSize(12)
              .fontColor($r('app.color.text_primary'));
          }
          Row({ space: 8 }) {
            SecondaryButton({
              label: this.tokenBusy ? '生成中…' : '生成 MCP Token',
              compact: true,
              fullWidth: false,
              buttonEnabled: !this.tokenBusy,
              onTap: () => {
                void this.generateToken();
              },
            });
            SecondaryButton({
              label: '复制 Token',
              compact: true,
              fullWidth: false,
              buttonEnabled: this.adminTokenPreview.length > 0,
              onTap: () => this.copyText(this.adminTokenPreview),
            });
          }
          SecondaryButton({
            label: this.sslBusy ? '上传中…' : '上传 SSL 证书',
            compact: true,
            fullWidth: false,
            buttonEnabled: !this.sslBusy,
            onTap: () => {
              void this.uploadSslPair();
            },
          });
        }
        if (card.title === '书栈服务') {
          SecondaryButton({
            label: this.bookbarnBusy ? '申请中…' : '申请书栈 Token',
            compact: true,
            fullWidth: false,
            buttonEnabled: !this.bookbarnBusy,
            onTap: () => this.applyBookbarn(),
          });
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  fieldView(field: FieldDef) {
    if (field.kind === 'bool') {
      Row() {
        Text(field.label)
          .fontSize(15)
          .fontColor(this.labelColor(field.danger));
        Blank();
        Toggle({ type: ToggleType.Switch, isOn: this.bool(field.key) })
          .onChange((value: boolean) => this.setBool(field.key, value));
      }
      .width('100%');
    } else if (field.kind === 'select') {
      Column({ space: 6 }) {
        Text(field.label)
          .fontSize(15)
          .fontColor(this.labelColor(field.danger));
        Select(this.selectOptions(field))
          .selected(this.selectIndex(field))
          .value(this.selectLabel(field))
          .fontColor($r('app.color.text_primary'))
          .font({ size: 14 })
          .backgroundColor($r('app.color.page_background'))
          .onSelect((index: number) => this.onPick(field, index));
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    } else if (field.kind === 'textarea') {
      Column({ space: 6 }) {
        Text(field.label)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'));
        TextArea({ text: this.str(field.key) })
          .height(90)
          .fontSize(14)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .onChange((value: string) => this.setText(field.key, value));
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    } else {
      Column({ space: 6 }) {
        Text(field.label)
          .fontSize(15)
          .fontColor(this.labelColor(field.danger));
        TextInput({ text: this.str(field.key) })
          .height(44)
          .fontSize(14)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .type(field.kind === 'number' ? InputType.Number :
            (field.secret === true ? InputType.Password : InputType.Normal))
          .onChange((value: string) => {
            if (field.kind === 'number') {
              this.setNum(field.key, value);
            } else {
              this.setText(field.key, value);
            }
          });
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
  }

  @Builder
  sectionTitle(title: string, subtitle?: string) {
    Row() {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'));
        if (subtitle !== undefined && subtitle.length > 0 && this.isExpanded(title)) {
          Text(subtitle)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'));
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
      SymbolGlyph(this.isExpanded(title) ?
        $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
        .fontSize(16)
        .fontColor([$r('app.color.text_tertiary')]);
    }
    .width('100%')
    .onClick(() => this.toggleExpand(title));
  }

  @Builder
  socialCard() {
    Column({ space: 10 }) {
      this.sectionTitle('社交网络登录', '所启用的社交网络将会在登录页面自动显示按钮。');
      if (this.isExpanded('社交网络登录')) {
        if (this.snsItems.length === 0) {
          Text('服务端未返回可选社交网络')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'));
        }
        ForEach(this.snsItems, (item: SnsItem) => {
          this.socialItem(item);
        }, (item: SnsItem) => `${String(item.value ?? '')}-${this.version}`);
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  socialItem(item: SnsItem) {
    Column({ space: 8 }) {
      Row() {
        Text(String(item.text ?? ''))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'));
        Blank();
        Toggle({ type: ToggleType.Switch, isOn: this.socialEnabled(String(item.value ?? '')) })
          .onChange((value: boolean) => this.toggleSocial(item, value));
      }
      .width('100%');
      if (this.socialEnabled(String(item.value ?? ''))) {
        Column({ space: 8 }) {
          Text(`Key/AppID 与 Secret（回调地址：${this.siteUrlOf()}/auth/complete/${String(item.value ?? '')}.do）`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'));
          TextInput({ text: this.str(this.socialAuthKey(String(item.value ?? ''), 'KEY')) })
            .height(44)
            .fontSize(14)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .onChange((value: string) => this.setText(this.socialAuthKey(String(item.value ?? ''), 'KEY'), value));
          TextInput({ text: this.str(this.socialAuthKey(String(item.value ?? ''), 'SECRET')) })
            .height(44)
            .fontSize(14)
            .borderRadius(8)
            .backgroundColor($r('app.color.page_background'))
            .type(InputType.Password)
            .onChange((value: string) => this.setText(this.socialAuthKey(String(item.value ?? ''), 'SECRET'), value));
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(12)
        .borderRadius(8)
        .backgroundColor($r('app.color.page_background'));
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  private siteUrlOf(): string {
    return this.siteUrl;
  }

  @Builder
  emailCard() {
    Column({ space: 10 }) {
      this.sectionTitle('邮件服务', '邮箱注册、推送 Kindle 依赖此配置（SMTP 服务器地址可带端口，默认为 465 号）。');
      if (this.isExpanded('邮件服务')) {
        this.fieldView(text('smtp_server', 'SMTP服务器（例如 smtp.126.com）'));
        this.fieldView(text('smtp_username', 'SMTP用户名（例如 user@126.com）'));
        this.fieldView(text('smtp_password', 'SMTP密码', false, true));
        this.fieldView(select('smtp_encryption', 'SMTP安全性', SMTP_ENCRYPTION));
        SecondaryButton({
          label: '测试邮件',
          compact: true,
          fullWidth: false,
          onTap: () => this.testEmail(),
        });
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  friendsCard() {
    Column({ space: 10 }) {
      this.sectionTitle('友情链接');
      if (this.isExpanded('友情链接')) {
        ForEach(this.friends(), (friend: Record<string, Object>, index: number) => {
          Row({ space: 8 }) {
            TextInput({ text: String(friend['text'] ?? ''), placeholder: '名称' })
              .height(44)
              .fontSize(14)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .layoutWeight(1)
              .onChange((value: string) => {
                this.friends()[index]['text'] = value;
              });
            TextInput({ text: String(friend['href'] ?? ''), placeholder: '链接' })
              .height(44)
              .fontSize(14)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .layoutWeight(2)
              .onChange((value: string) => {
                this.friends()[index]['href'] = value;
              });
            Text('删除')
              .fontSize(14)
              .fontColor($r('app.color.error'))
              .onClick(() => this.removeFriend(index));
          }
          .width('100%')
          .alignItems(VerticalAlign.Center);
        }, (friend: Record<string, Object>, index: number) => `friend-${index}-${this.version}`);
        SecondaryButton({
          label: '添加友情链接',
          compact: true,
          fullWidth: false,
          onTap: () => this.addFriend(),
        });
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  sourcesCard() {
    Column({ space: 10 }) {
      this.sectionTitle('互联网书籍信息源', '自动拉取新书信息的数据来源，支持多选。');
      if (this.isExpanded('互联网书籍信息源')) {
        this.fieldView(bool('auto_fill_meta', '自动从互联网拉取新书的书籍信息'));
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.allMetaSources(), (source: string) => {
            Row({ space: 4 }) {
              Text(this.selectedSourceNames.indexOf(source) >= 0 ? '✓ ' : '')
                .fontSize(13)
                .fontColor($r('app.color.on_brand'));
              Text(this.metaSourceLabel(source))
                .fontSize(13)
                .fontColor(this.selectedSourceNames.indexOf(source) >= 0 ?
                  $r('app.color.on_brand') : $r('app.color.text_secondary'));
            }
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius($r('app.float.chip_radius'))
            .backgroundColor(this.selectedSourceNames.indexOf(source) >= 0 ?
              $r('app.color.brand_primary') : $r('app.color.page_background'))
            .margin({ right: 8, bottom: 8 })
            .onClick(() => this.toggleSource(source));
          }, (source: string) => `${source}-${this.version}`);
        }
        .width('100%');
        this.fieldView(text('douban_baseurl', '豆瓣插件API地址（例如 http://10.0.0.1:8080 ）'));
        this.fieldView(text('douban_apikey', '豆瓣插件API密钥'));
        this.fieldView(numberField('douban_max_count', '豆瓣插件API查询结果数量'));
        this.fieldView(numberField('ujxsw_max_count', '悠久小说网插件查询结果数量'));
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  aiCard() {
    Column({ space: 10 }) {
      this.sectionTitle('AI助手', '配置AI助手相关功能（Beta）。');
      if (this.isExpanded('AI助手')) {
        this.fieldView(bool('AI_ENABLED', '启用AI助手'));
        this.fieldView(bool('AI_ALLOW_SET_CATEGORY', '使用AI生成的书籍分类'));
        this.fieldView(text('AI_API_URL', 'AI接口地址（OpenAPI 兼容接口地址）'));
        this.fieldView(text('AI_MODEL', 'AI模型'));
        this.fieldView(text('AI_DEEPSEEK_API_KEY', 'API密钥', false, true));
        SecondaryButton({
          label: '测试AI设置',
          compact: true,
          fullWidth: false,
          onTap: () => this.testAI(),
        });
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }
}
