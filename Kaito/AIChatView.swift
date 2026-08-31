import Observation
import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

@Model
final class AIConversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var modelName: String
    @Relationship(deleteRule: .cascade) var messages: [AIMessage]

    init(
        id: UUID = UUID(),
        title: String = "新对话",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        modelName: String = "",
        messages: [AIMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelName = modelName
        self.messages = messages
    }
}

@Model
final class AIMessage {
    @Attribute(.unique) var id: UUID
    var role: String
    var content: String
    var createdAt: Date

    init(id: UUID = UUID(), role: String, content: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

nonisolated private struct OllamaTagsResponse: Decodable {
    let models: [OllamaModel]
}

nonisolated struct OllamaModel: Decodable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let capabilities: [String]?

    var isVisionModel: Bool {
        if capabilities?.contains(where: { $0.lowercased() == "vision" }) == true { return true }
        let normalized = name.lowercased()
        return normalized.contains("vl")
            || normalized.contains("vision")
            || normalized.contains("llava")
            || normalized.contains("minicpm-v")
    }
}

nonisolated private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaRequestMessage]
    let stream: Bool
}

nonisolated private struct OllamaRequestMessage: Encodable {
    let role: String
    let content: String
    let images: [String]?
}

private let kaitoSystemPrompt = """
你是帮助用户阅读、理解 PDF 与文件内容的学习陪伴助手，名字叫海户（Kaito）。
回答必须准确、严谨、知识充分，并优先直接解决用户的问题。默认保持冷静、自然、简洁的语气：先给结论或关键解释，再补充必要依据和步骤。避免奉承用户、刻意讨好、重复寒暄、无意义总结以及频繁使用语气词、感叹号和可爱表达。不要为了显得亲切而增加与问题无关的内容。只有在不影响信息密度且场景合适时，才使用少量自然幽默。涉及不确定信息时明确说明不确定性，不要编造。
使用清晰的 Markdown 组织较长回答，段落之间留出空行；列表、公式和代码应保持易读。简单问题应简短回答，复杂问题再分层展开。
回答结束时可以视情境用一句简短、具体的问题或下一步建议与用户互动，但不要强行追问，也不要重复已经说过的内容。
"""

private struct AIPendingAttachment: Identifiable, Equatable {
    enum Kind { case image, text }
    let id = UUID()
    let name: String
    let kind: Kind
    let data: Data
}

nonisolated private struct OllamaChatChunk: Decodable {
    let message: OllamaChatDelta?
    let done: Bool
}

nonisolated private struct OllamaChatDelta: Decodable {
    let content: String
}

private enum AIChatError: LocalizedError {
    case serviceUnavailable
    case serverStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            "AI 服务当前不可用。"
        case .serverStatus(let status):
            "AI 服务返回了 HTTP \(status)。"
        case .emptyResponse:
            "AI 没有返回内容。"
        }
    }
}

enum AIServiceDiscovery {
    static let cachedEndpointKey = "ollamaDiscoveredEndpoint"
    static let cachedModelKey = "ollamaDiscoveredModel"

    static func scan() async -> (endpoint: URL, models: [OllamaModel])? {
        let defaults = UserDefaults.standard
        var ports = [11434]
        if let cached = defaults.string(forKey: cachedEndpointKey),
           let url = URL(string: cached),
           let port = url.port,
           port != 11434 {
            ports.insert(port, at: 0)
        }
        ports.append(contentsOf: 11435...11444)

        return await withTaskGroup(of: (URL, [OllamaModel])?.self) { group in
            for host in ["127.0.0.1", "localhost"] {
                for port in Array(Set(ports)) {
                    group.addTask {
                    let endpoint = URL(string: "http://\(host):\(port)")!
                    var request = URLRequest(url: endpoint.appending(path: "api/tags"))
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.timeoutInterval = 3
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200,
                          let tags = try? JSONDecoder().decode(OllamaTagsResponse.self, from: data) else {
                        return nil
                    }
                    return (endpoint, tags.models)
                    }
                }
            }

            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    static func scanAndCache() async {
        guard let discovery = await scan() else { return }
        let defaults = UserDefaults.standard
        defaults.set(discovery.endpoint.absoluteString, forKey: cachedEndpointKey)
        if let cachedModel = defaults.string(forKey: cachedModelKey),
           discovery.models.contains(where: { $0.name == cachedModel }) {
            return
        }
        defaults.set(discovery.models.first?.name, forKey: cachedModelKey)
    }
}

@MainActor
@Observable
private final class AIChatState {
    enum ServiceStatus: Equatable {
        case scanning
        case unavailable
        case available(endpoint: URL, models: [OllamaModel])
    }

    var serviceStatus: ServiceStatus = .scanning
    var selectedModel = ""
    var draft = ""
    var isSending = false
    var errorMessage: String?
    private(set) var generationTask: Task<Void, Never>?

    var selectedModelSupportsVision: Bool {
        guard case .available(_, let models) = serviceStatus else { return false }
        return models.first(where: { $0.name == selectedModel })?.isVisionModel ?? false
    }

    func scan() async {
        serviceStatus = .scanning
        errorMessage = nil
        guard let discovery = await AIServiceDiscovery.scan() else {
            serviceStatus = .unavailable
            return
        }

        let defaults = UserDefaults.standard
        let cachedModel = defaults.string(forKey: AIServiceDiscovery.cachedModelKey)
        selectedModel = cachedModel.flatMap { cached in
            discovery.models.contains(where: { $0.name == cached }) ? cached : nil
        }
            ?? discovery.models.first?.name
            ?? ""
        defaults.set(discovery.endpoint.absoluteString, forKey: AIServiceDiscovery.cachedEndpointKey)
        defaults.set(selectedModel, forKey: AIServiceDiscovery.cachedModelKey)
        serviceStatus = .available(endpoint: discovery.endpoint, models: discovery.models)
    }

    func selectModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: AIServiceDiscovery.cachedModelKey)
    }

    func setGenerationTask(_ task: Task<Void, Never>) {
        generationTask = task
    }

    func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
    }

    func finishGeneration() {
        generationTask = nil
    }
}

struct AIChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AIConversation.updatedAt, order: .reverse) private var conversations: [AIConversation]
    @State private var state = AIChatState()
    @State private var activeConversationID: UUID?
    @Binding private var showsHistory: Bool
    let document: PDFDocument
    @Binding private var selectedPageIndices: [Int]
    @Binding private var isSelectingPages: Bool
    @Binding private var maximumSelectedPages: Int
    @State private var attachments: [AIPendingAttachment] = []
    @State private var showsFileImporter = false
    @State private var showsVisionWarning = false
    @FocusState private var isPromptFocused: Bool

    init(
        showsHistory: Binding<Bool>,
        document: PDFDocument,
        selectedPageIndices: Binding<[Int]>,
        isSelectingPages: Binding<Bool>,
        maximumSelectedPages: Binding<Int>
    ) {
        _showsHistory = showsHistory
        self.document = document
        _selectedPageIndices = selectedPageIndices
        _isSelectingPages = isSelectingPages
        _maximumSelectedPages = maximumSelectedPages
    }

    var body: some View {
        VStack(spacing: 0) {
            AIChatHeader(
                status: state.serviceStatus,
                selectedModel: state.selectedModel,
                showsHistory: $showsHistory,
                selectModel: state.selectModel,
                newConversation: startNewConversation
            )
            Divider().padding(.horizontal, 16)

            switch state.serviceStatus {
            case .scanning:
                ProgressView("正在查找 AI 服务…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                AIServiceUnavailableView(configure: configureService)
            case .available(let endpoint, _):
                if showsHistory {
                    AIHistoryView(
                        conversations: conversations,
                        open: openConversation,
                        delete: deleteConversation
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    VStack(spacing: 0) {
                        AIConversationView(
                            messages: activeConversation?.messages.sorted { $0.createdAt < $1.createdAt } ?? [],
                            errorMessage: state.errorMessage,
                            showsMascot: activeConversation?.messages.isEmpty ?? true
                        )
                        Divider().padding(.horizontal, 16)
                        AIAttachmentStrip(
                            pageIndices: selectedPageIndices,
                            attachments: attachments,
                            removePage: removePage,
                            removeAttachment: removeAttachment
                        )
                        AIComposerView(
                            draft: $state.draft,
                            isSending: state.isSending,
                            isSelectingPages: isSelectingPages,
                            attachmentCount: selectedPageIndices.count + attachments.count,
                            isFocused: $isPromptFocused,
                            selectPages: requestPageSelection,
                            upload: requestUpload,
                            stop: state.stopGeneration,
                            submit: { submit(endpoint: endpoint) }
                        )
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.snappy(duration: 0.32), value: showsHistory)
        .animation(.snappy(duration: 0.32), value: activeConversationID)
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.image, .plainText, .json],
            allowsMultipleSelection: true,
            onCompletion: importAttachments
        )
        .alert("当前模型可能不支持视觉输入", isPresented: $showsVisionWarning) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("当前模型没有报告 vision 能力，PDF 页面和图片附件可能无法被识别。建议切换到 VL 或其他视觉模型。")
        }
        .onChange(of: attachments.count) { _, count in
            maximumSelectedPages = max(0, 5 - count)
            if selectedPageIndices.count > maximumSelectedPages {
                selectedPageIndices = Array(selectedPageIndices.prefix(maximumSelectedPages))
            }
        }
        .task {
            await state.scan()
            if activeConversationID == nil {
                activeConversationID = conversations.first?.id
            }
        }
    }

    private var activeConversation: AIConversation? {
        conversations.first { $0.id == activeConversationID }
    }

    private func startNewConversation() {
        withAnimation(.snappy(duration: 0.32)) {
            activeConversationID = nil
            showsHistory = false
        }
        clearPendingContext()
        state.errorMessage = nil
        state.draft = ""
        isPromptFocused = true
    }

    private func openConversation(_ conversation: AIConversation) {
        withAnimation(.snappy(duration: 0.32)) {
            activeConversationID = conversation.id
            showsHistory = false
        }
    }

    private func deleteConversation(_ conversation: AIConversation) {
        if activeConversationID == conversation.id {
            activeConversationID = nil
        }
        modelContext.delete(conversation)
        try? modelContext.save()
    }

    private func configureService() {
#if os(macOS)
        let ollamaApplication = URL(fileURLWithPath: "/Applications/Ollama.app")
        if FileManager.default.fileExists(atPath: ollamaApplication.path) {
            NSWorkspace.shared.openApplication(
                at: ollamaApplication,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else if let downloadURL = URL(string: "https://ollama.com/download") {
            NSWorkspace.shared.open(downloadURL)
        }
#endif
        Task {
            try? await Task.sleep(for: .seconds(1))
            await state.scan()
        }
    }

    private func submit(endpoint: URL) {
        let prompt = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !state.isSending, !state.selectedModel.isEmpty else { return }

        let conversation = activeConversation ?? createConversation(firstPrompt: prompt)
        let textContext = attachments.compactMap { attachment -> String? in
            guard attachment.kind == .text,
                  let text = String(data: attachment.data, encoding: .utf8) else { return nil }
            return "\n\n[文件：\(attachment.name)]\n\(text)"
        }.joined()
        let pageDescription = selectedPageIndices.isEmpty
            ? ""
            : "\n\n[已附加 PDF 第 \(selectedPageIndices.map { String($0 + 1) }.formatted()) 页]"
        let storedPrompt = prompt + pageDescription + attachments.map { "\n[附件：\($0.name)]" }.joined()
        let userMessage = AIMessage(role: "user", content: storedPrompt)
        conversation.messages.append(userMessage)
        conversation.updatedAt = .now
        conversation.modelName = state.selectedModel
        state.draft = ""
        state.errorMessage = nil
        state.isSending = true
        try? modelContext.save()

        var requestMessages = conversation.messages
            .sorted { $0.createdAt < $1.createdAt }
            .map { OllamaRequestMessage(role: $0.role, content: $0.content, images: nil) }
        let images = selectedPageIndices.compactMap(pageImageBase64)
            + attachments.filter { $0.kind == .image }.map { $0.data.base64EncodedString() }
        if !requestMessages.isEmpty {
            requestMessages[requestMessages.count - 1] = OllamaRequestMessage(
                role: "user",
                content: prompt + textContext + pageDescription,
                images: images.isEmpty ? nil : images
            )
        }
        requestMessages.insert(
            OllamaRequestMessage(role: "system", content: kaitoSystemPrompt, images: nil),
            at: 0
        )
        clearPendingContext()
        let assistantMessage = AIMessage(role: "assistant", content: "")
        conversation.messages.append(assistantMessage)

        let task = Task {
            await streamResponse(
                endpoint: endpoint,
                requestMessages: requestMessages,
                conversation: conversation,
                assistantMessage: assistantMessage
            )
        }
        state.setGenerationTask(task)
    }

    private func togglePageSelection() {
        guard attachments.count + selectedPageIndices.count < 5 || isSelectingPages else { return }
        withAnimation(.snappy(duration: 0.25)) { isSelectingPages.toggle() }
    }

    private func requestPageSelection() {
        if !state.selectedModelSupportsVision { showsVisionWarning = true }
        togglePageSelection()
    }

    private func requestUpload() {
        if !state.selectedModelSupportsVision { showsVisionWarning = true }
        showsFileImporter = true
    }

    private func removePage(_ pageIndex: Int) {
        selectedPageIndices.removeAll { $0 == pageIndex }
    }

    private func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    private func clearPendingContext() {
        selectedPageIndices = []
        attachments = []
        isSelectingPages = false
        maximumSelectedPages = 5
    }

    private func importAttachments(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls.prefix(max(0, 5 - attachments.count - selectedPageIndices.count)) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let kind: AIPendingAttachment.Kind = (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true)
                ? .image
                : .text
            attachments.append(AIPendingAttachment(name: url.lastPathComponent, kind: kind, data: data))
        }
    }

    private func pageImageBase64(_ pageIndex: Int) -> String? {
        guard let page = document.page(at: pageIndex) else { return nil }
        let image = page.thumbnail(of: CGSize(width: 1600, height: 2000), for: .cropBox)
#if os(macOS)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else { return nil }
#else
        guard let data = image.jpegData(compressionQuality: 0.86) else { return nil }
#endif
        return data.base64EncodedString()
    }

    private func createConversation(firstPrompt: String) -> AIConversation {
        let title = String(firstPrompt.prefix(36))
        let conversation = AIConversation(title: title, modelName: state.selectedModel)
        modelContext.insert(conversation)
        activeConversationID = conversation.id
        return conversation
    }

    private func streamResponse(
        endpoint: URL,
        requestMessages: [OllamaRequestMessage],
        conversation: AIConversation,
        assistantMessage: AIMessage
    ) async {
        do {
            var request = URLRequest(url: endpoint.appending(path: "api/chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                OllamaChatRequest(model: state.selectedModel, messages: requestMessages, stream: true)
            )

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw AIChatError.serverStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }

            for try await line in bytes.lines where !line.isEmpty {
                guard let data = line.data(using: .utf8) else { continue }
                let chunk = try JSONDecoder().decode(OllamaChatChunk.self, from: data)
                if let content = chunk.message?.content {
                    assistantMessage.content += content
                }
                if chunk.done { break }
            }
            guard !assistantMessage.content.isEmpty else { throw AIChatError.emptyResponse }
            conversation.updatedAt = .now
            try modelContext.save()
        } catch {
            if error is CancellationError || Task.isCancelled {
                if assistantMessage.content.isEmpty {
                    conversation.messages.removeAll { $0.id == assistantMessage.id }
                    modelContext.delete(assistantMessage)
                } else {
                    assistantMessage.content += "\n\n（已停止生成）"
                }
                try? modelContext.save()
            } else {
                conversation.messages.removeAll { $0.id == assistantMessage.id }
                modelContext.delete(assistantMessage)
                state.errorMessage = error.localizedDescription
                try? modelContext.save()
                if error is URLError {
                    state.serviceStatus = .unavailable
                }
            }
        }
        state.isSending = false
        state.finishGeneration()
        isPromptFocused = true
    }
}

private struct AIChatHeader: View {
    let status: AIChatState.ServiceStatus
    let selectedModel: String
    @Binding var showsHistory: Bool
    let selectModel: (String) -> Void
    let newConversation: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Kaito LM", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            if case .available(_, let models) = status, !models.isEmpty {
                Menu {
                    Picker(
                        "模型",
                        selection: Binding(get: { selectedModel }, set: selectModel)
                    ) {
                        ForEach(models) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                } label: {
                    Label("模型", systemImage: "cpu")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 72)
                .help(selectedModel)
            }
            Button {
                withAnimation(.snappy(duration: 0.32)) { showsHistory.toggle() }
            } label: {
                Image(systemName: showsHistory ? "message" : "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .help(showsHistory ? "返回对话" : "历史记录")
            Button(action: newConversation) {
                Image(systemName: "plus.message")
            }
            .buttonStyle(.plain)
            .help("新对话")
        }
        .padding(16)
    }
}

private struct AIServiceUnavailableView: View {
    let configure: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("AI 服务未启动", systemImage: "exclamationmark.triangle")
        } description: {
            Text("未找到正在运行的 Ollama 服务。启动服务后，AI Chat 会自动查找端口和已安装模型。")
        } actions: {
            Button("配置 AI 服务", action: configure)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AIHistoryView: View {
    let conversations: [AIConversation]
    let open: (AIConversation) -> Void
    let delete: (AIConversation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("对话历史")
                    .font(.title3.weight(.semibold))
                Text("继续之前的讨论，或整理不再需要的记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            if conversations.isEmpty {
                ContentUnavailableView("暂无历史记录", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(conversations) { conversation in
                            AIHistoryCard(
                                title: conversation.title,
                                modelName: conversation.modelName,
                                messageCount: conversation.messages.count,
                                updatedAt: conversation.updatedAt,
                                open: { open(conversation) },
                                delete: { delete(conversation) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

private struct AIHistoryCard: View {
    let title: String
    let modelName: String
    let messageCount: Int
    let updatedAt: Date
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .foregroundStyle(.tint)
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    Label("\(messageCount) 条消息", systemImage: "text.bubble")
                    if !modelName.isEmpty {
                        Label(modelName, systemImage: "cpu")
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(updatedAt, format: .dateTime.month().day().hour().minute())
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(13)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除", role: .destructive, action: delete)
        }
    }
}

private struct AIConversationView: View {
    let messages: [AIMessage]
    let errorMessage: String?
    let showsMascot: Bool
    @State private var showsScrollToBottom = false

    private static let bottomAnchor = "ai-conversation-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.isEmpty {
                        Text("你好呀，我是Kaito！你可以选择PDF页面，上传文件或者直接向我提问。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(messages) { message in
                        AIMessageBubble(role: message.role, content: message.content)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(16)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height > geometry.containerSize.height
                    && geometry.visibleRect.maxY < geometry.contentSize.height - 36
            } action: { _, isAwayFromBottom in
                withAnimation(.easeInOut(duration: 0.18)) {
                    showsScrollToBottom = isAwayFromBottom
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsMascot {
                    BundledPNGImage(resourceName: "QKaito")
                        .scaledToFit()
                        .frame(width: 150, height: 150)
                        .opacity(0.32)
                        .padding(.trailing, 14)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else if showsScrollToBottom {
                    Button {
                        withAnimation(.snappy(duration: 0.3)) {
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.caption.weight(.bold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial, in: Circle())
                    .overlay { Circle().stroke(.quaternary) }
                    .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
                    .padding(12)
                    .help("滚动到最新消息")
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AIMessageBubble: View {
    let role: String
    let content: String

    var body: some View {
        let isUser = role == "user"
        HStack {
            if isUser { Spacer(minLength: 34) }
            Group {
                if isUser {
                    Text(inlineMarkdown(content.isEmpty ? "…" : content))
                } else {
                    AIMarkdownView(content: content.isEmpty ? "…" : content)
                }
            }
                .textSelection(.enabled)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .foregroundStyle(isUser ? .white : .primary)
                .background(
                    isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.thinMaterial),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            if !isUser { Spacer(minLength: 34) }
        }
        .frame(maxWidth: .infinity)
    }

}

private struct AIMarkdownBlock: Identifiable {
    enum Kind {
        case paragraph(String), heading(Int, String), bullet(String)
        case numbered(String, String), quote(String), code(String), formula(String), spacer
    }
    let id: Int
    let kind: Kind
}

private struct AIMarkdownView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(parseMarkdownBlocks(content)) { block in
                AIMarkdownBlockView(kind: block.kind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AIMarkdownBlockView: View {
    let kind: AIMarkdownBlock.Kind

    var body: some View {
        Group {
            switch kind {
            case .paragraph(let text):
                Text(inlineMarkdown(text))
            case .heading(let level, let text):
                Text(inlineMarkdown(text))
                    .font(headingFont(level))
                    .padding(.top, level == 1 ? 4 : 2)
            case .bullet(let text):
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("•").foregroundStyle(.secondary)
                    Text(inlineMarkdown(text))
                }
            case .numbered(let marker, let text):
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(marker).monospacedDigit().foregroundStyle(.secondary)
                    Text(inlineMarkdown(text))
                }
            case .quote(let text):
                Text(inlineMarkdown(text))
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: 3)
                    }
                    .foregroundStyle(.secondary)
            case .code(let text):
                ScrollView(.horizontal) {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .padding(10)
                }
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                .scrollIndicators(.hidden)
            case .formula(let text):
                Text(text)
                    .font(.system(.body, design: .serif).italic())
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            case .spacer:
                Color.clear.frame(height: 3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.bold)
        case 2: .headline.weight(.bold)
        default: .subheadline.weight(.semibold)
        }
    }
}

private func inlineMarkdown(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: inlineMathAsCode(source), options: options)) ?? AttributedString(source)
}

private func inlineMathAsCode(_ source: String) -> String {
    var output = ""
    var formula = ""
    var isInsideFormula = false
    var index = source.startIndex
    while index < source.endIndex {
        let character = source[index]
        if character == "$" {
            let next = source.index(after: index)
            if next < source.endIndex, source[next] == "$" {
                output.append("$$")
                index = source.index(after: next)
                continue
            }
            if isInsideFormula {
                output.append("`\(formula.replacingOccurrences(of: "`", with: "′"))`")
                formula = ""
            }
            isInsideFormula.toggle()
        } else if isInsideFormula {
            formula.append(character)
        } else {
            output.append(character)
        }
        index = source.index(after: index)
    }
    if isInsideFormula { output.append("$\(formula)") }
    return output
}

private func parseMarkdownBlocks(_ source: String) -> [AIMarkdownBlock] {
    var kinds: [AIMarkdownBlock.Kind] = []
    var captured: [String] = []
    var isInCode = false
    var isInFormula = false

    for line in source.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            if isInCode { kinds.append(.code(captured.joined(separator: "\n"))); captured = [] }
            isInCode.toggle()
            continue
        }
        if isInCode { captured.append(line); continue }
        if trimmed.hasPrefix("$$") {
            let remainder = String(trimmed.dropFirst(2))
            if remainder.hasSuffix("$$"), remainder.count >= 2 {
                kinds.append(.formula(String(remainder.dropLast(2)).trimmingCharacters(in: .whitespaces)))
            } else if isInFormula {
                captured.append(remainder)
                kinds.append(.formula(captured.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                captured = []
                isInFormula = false
            } else {
                isInFormula = true
                if !remainder.isEmpty { captured.append(remainder) }
            }
            continue
        }
        if isInFormula { captured.append(line); continue }
        if trimmed.isEmpty { kinds.append(.spacer); continue }

        let hashes = trimmed.prefix { $0 == "#" }.count
        if (1...6).contains(hashes) {
            let text = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { kinds.append(.heading(hashes, text)); continue }
        }
        if let prefix = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
            kinds.append(.bullet(String(trimmed.dropFirst(prefix.count)))); continue
        }
        if trimmed.hasPrefix(">") {
            kinds.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))); continue
        }
        if let dot = trimmed.firstIndex(of: "."), !trimmed[..<dot].isEmpty,
           trimmed[..<dot].allSatisfy(\.isNumber), trimmed.index(after: dot) < trimmed.endIndex {
            kinds.append(.numbered(
                String(trimmed[...dot]),
                String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            ))
            continue
        }
        kinds.append(.paragraph(line))
    }
    if !captured.isEmpty { kinds.append(isInCode ? .code(captured.joined(separator: "\n")) : .formula(captured.joined(separator: "\n"))) }
    return kinds.enumerated().map { AIMarkdownBlock(id: $0.offset, kind: $0.element) }
}

private struct AIComposerView: View {
    @Binding var draft: String
    let isSending: Bool
    let isSelectingPages: Bool
    let attachmentCount: Int
    let isFocused: FocusState<Bool>.Binding
    let selectPages: () -> Void
    let upload: () -> Void
    let stop: () -> Void
    let submit: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: selectPages) {
                    Label(isSelectingPages ? "完成选页" : "选择页面", systemImage: "doc.viewfinder")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isSelectingPages ? .blue : .secondary)
                Button(action: upload) {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .help("上传图片或文本")
                .disabled(attachmentCount >= 5)
                Spacer()
                Text("\(attachmentCount)/5")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("发送消息…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused(isFocused)
                    .onSubmit(submit)
                Button(action: isSending ? stop : submit) {
                    Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSending ? .red : .primary)
                .disabled(!isSending && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(isSending ? "停止生成" : "发送")
            }
        }
        .padding(16)
    }
}

private struct AIAttachmentStrip: View {
    let pageIndices: [Int]
    let attachments: [AIPendingAttachment]
    let removePage: (Int) -> Void
    let removeAttachment: (UUID) -> Void

    var body: some View {
        if !pageIndices.isEmpty || !attachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(pageIndices, id: \.self) { pageIndex in
                        AIContextChip(
                            title: "第 \(pageIndex + 1) 页",
                            systemImage: "doc.richtext",
                            remove: { removePage(pageIndex) }
                        )
                    }
                    ForEach(attachments) { attachment in
                        AIContextChip(
                            title: attachment.name,
                            systemImage: attachment.kind == .image ? "photo" : "doc.text",
                            remove: { removeAttachment(attachment.id) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            .scrollIndicators(.hidden)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct AIContextChip: View {
    let title: String
    let systemImage: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.blue.opacity(0.1), in: Capsule())
    }
}
