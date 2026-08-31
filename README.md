<img src="KaitoIcon.png" alt="Kaito 应用图标" width="128" height="128">

# Kaito

Kaito 是一款使用 SwiftUI 与 PDFKit 构建的 Apple 平台 PDF 学习工作台，面向阅读、刷题、批注与复习场景。它将 PDF 阅读器、可保存的答题卡和本地 AI 助手整合在同一个界面中，并支持 macOS 与 iPadOS。

> 项目仍在开发中，界面、数据格式与功能可能发生变化。

## 功能特性

- **PDF 阅读**：打开本地 PDF，翻页、缩放、锁定缩放比例，并支持双页显示。
- **答题卡**：在 PDF 页面上建立题目标记，记录选项、正确答案与答题状态。
- **复习模式**：按答题结果筛选题目，查看作答情况与汇总信息。
- **PDF 批注**：支持手写/绘制与文字批注，可调整笔画宽度、颜色、字体及文字样式。
- **保存与恢复**：可保存原 PDF 或导出副本；应用也会在必要时保留恢复快照，降低未保存内容丢失的风险。
- **本地 AI 助手**：自动发现本机 Ollama 服务与已安装模型，通过流式响应辅助理解 PDF 和其他文件内容。
- **多模态上下文**：可选取 PDF 页面，并附加图片、纯文本或 JSON 文件；视觉模型可直接理解页面与图片。
- **会话历史**：使用 SwiftData 在本地保存 AI 对话、消息、模型信息与更新时间。
- **Markdown 展示**：AI 回复支持标题、列表、代码块及常用行内 Markdown。
- **多语言界面**：支持简体中文、繁体中文、日语和英语。
- **原生体验**：针对 macOS 与 iOS 分别适配窗口、工具栏、文件访问和输入交互。

## 技术栈

- Swift / SwiftUI
- PDFKit
- SwiftData
- Observation
- PencilKit（iOS 绘制交互）
- Ollama HTTP API
- Xcode String Catalog

项目不依赖云端 AI 服务。AI 请求发送至本机 Ollama，PDF 与会话数据的处理以本地为主。

## 运行要求

- macOS 或 iOS 设备/模拟器
- 能够构建当前工程的 Xcode 版本
- 如需使用 AI 功能：已安装并正在运行的 [Ollama](https://ollama.com/)，以及至少一个本地模型
- 如需让 AI 识别 PDF 页面或图片：建议安装带有 `vision` 能力的视觉语言模型

## 快速开始

1. 克隆仓库：

   ```bash
   git clone <repository-url>
   cd PtE
   ```

2. 使用 Xcode 打开 `PtE.xcodeproj`。
3. 选择 `PtE` Scheme 和目标设备，然后构建并运行。
4. 在欢迎界面打开一个 PDF，即可开始阅读、批注或建立答题卡。

### 启用本地 AI

1. 安装并启动 Ollama。
2. 拉取所需模型，例如：

   ```bash
   ollama pull <model-name>
   ```

3. 启动 Kaito。应用会自动扫描 `localhost` / `127.0.0.1` 上 Ollama 的默认端口及相邻端口，并列出可用模型。
4. 打开 AI 面板，选择模型后即可开始对话。

每次发送最多可组合 5 个 PDF 页面或文件附件。未报告视觉能力的模型仍可处理文本附件，但不一定能够识别 PDF 页面与图片。

## 使用说明

### 答题与复习

在 PDF 中添加题目标记后，可以在侧边答题卡记录选项和正确答案。题目信息会随 PDF 保存，重新打开文档后可继续作答或进入复习模式。

### 批注与保存

批注会写入 PDF。编辑完成后可覆盖保存原文件，或使用“保存为副本”保留原始文档。关闭窗口、切换文件或切换语言前，建议先确认修改已经保存。

### 隐私

Kaito 的 AI 功能连接本机 Ollama，不要求将文档发送到项目维护者运营的服务器。实际数据处理方式仍取决于你安装的模型、Ollama 配置及本机网络环境。

## 项目结构

```text
PtE/
├── AIChatView.swift          # Ollama、AI 会话、附件与 Markdown 界面
├── ContentView.swift         # PDF 阅读、答题、复习、批注与跨平台界面
├── KaitoApp.swift            # 应用入口、SwiftData 与语言设置
├── Localizable.xcstrings     # 界面本地化
├── Assets.xcassets           # 应用资源
├── Kaito.png                 # Kaito 人物立绘
└── QKaito.png                # Kaito 人物立绘变体
```

## 参与贡献

欢迎提交 Issue 和 Pull Request。提交代码前，请确保工程能够在 Xcode 中成功构建，并尽量保持现有 SwiftUI 架构、命名方式和跨平台兼容性。

贡献者提交代码即表示其有权提供相关内容，并同意该代码按本项目的 GPL-3.0 许可证发布。请勿提交来源不明或许可证不兼容的代码、图片、字体及其他素材。

## 许可证

本仓库采用双许可证策略：

- **源代码**：除另有说明外，以 **GNU General Public License v3.0 only（GPL-3.0-only）** 发布。你可以使用、研究、修改和再分发代码；分发修改版本时须遵守 GPL-3.0 的相应条款，并以相同许可证提供源代码。
- **Kaito 人物立绘**：`PtE/Kaito.png` 与 `PtE/QKaito.png` 以 **Creative Commons Attribution-ShareAlike 4.0 International（CC BY-SA 4.0）** 发布。使用或改编时须进行适当署名、注明许可证及修改情况，并以相同许可证分享演绎作品。
- **第三方内容**：第三方商标、框架、模型及其他材料仍遵循各自的许可证或使用条款，不因收录或兼容本项目而改用上述许可证。

## 名称与素材

Kaito（海户）是配合软件的角色。项目名称、角色名称和人物立绘的授权范围并不自动扩展到第三方商标用途；使用立绘时请遵守上方 CC BY-SA 4.0 条款并保留作者署名。
