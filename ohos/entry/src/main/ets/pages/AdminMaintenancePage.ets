import { common } from '@kit.AbilityKit';
import { PageScaffold, LoadingState, EmptyState, PrimaryButton, SecondaryButton, DangerButton,
  SectionTitle, TextButton } from '../components';
import {
  AdminMaintenanceApi, AdminUpdateStatus, AdminAudioStatsResponse, AdminPodcastAuditLog,
  AdminKindleConvertStatus,
} from '../services/AdminMaintenanceApi';
import { BookUploadService, PickedBookFile } from '../services/BookUploadService';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';

/** 审计日志只渲染最近 N 条，避免长列表进入 Scroll。 */
const AUDIT_RENDER_LIMIT: number = 30;

@Entry
@Component
struct AdminMaintenancePage {
  @State private supported: boolean = true;
  @State private loading: boolean = true;
  @State private loadError: string = '';
  @State private working: string = '';
  @State private updateStatus: AdminUpdateStatus = {};
  @State private audioStats: AdminAudioStatsResponse = {};
  @State private kindleStatus: AdminKindleConvertStatus = {};
  @State private auditLogs: AdminPodcastAuditLog[] = [];
  @State private dbUrl: string = '';
  @State private hint: string = '';

  aboutToAppear(): void {
    this.supported = ServerRegistry.supports(ServerFeature.ADMIN_MAINTENANCE);
    if (this.supported) {
      void this.load();
    } else {
      this.loading = false;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private messageOf(err: string | undefined, msg: string | undefined, fallback: string): string {
    if (msg !== undefined && msg.length > 0) {
      return msg;
    }
    if (err !== undefined && err !== 'ok') {
      return err;
    }
    return fallback;
  }

  private async load(): Promise<void> {
    this.loading = this.updateStatus.current_version === undefined;
    this.loadError = '';
    try {
      await TalebookService.ensureAuthenticated();
      const updateRsp = await AdminMaintenanceApi.getUpdateStatus();
      if (updateRsp.err !== undefined && updateRsp.err !== 'ok') {
        this.loadError = this.messageOf(updateRsp.err, updateRsp.msg, '更新状态加载失败');
        return;
      }
      this.updateStatus = updateRsp.status ?? {};
      await this.loadAudioStats();
      await this.loadKindleStatus();
      await this.loadAudits();
    } catch (e) {
      this.loadError = `加载失败：${e}`;
    } finally {
      this.loading = false;
    }
  }

  private async loadAudioStats(): Promise<void> {
    const rsp = await AdminMaintenanceApi.getAudioStats();
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      this.toast(this.messageOf(rsp.err, rsp.msg, '统计加载失败'));
      return;
    }
    this.audioStats = rsp;
  }

  private async loadKindleStatus(): Promise<void> {
    const rsp = await AdminMaintenanceApi.getKindleConvertStatus();
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      return;
    }
    this.kindleStatus = rsp.status ?? {};
  }

  private async loadAudits(): Promise<void> {
    const rsp = await AdminMaintenanceApi.listPodcastAudits();
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      this.toast(this.messageOf(rsp.err, rsp.msg, '审计日志加载失败'));
      return;
    }
    this.auditLogs = rsp.logs ?? [];
  }

  // ---- 格式化 ----

  private formatMs(ms: number): string {
    if (ms >= 3600000) {
      return `${(ms / 3600000).toFixed(1)} 小时`;
    }
    if (ms >= 60000) {
      return `${(ms / 60000).toFixed(0)} 分钟`;
    }
    return `${(ms / 1000).toFixed(0)} 秒`;
  }

  private formatBytes(bytes: number): string {
    if (bytes >= 1024 * 1024 * 1024) {
      return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
    }
    if (bytes >= 1024 * 1024) {
      return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    }
    if (bytes >= 1024) {
      return `${(bytes / 1024).toFixed(0)} KB`;
    }
    return `${bytes} B`;
  }

  private formatTimestamp(seconds: number): string {
    if (seconds <= 0) {
      return '未检查';
    }
    return new Date(seconds * 1000).toLocaleString();
  }

  private updateSummary(): string {
    const current: string = this.updateStatus.current_version ?? '-';
    const latest: string = this.updateStatus.latest_version ?? '-';
    if (this.updateStatus.check_error !== undefined && this.updateStatus.check_error.length > 0) {
      return `当前 ${current} · 检查失败：${this.updateStatus.check_error}`;
    }
    return `当前 ${current} · 最新 ${latest} · ${this.updateStatus.has_update === true ? '有可用更新' : '已是最新'}`;
  }

  private kindleSummary(): string {
    return `完成 ${this.kindleStatus.done ?? 0} · 跳过 ${this.kindleStatus.skip ?? 0}`
      + ` · 失败 ${this.kindleStatus.fail ?? 0} / 共 ${this.kindleStatus.total ?? 0}`
      + `${this.kindleStatus.running === true ? ' · 运行中' : ''}`;
  }

  private audioSummary(): string {
    const first = this.audioStats.first_party;
    const podcast = this.audioStats.podcast_estimated;
    const jobs = this.audioStats.jobs;
    const listened: number = first !== undefined && first.listened_ms !== undefined ? first.listened_ms : 0;
    const sessions: number = first !== undefined && first.sessions !== undefined ? first.sessions : 0;
    const requests: number = podcast !== undefined && podcast.requests !== undefined ? podcast.requests : 0;
    const bytes: number = podcast !== undefined && podcast.bytes !== undefined ? podcast.bytes : 0;
    const totalJobs: number = jobs !== undefined && jobs.total !== undefined ? jobs.total : 0;
    const failedJobs: number = jobs !== undefined && jobs.failed !== undefined ? jobs.failed : 0;
    return `本机播放 ${this.formatMs(listened)} / ${sessions} 会话\n`
      + `播客分发 ${requests} 次 · ${this.formatBytes(bytes)}\n`
      + `转换任务 ${totalJobs} 个（失败 ${failedJobs}）`;
  }

  private auditLine(log: AdminPodcastAuditLog): string {
    const kind: string = log.kind ?? '-';
    const status: number = log.status !== undefined ? log.status : 0;
    const bytes: number = log.bytes_sent !== undefined ? log.bytes_sent : 0;
    const ip: string = log.ip !== undefined ? log.ip : '';
    const created: string = log.created_at !== undefined ? log.created_at : '';
    const subscription: number = log.subscription_id !== undefined ? log.subscription_id : 0;
    return `#${log.id ?? 0} 订阅${subscription} · ${kind} · ${status} · ${this.formatBytes(bytes)}`
      + `${ip.length > 0 ? ` · ${ip}` : ''} · ${created}`;
  }

  // ---- 动作 ----

  private checkUpdates(): void {
    if (this.working.length > 0) {
      return;
    }
    this.working = 'update';
    this.hint = '正在向 GitHub 查询最新版本…';
    AdminMaintenanceApi.checkForUpdates().then((rsp) => {
      this.working = '';
      this.hint = '';
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.updateStatus = rsp.status ?? this.updateStatus;
        this.toast(this.updateStatus.has_update === true ? '发现新版本' : '已是最新版本');
      } else {
        this.toast(this.messageOf(rsp.err, rsp.msg, '检查失败'));
      }
    }).catch((e: Object) => {
      this.working = '';
      this.hint = '';
      this.toast(`检查失败：${e}`);
    });
  }

  private async uploadSslPair(): Promise<void> {
    if (this.working.length > 0) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    this.toast('请选择证书文件（.crt / .pem / .cer）');
    const crt: PickedBookFile | null = await BookUploadService.pickStagedFile(
      context, ['.crt', '.pem', '.cer'], 'ssl_crt');
    if (crt === null) {
      return;
    }
    this.toast('请选择私钥文件（.key / .pem）');
    const key: PickedBookFile | null = await BookUploadService.pickStagedFile(
      context, ['.key', '.pem'], 'ssl_key');
    if (key === null) {
      BookUploadService.removeStagedFile(crt.localPath);
      return;
    }
    this.working = 'ssl';
    try {
      const rsp = await AdminMaintenanceApi.uploadSsl(crt.localPath, crt.name,
        key.localPath, key.name);
      BookUploadService.removeStagedFile(crt.localPath);
      BookUploadService.removeStagedFile(key.localPath);
      this.toast(this.messageOf(rsp.err, rsp.msg, 'SSL 证书已上传'));
    } catch (e) {
      this.toast(`SSL 上传失败：${e}`);
    } finally {
      this.working = '';
    }
  }

  private testDatabase(): void {
    const url: string = this.dbUrl.trim();
    if (url.length === 0) {
      this.toast('请填写数据库地址');
      return;
    }
    if (this.working.length > 0) {
      return;
    }
    this.working = 'testdb';
    AdminMaintenanceApi.testDatabase(url).then((rsp) => {
      this.working = '';
      this.toast(this.messageOf(rsp.err, rsp.msg, '连接成功'));
    }).catch((e: Object) => {
      this.working = '';
      this.toast(`测试失败：${e}`);
    });
  }

  private confirmMigrate(): void {
    const url: string = this.dbUrl.trim();
    if (url.length === 0) {
      this.toast('请填写目标数据库地址');
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '迁移数据库',
      message: `将把全部用户数据迁移到：\n${url}\n迁移成功后需要重启服务端，确定继续？`,
      primaryButton: {
        value: '迁移',
        action: () => {
          this.doMigrate(url, false);
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  /** force=false 时若目标库非空，上游返回 db.target_has_data，需再次确认后强制迁移。 */
  private doMigrate(url: string, force: boolean): void {
    this.working = 'migrate';
    AdminMaintenanceApi.migrateDatabase(url, force).then((rsp) => {
      this.working = '';
      if (rsp.err === undefined || rsp.err === 'ok') {
        const restart: string = rsp.need_restart === true ? '（请重启服务端生效）' : '';
        this.toast(this.messageOf(rsp.err, rsp.msg, `迁移完成${restart}`));
        return;
      }
      if (rsp.err === 'db.target_has_data') {
        const count: number = rsp.count !== undefined ? rsp.count : 0;
        this.getUIContext().showAlertDialog({
          title: '目标库已有数据',
          message: `目标数据库已有 ${count} 条记录，强制迁移会清空这些数据。确定强制迁移？`,
          primaryButton: {
            value: '强制迁移',
            action: () => {
              this.doMigrate(url, true);
            },
          },
          secondaryButton: { value: '取消', action: () => {} },
        });
        return;
      }
      this.toast(this.messageOf(rsp.err, rsp.msg, '迁移失败'));
    }).catch((e: Object) => {
      this.working = '';
      this.toast(`迁移失败：${e}`);
    });
  }

  private confirmKindleConvert(): void {
    this.getUIContext().showAlertDialog({
      title: 'Kindle 格式批量转换',
      message: '将把书库中全部 Kindle 格式（azw/azw3/mobi）批量转换为 EPUB，过程较慢且会写入书库。确定继续？',
      primaryButton: {
        value: '开始转换',
        action: () => {
          this.runKindleConvert();
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private runKindleConvert(): void {
    if (this.working.length > 0) {
      return;
    }
    this.working = 'kindle';
    AdminMaintenanceApi.runKindleConvert([]).then((rsp) => {
      this.working = '';
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.toast(this.messageOf(rsp.err, rsp.msg, '转换任务已启动'));
        void this.loadKindleStatus();
      } else {
        this.toast(this.messageOf(rsp.err, rsp.msg, '启动失败'));
      }
    }).catch((e: Object) => {
      this.working = '';
      this.toast(`启动失败：${e}`);
    });
  }

  private setFrozen(log: AdminPodcastAuditLog, freeze: boolean): void {
    const subscriptionId: number = log.subscription_id !== undefined ? log.subscription_id : 0;
    if (subscriptionId <= 0 || this.working.length > 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: freeze ? '冻结订阅' : '解冻订阅',
      message: freeze
        ? `将冻结订阅 #${subscriptionId}，其播客抓取将被拒绝，确定继续？`
        : `将解冻订阅 #${subscriptionId}，确定继续？`,
      primaryButton: {
        value: freeze ? '冻结' : '解冻',
        action: () => {
          this.working = `freeze-${subscriptionId}`;
          AdminMaintenanceApi.setPodcastSubscriptionFrozen(subscriptionId, freeze, 'manual')
            .then((rsp) => {
              this.working = '';
              if (rsp.err === undefined || rsp.err === 'ok') {
                this.toast(freeze ? '已冻结' : '已解冻');
                void this.loadAudits();
              } else {
                this.toast(this.messageOf(rsp.err, rsp.msg, '操作失败'));
              }
            }).catch((e: Object) => {
              this.working = '';
              this.toast(`操作失败：${e}`);
            });
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  build() {
    Column() {
      PageScaffold({
        title: '服务端维护',
        showBack: true,
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  pageContent() {
    if (!this.supported) {
      EmptyState({ message: '当前服务端不支持服务端维护（需要 Talebook）' });
    } else if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({ message: this.loadError, actionLabel: '重试', onAction: () => { void this.load(); } });
    } else {
      Scroll() {
        Column({ space: 8 }) {
          this.updateSection();
          this.sslSection();
          this.databaseSection();
          this.audioSection();
          this.auditSection();
          this.kindleSection();
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 });
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top);
    }
  }

  @Builder
  updateSection() {
    SectionTitle({ title: '版本更新' });
    Column({ space: 8 }) {
      Text(this.updateSummary())
        .fontSize(13)
        .fontColor(this.updateStatus.has_update === true
          ? $r('app.color.brand_primary') : $r('app.color.text_secondary'))
        .width('100%');
      if (this.updateStatus.latest_release_name !== undefined
        && this.updateStatus.latest_release_name.length > 0) {
        Text(`发布：${this.updateStatus.latest_release_name}`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }
      Text(`上次检查：${this.formatTimestamp(this.updateStatus.last_check_time ?? 0)}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
      }
      PrimaryButton({
        label: this.working === 'update' ? '检查中…' : '检查更新',
        buttonEnabled: this.working.length === 0,
        onTap: () => this.checkUpdates(),
      });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  sslSection() {
    SectionTitle({ title: 'SSL 证书' });
    Column({ space: 8 }) {
      Text('依次选择证书（.crt/.pem/.cer）与私钥（.key/.pem），上传后需重启服务端生效。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
      SecondaryButton({
        label: this.working === 'ssl' ? '上传中…' : '上传证书与私钥',
        buttonEnabled: this.working.length === 0,
        onTap: () => {
          void this.uploadSslPair();
        },
      });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  databaseSection() {
    SectionTitle({ title: '数据库' });
    Column({ space: 8 }) {
      TextInput({
        placeholder: 'mysql+pymysql://user:pass@host:3306/talebook?charset=utf8mb4',
        text: this.dbUrl,
      })
        .height($r('app.float.button_height_compact'))
        .onChange((value: string) => {
          this.dbUrl = value;
        });
      Text('SQLite 无需测试连接；迁移前请确认已备份当前数据库。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
      Row({ space: 12 }) {
        SecondaryButton({
          label: this.working === 'testdb' ? '测试中…' : '测试连接',
          buttonEnabled: this.working.length === 0,
          fullWidth: false,
          onTap: () => this.testDatabase(),
        }).layoutWeight(1);
        DangerButton({
          label: this.working === 'migrate' ? '迁移中…' : '迁移数据',
          buttonEnabled: this.working.length === 0,
          fullWidth: false,
          onTap: () => this.confirmMigrate(),
        }).layoutWeight(1);
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  audioSection() {
    SectionTitle({ title: '有声书统计', actionLabel: '刷新',
      onAction: () => { void this.loadAudioStats(); } });
    Column({ space: 4 }) {
      Text(this.audioSummary())
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  auditSection() {
    SectionTitle({ title: `播客访问审计（${this.auditLogs.length} 条）`, actionLabel: '刷新',
      onAction: () => { void this.loadAudits(); } });
    Column({ space: 6 }) {
      if (this.auditLogs.length === 0) {
        Text('暂无访问记录')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      } else {
        Text('冻结状态无法从审计接口读取，冻结/解冻按订阅号直接下发。')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
        ForEach(this.auditLogs.slice(0, AUDIT_RENDER_LIMIT), (log: AdminPodcastAuditLog) => {
          this.auditRow(log);
        }, (log: AdminPodcastAuditLog) => `audit-${log.id ?? 0}`);
        if (this.auditLogs.length > AUDIT_RENDER_LIMIT) {
          Text(`仅显示最近 ${AUDIT_RENDER_LIMIT} 条`)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%');
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
  auditRow(log: AdminPodcastAuditLog) {
    Column({ space: 4 }) {
      Text(this.auditLine(log))
        .fontSize(12)
        .fontColor($r('app.color.text_primary'))
        .width('100%');
      Row({ space: 8 }) {
        TextButton({
          label: '冻结订阅',
          tone: 'danger',
          onTap: () => this.setFrozen(log, true),
        });
        TextButton({
          label: '解冻订阅',
          onTap: () => this.setFrozen(log, false),
        });
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 });
  }

  @Builder
  kindleSection() {
    SectionTitle({ title: 'Kindle 格式批量转换', actionLabel: '刷新进度',
      onAction: () => { void this.loadKindleStatus(); } });
    Column({ space: 8 }) {
      Text(this.kindleSummary())
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      Text('把 azw/azw3/mobi 批量转为 EPUB；可在书库管理页右上角查看进度。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
      PrimaryButton({
        label: this.working === 'kindle' ? '启动中…' : '开始转换',
        buttonEnabled: this.working.length === 0 && this.kindleStatus.running !== true,
        onTap: () => this.confirmKindleConvert(),
      });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }
}
