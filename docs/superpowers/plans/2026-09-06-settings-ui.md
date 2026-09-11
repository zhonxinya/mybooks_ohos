# Settings UI 完善 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按「3+1 + A 档」完善鸿蒙三处设置页：先补齐 `AdminSettingsPage` 折叠与缺失动作，再美化并补全主 Tab `SettingsPage` 与 `UserSettingsPage`。

**Architecture:** 就地增强现有页面，复用 `SettingCell` / `SectionTitle` / `PageScaffold` / 按钮组件与 `BookUploadService` 选文件；Admin 用 `@State expandedCards` 控制折叠；缺失管理动作直接调用已有 `TalebookApi` 方法；个人设置扩展 `UserUpdatePayload.podcast_token` 并对齐 Web 端生成 token 逻辑。

**Tech Stack:** HarmonyOS ArkTS / ArkUI、`TalebookApi` + `TalebookCoreService`、`BookUploadService`（DocumentViewPicker）、`@kit.BasicServicesKit` pasteboard（复制 Token）、`scripts/build-hap.ps1` 编译验收。

**Spec:** `docs/superpowers/specs/2026-09-06-settings-ui-design.md`

## Global Constraints

- 优先级：Admin → SettingsPage → UserSettingsPage；Admin 完成度 A 档（保留表单 + 补动作 + 折叠视觉）。
- 不做：Profile 重做、阅读范围详情、Thanks Notes、与 Web 像素对齐、新建 SettingsShell。
- 仅改任务相关文件；风格匹配现有 ArkTS；编译必须通过 `powershell -NoProfile -File scripts/build-hap.ps1`。
- **不要自动 git commit**，除非用户明确要求提交。

---

## File map

| File | Responsibility |
|------|----------------|
| `ohos/entry/src/main/ets/pages/AdminSettingsPage.ets` | 折叠卡片、系统信息、印章/SSL/Token/书栈 Apply UI |
| `ohos/entry/src/main/ets/services/BookUploadService.ets` | 新增通用选文件（PNG/证书）辅助方法 |
| `ohos/entry/src/main/ets/pages/SettingsPage.ets` | 分区、主题弹窗、登录态与个人设置入口 |
| `ohos/entry/src/main/ets/pages/UserSettingsPage.ets` | VIP 卡、podcast_token、视觉统一 |
| `ohos/entry/src/main/ets/services/TalebookApi.ets` | `UserUpdatePayload.podcast_token`；导出 `VipInfoResponse`（若页面需 import） |

---

### Task 1: BookUploadService — 通用选文件

**Files:**
- Modify: `ohos/entry/src/main/ets/services/BookUploadService.ets`

**Interfaces:**
- Produces: `BookUploadService.pickStagedFile(context, suffixes: string[], stagedPrefix: string): Promise<PickedBookFile | null>`
- Consumes: 现有 `DocumentViewPicker` + cacheDir stage 模式（同 `pickAvatarImage`）

- [ ] **Step 1: 在 `pickAvatarImage` 旁新增通用方法**

```typescript
static async pickStagedFile(
  context: common.UIAbilityContext,
  suffixes: string[],
  stagedPrefix: string,
): Promise<PickedBookFile | null> {
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = 1;
  options.fileSuffixFilters = suffixes;
  const viewPicker = new picker.DocumentViewPicker();
  const uris = await viewPicker.select(options);
  if (uris.length === 0) {
    return null;
  }
  const stageDir = `${context.cacheDir}/upload`;
  try {
    if (!fs.accessSync(stageDir)) {
      fs.mkdirSync(stageDir, true);
    }
  } catch (_error) {
    fs.mkdirSync(stageDir, true);
  }
  const src = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
  try {
    const size = fs.statSync(src.fd).size;
    const rawName = BookUploadService.uriToName(uris[0]);
    const safeName = rawName.replace(/[\/\\]/g, '_');
    const destPath = `${stageDir}/${stagedPrefix}_${Date.now()}_${safeName}`;
    fs.copyFileSync(src.fd, destPath);
    return { name: safeName, size: size, localPath: destPath };
  } finally {
    fs.closeSync(src.fd);
  }
}
```

- [ ] **Step 2: 可选重构** — `pickAvatarImage` 内部可改为调用 `pickStagedFile(context, ['.jpg','.jpeg','.png','.webp'], 'avatar')`；若行为有风险则保持原实现、仅新增方法。

- [ ] **Step 3: 验证** — 暂不单独编译；随 Task 2 编译。

---

### Task 2: AdminSettingsPage — 折叠卡片 + 系统信息

**Files:**
- Modify: `ohos/entry/src/main/ets/pages/AdminSettingsPage.ets`

**Interfaces:**
- Consumes: `TalebookApi.getSysInfo()` → `SysInfoResponse`（`data?: Record<string, Object>`）
- Produces: `@State expandedKeys: string[]`；`toggleExpand(key: string)`；页头系统信息摘要

- [ ] **Step 1: 增加状态**

在 `AdminSettingsPage` 内：

```typescript
@State expandedKeys: string[] = ['基础信息'];
@State sysInfoSummary: string = '';
@State adminTokenPreview: string = '';
@State stampExists: boolean = false;
@State stampBusy: boolean = false;
@State sslBusy: boolean = false;
@State tokenBusy: boolean = false;
@State bookbarnBusy: boolean = false;
```

辅助：

```typescript
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
```

- [ ] **Step 2: 改 `cardView` 为可折叠**

标题行改为 `Row` + chevron；仅当 `isExpanded(card.title)` 时渲染 fields/groups。`socialCard` / `emailCard` / `friendsCard` / `sourcesCard` / `aiCard` 同样用固定 key（`'社交登录'` 等）包一层折叠头（可抽 `@Builder collapsibleCard(title, subtitle, contentBuilder)`，避免大复制）。

示例标题行：

```typescript
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
```

- [ ] **Step 3: 加载系统信息**

在 `load()` 成功后（设置已解析）调用：

```typescript
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
    // 若已知字段皆空，退化为取 data 前 4 个键
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
```

在 `pageContent` 的 Scroll 顶部（CARDS 之前）加卡片：

```typescript
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
```

同时在 `load()` 成功分支 `void this.refreshSysInfo(); void this.refreshStampStatus();`（stamp 方法见 Task 3）。

- [ ] **Step 4: 编译验证**

Run: `powershell -NoProfile -File scripts/build-hap.ps1`  
Expected: `BUILD SUCCESSFUL`（或仅剩与本任务无关的既有 WARN）。

---

### Task 3: AdminSettingsPage — 印章 / SSL / Token / 书栈 Apply

**Files:**
- Modify: `ohos/entry/src/main/ets/pages/AdminSettingsPage.ets`
- Uses: `BookUploadService.pickStagedFile`（Task 1）、`TalebookApi.getStampStatus` / `uploadStamp` / `uploadAdminSsl` / `generateAdminToken` / `applyBookbarnToken`

**Interfaces:**
- Consumes: Task 1 `pickStagedFile`；API 签名见 `TalebookApi.ets` 853–899 行附近
- Produces: 扩展功能卡内印章区；高级卡内 Token/SSL；书栈卡内 Apply 按钮

- [ ] **Step 1: 印章状态与上传**

```typescript
private async refreshStampStatus(): Promise<void> {
  try {
    const rsp = await TalebookApi.getStampStatus();
    this.stampExists = rsp.exists === true;
  } catch (_e) {
    this.stampExists = false;
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
```

在 `cardView` 中，当 `card.title === '扩展功能'` 且已展开时，在 fields 后追加：

```typescript
Text(this.stampExists ? '当前已有图章文件' : '尚未上传图章')
  .fontSize(13)
  .fontColor($r('app.color.text_secondary'));
SecondaryButton({
  label: this.stampBusy ? '上传中…' : '上传图章 PNG',
  compact: true,
  fullWidth: false,
  buttonEnabled: !this.stampBusy,
  onTap: () => { void this.uploadStampImage(); },
});
```

导入：`import { common } from '@kit.AbilityKit';`、`import { BookUploadService } from '../services/BookUploadService';`（若尚未导入）。

- [ ] **Step 2: 生成管理 Token + 复制**

```typescript
import { pasteboard } from '@kit.BasicServicesKit';

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
```

在 `card.title === '高级配置项'` 展开内容末尾追加 Token 预览 +「生成 MCP Token」+「复制」按钮。

- [ ] **Step 3: SSL 双文件上传**

```typescript
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
```

同样挂在「高级配置项」展开区。

- [ ] **Step 4: 书栈 Apply**

```typescript
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
```

挂在 `card.title === '书栈服务'` 展开区。

- [ ] **Step 5: 编译验证**

Run: `powershell -NoProfile -File scripts/build-hap.ps1`  
Expected: `BUILD SUCCESSFUL`。

- [ ] **Step 6: 手动验收（真机/模拟器）**

对照规格 §8 Admin 清单：折叠、保存/重启、印章、SSL、Token、Apply、系统信息。

---

### Task 4: SettingsPage — 分区 + 主题弹窗 + 账号入口

**Files:**
- Modify: `ohos/entry/src/main/ets/pages/SettingsPage.ets`

**Interfaces:**
- Consumes: `AppTheme.themeModeLabel` / `applyThemeMode`；`TalebookService.getSavedUserProfile` / `hasAuthCredentials`；`router.pushUrl`
- Produces: 分区标题「外观 / 账号与服务 / 关于」；主题 `showActionMenu`；个人设置入口

- [ ] **Step 1: 增加登录态状态**

```typescript
@State accountSubtitle: string = 'Talebook 账号登录';
@State isLoggedIn: boolean = false;

private refreshAccount(): void {
  const saved = TalebookService.getSavedUserProfile();
  if (saved !== null && TalebookService.hasAuthCredentials()) {
    const nick = String(saved['nickname'] ?? saved['name'] ?? '');
    const user = String(saved['username'] ?? '');
    this.isLoggedIn = true;
    this.accountSubtitle = nick.length > 0 ? nick : (user.length > 0 ? user : '已登录');
  } else {
    this.isLoggedIn = false;
    this.accountSubtitle = 'Talebook 账号登录';
  }
}
```

在 `aboutToAppear` 调用 `this.refreshAccount()`。

- [ ] **Step 2: 主题选择弹窗**

替换点击循环为：

```typescript
private showThemePicker(): void {
  this.getUIContext().getPromptAction().showActionMenu({
    title: '主题模式',
    buttons: [
      { text: '跟随系统', color: '#007DFF' },
      { text: '浅色', color: '#007DFF' },
      { text: '深色', color: '#007DFF' },
    ],
  }).then((result) => {
    const modes: string[] = ['system', 'light', 'dark'];
    if (result.index >= 0 && result.index < modes.length) {
      this.applyTheme(modes[result.index]);
    }
  }).catch(() => {});
}
```

`SettingCell` 的 `onTap` 改为 `() => this.showThemePicker()`。

- [ ] **Step 3: 重构 build 分区**

结构（保留现有 SettingCell）：

```typescript
Column({ space: 12 }) {
  Text('外观').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%');
  Column() { /* 返回按钮 + 主题 */ }
    .width('100%').borderRadius(...).backgroundColor($r('app.color.card_background'));

  Text('账号与服务').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%');
  Column() {
    SettingCell({
      title: this.isLoggedIn ? '个人设置' : '登录',
      subtitle: this.accountSubtitle,
      showChevron: true,
      onTap: () => {
        if (this.isLoggedIn) {
          router.pushUrl({ url: 'pages/UserSettingsPage' });
        } else {
          router.pushUrl({ url: 'pages/LoginPage' });
        }
      },
    });
    Divider()...
    if (this.isLoggedIn) {
      SettingCell({
        title: '个人中心',
        subtitle: '收藏、消息与账号',
        showChevron: true,
        onTap: () => router.pushUrl({ url: 'pages/ProfilePage' }),
      });
      Divider()...
    }
    // 下载管理 / 附加服务 / SoNovel — 保持现有
  }...

  Text('关于')...
  Column() { SettingCell({ title: '版本', valueText: this.versionText }); }...
}
```

- [ ] **Step 4: 编译验证**

Run: `powershell -NoProfile -File scripts/build-hap.ps1`  
Expected: `BUILD SUCCESSFUL`。

---

### Task 5: UserSettingsPage — VIP + podcast_token + 视觉

**Files:**
- Modify: `ohos/entry/src/main/ets/services/TalebookApi.ets`（`UserUpdatePayload`）
- Modify: `ohos/entry/src/main/ets/pages/UserSettingsPage.ets`

**Interfaces:**
- Consumes: `TalebookApi.getVipInfo()`；Web 对齐：客户端本地生成 64 hex token 后经 `updateUserSettings` 提交
- Produces: `UserUpdatePayload.podcast_token?: string`；页面 VIP 卡与 Token 区

- [ ] **Step 1: 扩展 payload**

在 `TalebookApi.ets`：

```typescript
export interface UserUpdatePayload {
  nickname?: string;
  password0?: string;
  password1?: string;
  password2?: string;
  kindle_email?: string;
  allow_sending_mail?: boolean;
  show_other_annotations?: boolean;
  share_annotations?: boolean;
  show_home_recommendations?: boolean;
  podcast_token?: string;
}
```

若 `VipInfoResponse` 未导出，将其改为 `export interface VipInfoResponse`（或页面侧不标注类型、用局部字段）。

- [ ] **Step 2: UserSettings 状态与加载**

```typescript
@State podcastToken: string = '';
@State vipSummary: string = '';

// loadProfile 中：
this.podcastToken = String(saved['podcast_token'] ?? '');

// loadProfile finally 前：
void this.refreshVip();

private async refreshVip(): Promise<void> {
  try {
    const rsp = await TalebookApi.getVipInfo();
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      this.vipSummary = '';
      return;
    }
    const quota = rsp.vipquota !== undefined ? String(rsp.vipquota) : '-';
    const expire = rsp.vip_expire !== undefined && rsp.vip_expire.length > 0 ? rsp.vip_expire : '无';
    this.vipSummary = `配额 ${quota} · 到期 ${expire}`;
  } catch (_e) {
    this.vipSummary = '';
  }
}
```

- [ ] **Step 3: 生成 / 复制 token（对齐 Web）**

```typescript
import { util } from '@kit.ArkTS';
import { pasteboard } from '@kit.BasicServicesKit';

private generatePodcastToken(): void {
  // 32 bytes → 64 hex；无 crypto.getRandomValues 时用 util.generateRandomUUID 拼接退化亦可，优先：
  const buf = new Uint8Array(32);
  // @ohos.security.cryptoFramework 或 util — 若项目已有随机源则复用；否则：
  let hex = '';
  for (let i = 0; i < 32; i++) {
    const b = Math.floor(Math.random() * 256);
    const h = b.toString(16);
    hex += h.length < 2 ? `0${h}` : h;
  }
  this.podcastToken = hex;
  this.toast('已生成新 Token，请保存设置后生效');
}

private copyPodcastToken(): void {
  if (this.podcastToken.length === 0) {
    this.toast('暂无 Token');
    return;
  }
  const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.podcastToken);
  pasteboard.getSystemPasteboard().setData(data);
  this.toast('已复制');
}
```

`save()` 中：`payload.podcast_token = this.podcastToken.trim();`

- [ ] **Step 4: UI 区块**

在偏好开关卡之后、「修改密码」之前插入：

```typescript
Column({ space: 8 }) {
  SectionTitle({ title: '会员与订阅' });
  if (this.vipSummary.length > 0) {
    Text(this.vipSummary)
      .fontSize(14)
      .fontColor($r('app.color.text_primary'));
  } else {
    Text('VIP 信息暂不可用')
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'));
  }
  Text('Podcast Token')
    .fontSize(13)
    .fontColor($r('app.color.text_secondary'));
  Text(this.podcastToken.length > 0 ? this.podcastToken : '未设置')
    .fontSize(12)
    .fontColor($r('app.color.text_primary'));
  Row({ space: 8 }) {
    SecondaryButton({
      label: '重新生成',
      compact: true,
      fullWidth: false,
      onTap: () => this.generatePodcastToken(),
    });
    SecondaryButton({
      label: '复制',
      compact: true,
      fullWidth: false,
      onTap: () => this.copyPodcastToken(),
    });
  }
}
.width('100%')
.padding($r('app.float.card_padding'))
.borderRadius($r('app.float.card_radius'))
.backgroundColor($r('app.color.card_background'))
.alignItems(HorizontalAlign.Start);
```

统一基本资料卡内输入框高度/间距与现有 `SectionTitle` 一致（微调 padding，不改业务校验）。

- [ ] **Step 5: 全量编译**

Run: `powershell -NoProfile -File scripts/build-hap.ps1`  
Expected: `BUILD SUCCESSFUL`。

- [ ] **Step 6: 对照规格 §8 全清单做一次手动点检**

---

## Spec coverage check

| Spec 项 | Task |
|---------|------|
| Admin 折叠 + 底栏 | Task 2（底栏已存在，保留） |
| getSysInfo | Task 2 |
| 印章状态/上传 | Task 3 |
| SSL / Token / Bookbarn Apply | Task 3 |
| Settings 分区 / 主题弹窗 / 账号入口 | Task 4 |
| User VIP / podcast_token / 视觉 | Task 5 |
| 选文件复用 | Task 1 |
| 编译通过 | Task 2/3/4/5 |
| 不做 Profile/阅读范围/Thanks | 全计划未纳入 |

## Placeholder / type notes

- `SysInfoResponse.data` 字段名因服务端版本可能不同，Task 2 已含 fallback 取前 4 键。
- Podcast token 随机：优先可用平台安全随机；`Math.random` 仅作无 crypto API 时的降级（与 Web `crypto.getRandomValues` 不完全等价，实现时若项目已有 `cryptoFramework` 随机字节 API 则改用该 API）。
- 剪贴板 API：`pasteboard.createData` / `getSystemPasteboard().setData`；若编译报 API 变更，按当前 SDK 文档微调，勿改业务流。

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-09-06-settings-ui.md`.

**Two execution options:**

1. **Subagent-Driven（推荐）** — 每任务派生子代理，任务间评审  
2. **Inline Execution** — 本会话按 `executing-plans` 连续执行并设检查点  

Which approach?
