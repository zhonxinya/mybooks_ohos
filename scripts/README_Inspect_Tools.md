# 鸿蒙页面分析工具使用指南

## 📋 概述

本工具集提供两个 PowerShell 脚本,用于通过 HDC (HarmonyOS Device Connector) 命令分析和检查鸿蒙应用的页面结构。

### 工具列表

1. **inspect-page.ps1** - 完整页面分析工具
   - 获取完整的组件树结构
   - 支持输出到文件
   - 包含 UI 层级、窗口信息、无障碍节点
   
2. **quick-inspect.ps1** - 快速检查工具
   - 快速获取关键组件统计
   - 支持按组件类型过滤
   - 适合日常调试使用

---

## 🚀 快速开始

### 前置条件

1. **安装 DevEco Studio** 或单独安装 HDC 工具
2. **连接设备** 并开启 USB 调试
3. **验证 HDC**: 在终端运行 `hdc version`

### 基本用法

```powershell
# 进入项目 scripts 目录
cd c:\Apps\TalebookReader\scripts

# 方法1: 快速检查当前页面
.\quick-inspect.ps1

# 方法2: 完整分析并保存到文件
.\inspect-page.ps1 -OutputFile page-analysis.json

# 方法3: 查看帮助
.\inspect-page.ps1 -Help
```

---

## 📖 详细使用说明

### 1. inspect-page.ps1 (完整分析)

#### 参数说明

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-BundleName` | string | com.example.talebookreader | 应用包名 |
| `-OutputFile` | string | (空) | 输出文件路径 |
| `-Help` | switch | false | 显示帮助信息 |

#### 使用示例

```powershell
# 分析当前前台应用
.\inspect-page.ps1

# 指定应用包名
.\inspect-page.ps1 -BundleName com.huawei.hmos.settings

# 输出到 JSON 文件
.\inspect-page.ps1 -OutputFile C:\temp\page-structure.json

# 组合使用
.\inspect-page.ps1 -BundleName com.example.app -OutputFile analysis.json
```

#### 输出内容

脚本会收集以下信息:

- **UI 层级结构**: 通过 `hidumper -s RenderService -a screen` 获取
- **窗口信息**: 通过 `dumpsys window` 获取
- **无障碍节点**: 通过 `dumpsys accessibility` 获取(如果可用)
- **元数据**: 时间戳、设备信息、应用包名

---

### 2. quick-inspect.ps1 (快速检查)

#### 参数说明

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-ComponentType` | string | (空) | 过滤特定组件类型 |
| `-ShowAll` | switch | false | 显示完整 UI 层级 |

#### 使用示例

```powershell
# 快速统计所有组件
.\quick-inspect.ps1

# 只查看 Text 组件
.\quick-inspect.ps1 -ComponentType Text

# 查看 Button 组件详情
.\quick-inspect.ps1 -ComponentType Button

# 显示前100行完整 UI 树
.\quick-inspect.ps1 -ShowAll

# 组合使用
.\quick-inspect.ps1 -ComponentType Image -ShowAll
```

#### 输出内容

- **组件统计**: Text、Button、Image、Column、Row 等常见组件数量
- **组件详情**: 如果指定了 `-ComponentType`,显示匹配组件的详细信息
- **窗口摘要**: 焦点窗口和窗口总数
- **快捷命令**: 常用的 HDC 调试命令参考

---

## 🔍 解读输出结果

### UI 层级信息示例

```
RenderService Screen Info:
  Window[0]:
    Component: Column
      bounds: [0, 0, 1080, 2400]
      children:
        - Component: Row
            bounds: [0, 0, 1080, 120]
            children:
              - Component: Text
                  text: "标题"
                  bounds: [20, 40, 200, 80]
              - Component: Button
                  text: "搜索"
                  bounds: [900, 40, 1060, 80]
        - Component: List
            bounds: [0, 120, 1080, 2280]
            children:
              - Component: ListItem
                  ...
```

### 关键字段说明

- **Component**: 组件类型 (Text, Button, Column, Row, etc.)
- **bounds**: 组件位置和尺寸 [left, top, right, bottom]
- **text**: 文本内容 (Text/Button 组件)
- **children**: 子组件列表
- **Window**: 窗口层级,每个窗口包含一个组件树

### 如何定位问题

#### 场景1: 布局异常

```powershell
# 检查组件的实际位置和尺寸
.\inspect-page.ps1 -OutputFile layout-check.json

# 在输出文件中搜索特定组件的 bounds
# 对比预期位置和实际位置
```

#### 场景2: 组件未显示

```powershell
# 检查组件是否存在于树中
.\quick-inspect.ps1 -ComponentType Button

# 如果数量为0,说明组件未渲染
# 检查是否有条件渲染逻辑阻止了组件显示
```

#### 场景3: 点击无响应

```powershell
# 检查组件是否可交互
.\inspect-page.ps1 -OutputFile interaction-check.json

# 查看组件的 enabled、clickable 等属性
# 确认组件是否在可见区域内 (bounds)
```

---

## 💡 实用技巧

### 1. 对比不同状态

```powershell
# 保存初始状态
.\inspect-page.ps1 -OutputFile state-before.json

# 执行某个操作后...

# 保存操作后状态
.\inspect-page.ps1 -OutputFile state-after.json

# 使用 diff 工具对比两个文件
```

### 2. 监控页面变化

```powershell
# 创建循环监控脚本
for ($i = 1; $i -le 5; $i++) {
    Write-Host "=== 第 $i 次检查 ==="
    .\quick-inspect.ps1
    Start-Sleep -Seconds 2
}
```

### 3. 提取特定信息

```powershell
# 从完整输出中提取 Text 组件
$content = Get-Content page-analysis.json -Raw
$textComponents = $content | Select-String -Pattern '"text":\s*"[^"]+"' -AllMatches
$textComponents.Matches | ForEach-Object { Write-Host $_.Value }
```

### 4. 结合截图分析

```powershell
# 先截图
hdc shell screencap /data/local/tmp/screen.png
hdc file recv /data/local/tmp/screen.png ./screenshot.png

# 再获取结构
.\inspect-page.ps1 -OutputFile structure.json

# 对比截图和结构,定位视觉问题
```

---

## 🛠️ 故障排查

### 问题1: HDC 命令不可用

**症状**: `hdc : 无法将"hdc"项识别为 cmdlet、函数、脚本文件或可运行程序的名称`

**解决**:
```powershell
# 方法1: 添加 HDC 到 PATH
$env:Path += ";C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains"

# 方法2: 设置 HDC_HOME 环境变量
[System.Environment]::SetEnvironmentVariable("HDC_HOME", "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains", "User")

# 方法3: 使用完整路径
& "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" version
```

### 问题2: 未检测到设备

**症状**: `[✗] 错误: 未检测到连接的设备`

**解决**:
```powershell
# 1. 检查 USB 连接
hdc list targets

# 2. 重启 HDC 服务
hdc kill
hdc start

# 3. 检查设备开发者选项
# - 开启"USB 调试"
# - 开启"仅充电模式下允许 ADB 调试"

# 4. 重新授权设备
hdc target connect <device-id>
```

### 问题3: 无法获取 UI 信息

**症状**: `[✗] 错误: 未能获取 UI 层级信息`

**解决**:
```powershell
# 1. 确保应用在前台运行
hdc shell aa start -a EntryAbility -b com.example.app

# 2. 等待应用完全加载
Start-Sleep -Seconds 3

# 3. 尝试手动执行命令
hdc shell hidumper -s RenderService -a screen

# 4. 检查权限
# 某些系统版本可能需要额外权限
```

### 问题4: 输出乱码

**解决**:
```powershell
# 设置控制台编码为 UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 或在脚本开头添加
$OutputEncoding = [System.Text.Encoding]::UTF8
```

---

## 📚 相关资源

### 官方文档

- [HDC 命令参考](https://developer.harmonyos.com/cn/docs/documentation/doc-references-V3/hdc-command-reference-0000001774120425-V3)
- [DevEco Studio Inspector](https://developer.harmonyos.com/cn/docs/documentation/doc-guides-V3/ide-inspector-0000001774280469-V3)
- [UI 调试指南](https://developer.harmonyos.com/cn/docs/documentation/doc-guides-V3/ui-debugging-0000001774280473-V3)

### 常用 HDC 命令

```bash
# 设备管理
hdc list targets                    # 列出设备
hdc target connect <id>             # 连接设备
hdc kill && hdc start               # 重启服务

# 应用管理
hdc shell aa start -a <ability> -b <bundle>  # 启动应用
hdc shell aa force-stop <bundle>             # 停止应用

# 文件传输
hdc file send <local> <remote>      # 发送文件
hdc file recv <remote> <local>      # 接收文件

# 屏幕截图
hdc shell screencap /data/local/tmp/screen.png
hdc file recv /data/local/tmp/screen.png ./screen.png

# UI 调试
hdc shell hidumper -s RenderService -a screen  # UI 层级
hdc shell dumpsys window                       # 窗口信息
hdc shell dumpsys ability ams                  # 应用信息
```

---

## 🎯 最佳实践

1. **定期清理临时文件**: 分析生成的 JSON 文件可能较大,及时清理
2. **结合 DevEco Inspector**: 脚本适合自动化,IDE 可视化工具更直观
3. **建立基准线**: 保存正常状态的输出作为对比基准
4. **自动化集成**: 可将脚本集成到 CI/CD 流程中进行 UI 回归测试
5. **团队协作**: 分享分析结果时使用标准化格式 (JSON)

---

## 📝 更新日志

### v1.0.0 (2026-04-23)
- ✨ 初始版本发布
- ✨ 实现完整页面分析工具 (inspect-page.ps1)
- ✨ 实现快速检查工具 (quick-inspect.ps1)
- ✨ 支持组件统计和过滤
- ✨ 支持输出到文件
- ✨ 完善的错误处理和提示信息
