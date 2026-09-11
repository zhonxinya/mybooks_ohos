# Settings UI 完善设计

> 日期：2026-09-06  
> 状态：待用户审阅  
> 范围：`SettingsPage` + `UserSettingsPage` + `AdminSettingsPage`  
> 优先级：**3+1**（先 Admin 补齐，再主 Tab 设置 + 个人设置）  
> Admin 完成度：**A 档**（保留现有表单 + 补齐缺失动作 + 视觉整理）

## 1. 背景与目标

鸿蒙端三处「设置」已能完成基本读写，但存在两类问题：

1. **不够美观**：主 Tab 无分区标题；主题靠点击循环；Admin 长表单一屏堆叠难扫读。
2. **功能不全**：Admin 印章/SSL/Token/书栈 Apply/系统信息等 API 已封装未接线；Settings 缺个人设置入口与登录态展示；UserSettings 缺 VIP / podcast_token。

成功标准：

- 管理员在手机上能完成站点配置保存/重启，并能执行印章上传、SSL 上传、生成管理 Token、书栈 Apply、查看系统信息摘要。
- 普通用户从主 Tab「设置」能清晰进入登录/个人设置，主题三选一，个人设置可看 VIP 与 podcast_token。
- 视觉统一复用现有 `SettingCell` / `SectionTitle` / `PageScaffold` / 按钮组件，不新建设计系统。

## 2. 非目标

- 不重做 `ProfilePage`（仅从 Settings 链入）。
- 不追求与 Web Admin 像素级对齐。
- 不做阅读范围详情配置（继续提示网页端）。
- 不引入新建设置壳组件库（方案②）或把 Admin 拆成多路由页（方案③）。
- 不提交无关重构。

## 3. 实现策略

采用**就地增强**：

| 顺序 | 页面 | 内容 |
|------|------|------|
| 1 | `AdminSettingsPage` | 折叠卡片 + 底部操作条 + 缺失动作接线 |
| 2 | `SettingsPage` | 分区、主题弹窗、账号区、个人设置入口 |
| 3 | `UserSettingsPage` | VIP 卡、podcast_token、表单视觉统一 |

## 4. AdminSettingsPage

### 4.1 视觉

- 每张配置卡：标题行可点击展开/折叠（默认折叠，或「基础信息」默认展开）。
- 展开态内保持现有字段渲染（text / number / textarea / bool / select / groups）。
- 页底固定操作条：`保存设置`（主按钮）+ `重启服务`（危险/次要），避免滚到底才发现。
- 加载失败继续 `EmptyState`；加载中 `LoadingState`。

### 4.2 补齐动作（API 已在 `TalebookApi`）

| 区域 | 能力 | API |
|------|------|-----|
| 页头/关于区 | 系统信息摘要（版本、平台等关键字段） | `getSysInfo` |
| 扩展功能 | 印章启用/位置旁：状态展示 + 选图上传 | `getStampStatus` / `uploadStamp` |
| 高级配置 | 生成管理 Token（展示/复制） | `generateAdminToken` |
| 高级配置 | SSL 证书上传（选文件） | `uploadAdminSsl` |
| 书栈服务 | 一键 Apply Token | `applyBookbarnToken` |

### 4.3 明确不做（本迭代）

- `getThanksNotes` 全文展示。
- 阅读范围详细规则编辑。
- 社交登录/友情链接的复杂表格高级编辑（现有列表编辑能力保留即可）。

## 5. SettingsPage（主 Tab）

### 5.1 信息架构

```
外观
  - 显示返回按钮（开关）
  - 主题模式 → 弹窗三选：跟随系统 / 浅色 / 深色

账号与服务
  - 未登录：登录
  - 已登录：账号摘要（昵称/用户名）→ 个人设置；个人中心（可选）
  - 附加服务（未读徽标）
  - 下载管理（任务徽标）
  - SoNovel 搜索（快捷入口，与现网一致）

关于
  - 版本号
```

### 5.2 行为

- 主题：`ActionSheet` / `AlertDialog` 显式选择，写入 `StorageKeys.THEME_MODE` 并 `AppTheme.applyThemeMode`。
- 登录态：`TalebookService.getSavedUserProfile()` / `hasAuthCredentials()`；进入页时轻量刷新。
- 「个人设置」→ `pages/UserSettingsPage`；需登录，未登录则先跳转登录页。

## 6. UserSettingsPage

### 6.1 增强

- **VIP 信息卡**：调用 `getVipInfo`，展示配额与到期；失败时静默或短提示，不阻断其它表单。
- **podcast_token**：扩展 `UserUpdatePayload`（及保存逻辑）；UI 展示现有 token（若 profile/extra 中有），支持复制；若服务端支持更新则允许编辑后随「保存设置」提交。
- **视觉**：基本资料 / 偏好开关 / 密码 / VIP / Token 分区统一卡片内边距与 `SectionTitle`；保存按钮样式与 Admin 底部主操作一致（可滚动底部，不必 sticky）。

### 6.2 保持

- 头像上传、昵称、Kindle、四个偏好开关、改密校验逻辑不变（可顺手修明显 UX 毛刺，不改业务语义）。

## 7. 组件与文件

| 文件 | 变更 |
|------|------|
| `ohos/.../pages/AdminSettingsPage.ets` | 折叠态、动作区、底部栏 |
| `ohos/.../pages/SettingsPage.ets` | 分区、主题弹窗、账号入口 |
| `ohos/.../pages/UserSettingsPage.ets` | VIP、token、视觉 |
| `ohos/.../services/TalebookApi.ets` | `UserUpdatePayload.podcast_token?`；必要时导出 `VipInfoResponse` |
| 可选小改 | `BookUploadService` 复用选图/选文件；无新模块 |

复用：`SettingCell`、`SectionTitle`、`PageScaffold`、`HarmonyTopBar`、`PrimaryButton` / `SecondaryButton` / `DangerButton`、`AuthImage`、`LoadingState` / `EmptyState`。

## 8. 验收清单

### Admin

- [ ] 卡片可折叠；保存/重启可用且与现网一致  
- [ ] 印章：能看状态、能选图上传并 toast 结果  
- [ ] SSL：能选文件上传  
- [ ] 生成 Token：展示结果并可复制  
- [ ] 书栈 Apply：有确认/结果 toast  
- [ ] 系统信息摘要可见  

### Settings

- [ ] 三区标题清晰  
- [ ] 主题三选一生效且持久化  
- [ ] 已登录可进个人设置；未登录引导登录  

### UserSettings

- [ ] VIP 有展示路径  
- [ ] podcast_token 可见/可复制（及按 API 可保存）  
- [ ] 原有保存/头像流程仍可用  

### 回归

- [ ] `scripts/build-hap.ps1` 编译通过  

## 9. 风险与假设

- **假设**：`podcast_token` 存在于用户 profile/extra 或 update API；若服务端只读，则 UI 仅展示不提交。实现前对照 Web `/user/detail` 与 `UserUpdate` handler。
- **假设**：SSL 上传需要证书+密钥路径参数，与现有 `uploadAdminSsl` 签名对齐；若需双文件，UI 提供两步选择。
- **风险**：Admin 页已很大，折叠 + 动作区会继续增行；避免再抽抽象层，优先局部 Builder。
- **风险**：移动端选文件权限/沙箱路径需沿用 `BookUploadService` 既有模式。

## 10. 后续（本规格外）

- Profile 页头像/统计对齐 Flutter 历史能力。
- Thanks Notes、阅读范围详情。
- Admin 卡片引擎拆分（若后续维护成本过高再议）。
