import SwiftUI
import SwiftData

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case english = "en-US"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var nativeName: String {
        switch self {
        case .simplifiedChinese:
            "简体中文"
        case .traditionalChinese:
            "繁體中文"
        case .japanese:
            "日本語"
        case .english:
            "English"
        }
    }

    func localized(_ resource: LocalizedStringResource) -> String {
        var localizedResource = resource
        localizedResource.locale = locale
        return String(localized: localizedResource)
    }
}

@main struct KaitoApp: App {
    @AppStorage("appLanguage") private var appLanguageCode = AppLanguage.simplifiedChinese.rawValue

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageCode) ?? .simplifiedChinese
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(\.locale, appLanguage.locale)
                .task {
                    await AIServiceDiscovery.scanAndCache()
                }
#if os(iOS)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
#endif
        }
        .modelContainer(for: [AIConversation.self, AIMessage.self])
#if os(macOS)
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("AI") {
                Button(
                    appLanguage.localized("启动对话"),
                    systemImage: "message.fill"
                ) {
                    NotificationCenter.default.post(name: .startKaitoLLMChat, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button(
                    appLanguage.localized("历史记录"),
                    systemImage: "clock.arrow.circlepath"
                ) {
                    NotificationCenter.default.post(name: .showKaitoAIHistory, object: nil)
                }

                Button(
                    appLanguage.localized("返回答题卡"),
                    systemImage: "rectangle.and.pencil.and.ellipsis"
                ) {
                    NotificationCenter.default.post(name: .showKaitoAnswerSidebar, object: nil)
                }
            }
        }
#endif

#if os(macOS)
        Settings {
            PreferencesView(appLanguageCode: $appLanguageCode)
                .environment(\.locale, appLanguage.locale)
        }
#endif
    }
}

#if os(macOS)
private struct PreferencesView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Binding var appLanguageCode: String
    @State private var pendingLanguage: AppLanguage?
    @State private var showsLanguageChangeWarning = false

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageCode) ?? .simplifiedChinese
    }

    var body: some View {
        Form {
            Section("通用") {
                Picker("界面语言", selection: languageSelection) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName)
                            .tag(language)
                    }
                }

                Text("切换语言后，所有主窗口将自动重新打开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ollama") {
                Text("AI Chat 会在每次启动时自动查找本机 Ollama 服务、端口和已安装模型，无需手动填写。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 460)
        .alert("切换界面语言？", isPresented: $showsLanguageChangeWarning) {
            Button("取消", role: .cancel) {
                pendingLanguage = nil
            }
            Button("切换并重新打开窗口") {
                applyPendingLanguage()
            }
        } message: {
            Text("切换语言会关闭并重新打开所有主窗口。请先保存每个已打开 PDF 的修改，否则未保存的内容将会丢失。")
        }
        .environment(\.locale, selectedLanguage.locale)
    }

    private var languageSelection: Binding<AppLanguage> {
        Binding(
            get: { selectedLanguage },
            set: { language in
                guard language != selectedLanguage else { return }
                pendingLanguage = language
                showsLanguageChangeWarning = true
            }
        )
    }

    private func applyPendingLanguage() {
        guard let pendingLanguage else { return }
        let languageCode = pendingLanguage.rawValue
        self.pendingLanguage = nil
        UserDefaults.standard.set([languageCode], forKey: "AppleLanguages")
        appLanguageCode = languageCode

        dismissWindow(id: "main")
        Task { @MainActor in
            await Task.yield()
            openWindow(id: "main")
        }
    }
}
#endif
