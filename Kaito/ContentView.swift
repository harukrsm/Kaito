import CoreText
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

struct BundledPNGImage: View {
    let resourceName: String

    var body: some View {
#if os(macOS)
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.original)
        }
#else
        if let path = Bundle.main.path(forResource: resourceName, ofType: "png"),
           let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image)
                .resizable()
                .renderingMode(.original)
        }
#endif
    }
}

extension Notification.Name {
    static let commitKaitoCanvasDrawings = Notification.Name("CommitKaitoCanvasDrawings")
    static let restoreKaitoEditingOverlays = Notification.Name("RestoreKaitoEditingOverlays")
    static let startKaitoLLMChat = Notification.Name("StartKaitoLLMChat")
    static let showKaitoAIHistory = Notification.Name("ShowKaitoAIHistory")
    static let showKaitoAnswerSidebar = Notification.Name("ShowKaitoAnswerSidebar")
}

#if os(iOS)
import PencilKit

private extension UIViewController {
    var topmostPresentedViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.topmostPresentedViewController
        }
        if let navigationController = self as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleViewController.topmostPresentedViewController
        }
        if let tabBarController = self as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return selectedViewController.topmostPresentedViewController
        }
        return self
    }
}

private extension UIView {
    var descendantScrollViews: [UIScrollView] {
        subviews.flatMap { subview in
            let current = subview as? UIScrollView
            return (current.map { [$0] } ?? []) + subview.descendantScrollViews
        }
    }
}

private final class PDFPageAnnotationOverlayView: UIView {
    let canvasView = PKCanvasView(frame: .zero)
    private let textBoxPreviewLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        layer.strokeColor = UIColor.systemBlue.cgColor
        layer.lineWidth = 2
        layer.lineDashPattern = [6, 4]
        layer.isHidden = true
        return layer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        layer.addSublayer(textBoxPreviewLayer)
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showTextBoxPreview(from start: CGPoint, to end: CGPoint) {
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        textBoxPreviewLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 4).cgPath
        textBoxPreviewLayer.isHidden = false
    }

    func hideTextBoxPreview() {
        textBoxPreviewLayer.isHidden = true
        textBoxPreviewLayer.path = nil
    }
}
#endif

// MARK: - 答题卡与标记数据模型
struct QuestionRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var pageIndex: Int
    var pointX: Double
    var pointY: Double
    var questionNumber: Int
    var selectedOption: Int?
    var correctOption: Int?
    var note: String
    var isMarkDeleted: Bool = false

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        pointX: Double,
        pointY: Double,
        questionNumber: Int,
        selectedOption: Int?,
        correctOption: Int? = nil,
        note: String = "",
        isMarkDeleted: Bool = false
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.pointX = pointX
        self.pointY = pointY
        self.questionNumber = questionNumber
        self.selectedOption = selectedOption
        self.correctOption = correctOption
        self.note = note
        self.isMarkDeleted = isMarkDeleted
    }

    private enum CodingKeys: String, CodingKey {
        case id, pageIndex, pointX, pointY, questionNumber, selectedOption
        case correctOption, note, isMarkDeleted
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        pointX = try container.decode(Double.self, forKey: .pointX)
        pointY = try container.decode(Double.self, forKey: .pointY)
        questionNumber = try container.decode(Int.self, forKey: .questionNumber)
        selectedOption = try container.decodeIfPresent(Int.self, forKey: .selectedOption)
        correctOption = try container.decodeIfPresent(Int.self, forKey: .correctOption)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        isMarkDeleted = try container.decodeIfPresent(Bool.self, forKey: .isMarkDeleted) ?? false
    }
}

struct PendingQuestionMarker: Equatable {
    var id: UUID = UUID()
    var pageIndex: Int
    var pagePoint: CGPoint
    var viewPoint: CGPoint
    var questionNumber: Int
}

// MARK: - CoreText 文字绘制（直接在 CGContext 中绘制，确保 PDFAnnotation 绝对能渲染文字）
private func drawCTText(_ text: String, in rect: CGRect, fontSize: CGFloat, isBold: Bool = true, color: CGColor, context: CGContext) {
    let fontName = isBold ? "HelveticaNeue-Bold" : "HelveticaNeue"
    let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: color
    ]
    let attrString = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes as CFDictionary)
    guard let attrString else { return }
    let line = CTLineCreateWithAttributedString(attrString)
    let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

    context.saveGState()
    context.textMatrix = .identity
    let x = rect.midX - glyphBounds.width / 2 - glyphBounds.minX
    let y = rect.midY - glyphBounds.height / 2 - glyphBounds.minY
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)
    context.restoreGState()
}

// MARK: - 嵌入在 PDF 中的题目标记 Annotation
final class KaitoQuestionAnnotation: PDFAnnotation {
    var record: QuestionRecord
    var flashOpacity: Double = 0.0

    init(record: QuestionRecord) {
        self.record = record
        // 中心灰块: 26px x 13px
        // 左侧题号: 26px x 13px (间隔2px)
        // 右侧答案: 13px x 13px (间隔2px)
        let minX = record.pointX - 13 - 26 - 4
        let reviewWidth = record.correctOption == nil ? 0.0 : 30.0
        let maxX = record.pointX + 13 + 13 + 4 + reviewWidth
        let minY = record.pointY - 6.5 - 2
        let maxY = record.pointY + 6.5 + 2
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        super.init(bounds: bounds, forType: .square, withProperties: nil)
        self.userName = "KaitoQuestionMarker"
        updateContents()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateContents() {
        if let data = try? JSONEncoder().encode(record),
           let json = String(data: data, encoding: .utf8) {
            setValue(json, forAnnotationKey: PDFAnnotationKey(rawValue: "/KaitoRecord"))
            contents = record.note.isEmpty
                ? "题 \(record.questionNumber)：暂无笔记"
                : record.note
        }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard !record.isMarkDeleted else { return }
        context.saveGState()

        let centerRect = CGRect(x: record.pointX - 13, y: record.pointY - 6.5, width: 26, height: 13)
        let leftRect = CGRect(x: centerRect.minX - 26 - 2, y: centerRect.minY, width: 26, height: 13)
        let rightRect = CGRect(x: centerRect.maxX + 2, y: centerRect.minY, width: 13, height: 13)
        let correctRect = CGRect(x: rightRect.maxX + 2, y: centerRect.minY, width: 13, height: 13)
        let resultRect = CGRect(x: correctRect.maxX + 2, y: centerRect.minY, width: 13, height: 13)

        // 1. 左侧：和灰块一样大小(26x13)，同样的颜色显示题号，无背景
        drawCTText(
            "\(record.questionNumber)",
            in: leftRect,
            fontSize: 9.5,
            isBold: true,
            color: CGColor(gray: 0.38, alpha: 0.95),
            context: context
        )

        // 2. 中间：高度13px长度26px的半透明灰色方块
        let centerPath = CGPath(roundedRect: centerRect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        context.addPath(centerPath)
        context.setFillColor(CGColor(gray: 0.5, alpha: 0.55))
        context.fillPath()

        context.addPath(centerPath)
        context.setStrokeColor(CGColor(gray: 0.3, alpha: 0.4))
        context.setLineWidth(0.6)
        context.strokePath()

        // 点击题号时淡粉色快速渐隐闪两下
        if flashOpacity > 0 {
            context.addPath(centerPath)
            context.setFillColor(CGColor(red: 0.98, green: 0.65, blue: 0.78, alpha: flashOpacity))
            context.fillPath()
        }

        // 3. 右侧：粉色背景，白色字体，正方形(13x13)，高度和灰块一致
        if let opt = record.selectedOption {
            let rightPath = CGPath(roundedRect: rightRect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
            context.addPath(rightPath)
            let answerColor: CGColor
            if let correct = record.correctOption {
                answerColor = opt == correct
                    ? CGColor(red: 0.16, green: 0.68, blue: 0.33, alpha: 1)
                    : CGColor(red: 0.86, green: 0.18, blue: 0.22, alpha: 1)
            } else {
                answerColor = CGColor(red: 0.92, green: 0.35, blue: 0.58, alpha: 1)
            }
            context.setFillColor(answerColor)
            context.fillPath()

            drawCTText(
                "\(opt)",
                in: rightRect,
                fontSize: 9.5,
                isBold: true,
                color: CGColor(gray: 1.0, alpha: 1.0),
                context: context
            )

            if let correct = record.correctOption {
                let resultColor = opt == correct
                    ? CGColor(red: 0.16, green: 0.68, blue: 0.33, alpha: 1)
                    : CGColor(red: 0.86, green: 0.18, blue: 0.22, alpha: 1)

                for rect in [correctRect, resultRect] {
                    context.addPath(CGPath(roundedRect: rect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
                    context.setFillColor(resultColor)
                    context.fillPath()
                }
                let white = CGColor(gray: 1, alpha: 1)
                drawCTText("\(correct)", in: correctRect, fontSize: 9.5, color: white, context: context)
                drawCTText(opt == correct ? "O" : "X", in: resultRect, fontSize: 9.5, color: white, context: context)
            }
        }

        context.restoreGState()
    }
}

private func loadQuestionsFromPDF(_ pdf: PDFDocument) -> [QuestionRecord] {
    var loaded: [QuestionRecord] = []
    for pageIndex in 0..<pdf.pageCount {
        guard let page = pdf.page(at: pageIndex) else { continue }
        for annotation in page.annotations {
            if annotation.userName == "KaitoQuestionMarker" {
                let storedJSON = annotation.value(
                    forAnnotationKey: PDFAnnotationKey(rawValue: "/KaitoRecord")
                ) as? String
                let legacyJSON = annotation.contents
                if let json = storedJSON ?? legacyJSON,
                   let data = json.data(using: .utf8),
                   let question = try? JSONDecoder().decode(QuestionRecord.self, from: data) {
                    loaded.append(question)
                }
            }
        }
    }
    return loaded.sorted(by: { $0.questionNumber < $1.questionNumber })
}

private func syncQuestionAnnotationsToDocument(_ pdf: PDFDocument, questions: [QuestionRecord]) {
    for pageIndex in 0..<pdf.pageCount {
        guard let page = pdf.page(at: pageIndex) else { continue }
        let markerAnns = page.annotations.filter { $0.userName == "KaitoQuestionMarker" }
        for ann in markerAnns {
            page.removeAnnotation(ann)
        }
    }
    for q in questions where !q.isMarkDeleted {
        if let page = pdf.page(at: q.pageIndex) {
            let ann = KaitoQuestionAnnotation(record: q)
            page.addAnnotation(ann)
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var document: PDFDocument?
    @State private var isImportingPDF = false
    @State private var importErrorMessage: String?
    @State private var documentTitle = ""
    @State private var currentPage = 0
    @State private var zoom = 1.0
    @State private var isZoomLocked = false
    @State private var showsTwoPages = false
    @State private var questions: [QuestionRecord] = []
    @State private var annotationFontName = "Helvetica"
    @State private var annotationTextIsBold = false
    @State private var annotationTextIsItalic = false
#if os(macOS)
    @State private var annotationTool: PDFAnnotationTool?
    @State private var annotationWidth = 2.5
    @AppStorage("annotationColorRed") private var annotationColorRed = 0.12
    @AppStorage("annotationColorGreen") private var annotationColorGreen = 0.12
    @AppStorage("annotationColorBlue") private var annotationColorBlue = 0.13
    @State private var sourceURL: URL?
    @State private var hasUnsavedChanges = false
    @State private var showsUnsavedChangesDialog = false
    @State private var saveToast: SaveToast?
    @State private var saveToastDismissTask: Task<Void, Never>?
#elseif os(iOS)
    @State private var annotationTool: PDFAnnotationTool?
    @State private var annotationWidth = 18.0
    @State private var annotationColor = Color.primary
    @State private var sourceURL: URL?
    @State private var hasUnsavedChanges = false
    @State private var saveToast: SaveToast?
    @State private var saveToastDismissTask: Task<Void, Never>?
    @State private var exportDocument = PDFExportDocument(data: Data())
    @State private var isExportingPDF = false
#endif

    var body: some View {
        Group {
            if let document {
                workspace(document: document)
                    .transition(.opacity)
            } else {
                PDFWelcomeView(
                    openPDF: { isImportingPDF = true },
                    openLastPDF: openLastPDF,
                    hasLastPDF: hasLastPDF,
                    openDroppedPDF: { openPDF(from: .success($0)) }
                )
                .transition(.blurReplace(.downUp))
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.45),
            value: document != nil
        )
        .frame(minWidth: 760, minHeight: 560)
#if os(macOS) || os(iOS)
        .overlay(alignment: .topLeading) {
            if let saveToast {
                Text(saveToast.message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(saveToast.isError ? .red : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .padding(.top, 12)
                    .padding(.leading, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
#endif
        .fileImporter(isPresented: $isImportingPDF, allowedContentTypes: [.pdf]) { result in
            openPDF(from: result)
        }
#if os(iOS)
        .fileExporter(
            isPresented: $isExportingPDF,
            document: exportDocument,
            contentType: .pdf,
            defaultFilename: "\(documentTitle)-Kaito"
        ) { result in
            switch result {
            case .success:
                hasUnsavedChanges = false
                showSaveToast(message: "已保存 PDF 副本。", isError: false)
            case .failure(let error):
                showSaveToast(message: "保存副本失败（错误 \((error as NSError).code)）。", isError: true)
            }
        }
#endif
        .alert("无法打开 PDF", isPresented: importErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "文件无法读取。")
        }
#if os(macOS)
        .confirmationDialog(
            "是否保存批注？",
            isPresented: $showsUnsavedChangesDialog,
            titleVisibility: .visible
        ) {
            Button("保存为副本") {
                if savePDFCopy() { isImportingPDF = true }
            }
            Button("保存") {
                if savePDF() { isImportingPDF = true }
            }
            Button("放弃修改", role: .destructive) {
                hasUnsavedChanges = false
                isImportingPDF = true
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前 PDF 有尚未保存的修改。请选择保存为副本、覆盖原文件或放弃修改。")
        }
#endif
        .background {
            KeyboardShortcuts(
                previousPage: { movePage(by: showsTwoPages ? -2 : -1) },
                nextPage: { movePage(by: showsTwoPages ? 2 : 1) },
                openPDF: requestOpenPDF,
                savePDF: savePDFCopy
            )
        }
#if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, hasUnsavedChanges else { return }
            if !savePDF() {
                saveRecoverySnapshot()
            }
        }
#endif
#if os(macOS)
        .background(
            WindowCloseGuard(
                hasUnsavedChanges: hasUnsavedChanges,
                saveCopy: savePDFCopy,
                saveOriginal: savePDF
            )
        )
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
#endif
    }

    @ViewBuilder
    private func workspace(document: PDFDocument) -> some View {
#if os(macOS)
        WorkspaceView(
            document: document,
            documentTitle: documentTitle,
            currentPage: $currentPage,
            zoom: $zoom,
            isZoomLocked: $isZoomLocked,
            showsTwoPages: $showsTwoPages,
            questions: $questions,
            annotationTool: $annotationTool,
            annotationWidth: $annotationWidth,
            annotationColor: annotationColorBinding,
            annotationFontName: $annotationFontName,
            annotationTextIsBold: $annotationTextIsBold,
            annotationTextIsItalic: $annotationTextIsItalic,
            hasUnsavedChanges: $hasUnsavedChanges,
            savePDFCopy: savePDFCopy,
            savePDF: savePDF,
            openPDF: requestOpenPDF
        )
#else
        WorkspaceView(
            document: document,
            documentTitle: documentTitle,
            currentPage: $currentPage,
            zoom: $zoom,
            isZoomLocked: $isZoomLocked,
            showsTwoPages: $showsTwoPages,
            questions: $questions,
            annotationTool: $annotationTool,
            annotationWidth: $annotationWidth,
            annotationColor: $annotationColor,
            annotationFontName: $annotationFontName,
            annotationTextIsBold: $annotationTextIsBold,
            annotationTextIsItalic: $annotationTextIsItalic,
            hasUnsavedChanges: $hasUnsavedChanges,
            savePDFCopy: savePDFCopy,
            savePDF: savePDF,
            openPDF: requestOpenPDF
        )
#endif
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )
    }

#if os(macOS)
    private var annotationColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    .sRGB,
                    red: annotationColorRed,
                    green: annotationColorGreen,
                    blue: annotationColorBlue
                )
            },
            set: { color in
                guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return }
                annotationColorRed = resolved.redComponent
                annotationColorGreen = resolved.greenComponent
                annotationColorBlue = resolved.blueComponent
            }
        )
    }
#endif

    private func openPDF(from result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: url)
            guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
                throw PDFOpenError.invalidDocument
            }

            documentTitle = url.deletingPathExtension().lastPathComponent
            cacheLastOpenedPDF(data, title: documentTitle)
            let loaded = loadQuestionsFromPDF(pdf)
            questions = loaded
            syncQuestionAnnotationsToDocument(pdf, questions: loaded)
#if os(macOS) || os(iOS)
            sourceURL = url
            hasUnsavedChanges = false
#endif
            currentPage = 0
            zoom = 1
            isZoomLocked = false
            showsTwoPages = false
            document = pdf
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private var lastOpenedPDFURL: URL? {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return applicationSupportURL
            .appendingPathComponent("Kaito", isDirectory: true)
            .appendingPathComponent("LastOpened.pdf")
    }

    private var hasLastPDF: Bool {
        guard let lastOpenedPDFURL else { return false }
        return FileManager.default.fileExists(atPath: lastOpenedPDFURL.path)
    }

    private func cacheLastOpenedPDF(_ data: Data, title: String) {
        guard let lastOpenedPDFURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: lastOpenedPDFURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: lastOpenedPDFURL, options: .atomic)
            UserDefaults.standard.set(title, forKey: "lastOpenedPDFTitle")
        } catch {
            // Opening the selected document should still succeed if the recent-file cache cannot be updated.
        }
    }

    private func openLastPDF() {
        guard let lastOpenedPDFURL, hasLastPDF else { return }
        openPDF(from: .success(lastOpenedPDFURL))
        if let cachedTitle = UserDefaults.standard.string(forKey: "lastOpenedPDFTitle") {
            documentTitle = cachedTitle
        }
    }

    private func requestOpenPDF() {
#if os(macOS)
        if hasUnsavedChanges {
            showsUnsavedChangesDialog = true
        } else {
            isImportingPDF = true
        }
#else
        isImportingPDF = true
#endif
    }

#if os(macOS)
    @discardableResult
    private func savePDFCopy() -> Bool {
        guard let document, let sourceURL else {
            showSaveToast(message: "无法保存：未找到当前 PDF。", isError: true)
            return false
        }

        syncQuestionAnnotationsToDocument(document, questions: questions)
        guard let pdfData = document.dataRepresentation() else {
            showSaveToast(message: "无法生成 PDF 数据。", isError: true)
            return false
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.nameFieldStringValue = nextCopyName(for: sourceURL)

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return false
        }

        do {
            try pdfData.write(to: destinationURL, options: .atomic)
            self.sourceURL = destinationURL
            documentTitle = destinationURL.deletingPathExtension().lastPathComponent
            hasUnsavedChanges = false
            showSaveToast(message: "已保存副本：\(destinationURL.lastPathComponent)", isError: false)
            return true
        } catch {
            showSaveToast(message: "保存副本失败（错误 \((error as NSError).code)）。", isError: true)
            return false
        }
    }

    private func nextCopyName(for sourceURL: URL) -> String {
        let directoryURL = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent

        for number in 1...999 {
            let fileName = "\(baseName)-Kaito\(String(format: "%03d", number)).pdf"
            if !FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent(fileName).path) {
                return fileName
            }
        }

        return "\(baseName)-Kaito\(UUID().uuidString.prefix(8)).pdf"
    }

    @discardableResult
    private func savePDF() -> Bool {
        guard let document, let sourceURL else {
            showSaveToast(message: "Error 1.", isError: true)
            return false
        }
        let isAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if isAccessing { sourceURL.stopAccessingSecurityScopedResource() } }

        syncQuestionAnnotationsToDocument(document, questions: questions)

        guard let pdfData = document.dataRepresentation() else {
            showSaveToast(message: "Error 2.", isError: true)
            return false
        }

        do {
            try pdfData.write(to: sourceURL, options: .atomic)
            hasUnsavedChanges = false
            showSaveToast(message: "Saved.", isError: false)
            return true
        } catch {
            showSaveToast(message: "Error \((error as NSError).code).", isError: true)
            return false
        }
    }

    private func showSaveToast(message: String, isError: Bool) {
        saveToastDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) {
            saveToast = SaveToast(message: message, isError: isError)
        }
        saveToastDismissTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.16)) {
                saveToast = nil
            }
        }
    }
#endif

#if os(iOS)
    @discardableResult
    private func savePDFCopy() -> Bool {
        guard let document else {
            showSaveToast(message: "无法保存：未找到当前 PDF。", isError: true)
            return false
        }
        NotificationCenter.default.post(name: .commitKaitoCanvasDrawings, object: nil)
        syncQuestionAnnotationsToDocument(document, questions: questions)
        guard let data = document.dataRepresentation() else {
            showSaveToast(message: "无法生成 PDF 数据。", isError: true)
            return false
        }
        NotificationCenter.default.post(name: .restoreKaitoEditingOverlays, object: nil)
        exportDocument = PDFExportDocument(data: data)
        Task { @MainActor in
            isExportingPDF = true
        }
        return true
    }

    @discardableResult
    private func savePDF() -> Bool {
        guard let document, let sourceURL else {
            showSaveToast(message: "无法保存：未找到原始 PDF。", isError: true)
            return false
        }
        NotificationCenter.default.post(name: .commitKaitoCanvasDrawings, object: nil)
        syncQuestionAnnotationsToDocument(document, questions: questions)
        guard let data = document.dataRepresentation() else {
            showSaveToast(message: "无法生成 PDF 数据。", isError: true)
            return false
        }
        NotificationCenter.default.post(name: .restoreKaitoEditingOverlays, object: nil)

        let isAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if isAccessing { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            try data.write(to: sourceURL, options: .atomic)
            hasUnsavedChanges = false
            showSaveToast(message: "已保存。", isError: false)
            return true
        } catch {
            showSaveToast(message: "保存失败（错误 \((error as NSError).code)）。", isError: true)
            return false
        }
    }

    private func showSaveToast(message: String, isError: Bool) {
        saveToastDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) {
            saveToast = SaveToast(message: message, isError: isError)
        }
        saveToastDismissTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.16)) {
                saveToast = nil
            }
        }
    }

    private func saveRecoverySnapshot() {
        guard let document else { return }
        NotificationCenter.default.post(name: .commitKaitoCanvasDrawings, object: nil)
        syncQuestionAnnotationsToDocument(document, questions: questions)
        guard let data = document.dataRepresentation() else { return }
        NotificationCenter.default.post(name: .restoreKaitoEditingOverlays, object: nil)
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Kaito Recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeName = documentTitle.isEmpty ? "未命名" : documentTitle
            try data.write(to: directory.appendingPathComponent("\(safeName)-自动恢复.pdf"), options: .atomic)
            showSaveToast(message: "已创建自动恢复副本。", isError: false)
        } catch {
            showSaveToast(message: "自动恢复副本保存失败。", isError: true)
        }
    }
#endif

    private func movePage(by offset: Int) {
        guard let document else { return }
        currentPage = min(max(currentPage + offset, 0), document.pageCount - 1)
    }
}

private struct SaveToast {
    let message: String
    let isError: Bool
}

#if os(iOS)
private struct PDFExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif

private enum PDFAnnotationTool {
    case pencil
    case eraser
    case textBox
}

private enum PDFOpenError: LocalizedError {
    case invalidDocument

    var errorDescription: String? {
        "这个文件不是有效的 PDF，或没有可显示的页面。"
    }
}

private struct WorkspaceView: View {
    private let floatingInset: CGFloat = 18
    private let minimumSidebarWidth: CGFloat = 328
    private let maximumSidebarWidth: CGFloat = 408

    let document: PDFDocument
    let documentTitle: String
    @Binding var currentPage: Int
    @Binding var zoom: Double
    @Binding var isZoomLocked: Bool
    @Binding var showsTwoPages: Bool
    @Binding var questions: [QuestionRecord]
#if os(macOS) || os(iOS)
    @Binding var annotationTool: PDFAnnotationTool?
    @Binding var annotationWidth: Double
    @Binding var annotationColor: Color
    @Binding var annotationFontName: String
    @Binding var annotationTextIsBold: Bool
    @Binding var annotationTextIsItalic: Bool
    @Binding var hasUnsavedChanges: Bool
    let savePDFCopy: () -> Bool
    let savePDF: () -> Bool
#endif
    let openPDF: () -> Void
    @State private var isChangingLayout = false
    @State private var sidebarWidth: CGFloat = 328
    @GestureState private var sidebarDragTranslation: CGFloat = 0
    @State private var pendingMarker: PendingQuestionMarker?
    @State private var coordinatorRef: PDFReaderCoordinator?
    @State private var isReviewMode = false
    @State private var showsLLMChat = false
    @State private var showsAIHistory = false
    @State private var isSelectingAIPages = false
    @State private var selectedAIPageIndices: [Int] = []
    @State private var maximumAISelectedPages = 5

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = clampedSidebarWidth(sidebarWidth + sidebarDragTranslation)
            let readerWidth = max(geometry.size.width - panelWidth - floatingInset * 3, 220)
            let controlsTop = floatingInset
#if os(iOS)
            let controlsPanelHeight: CGFloat = 120
#else
            let controlsPanelHeight: CGFloat = 108
#endif
            let panelTop = controlsTop + controlsPanelHeight + 8
            let panelHeight = max(geometry.size.height - panelTop - floatingInset, 220)

            ZStack(alignment: .topTrailing) {
                translucentCanvas
                    .ignoresSafeArea()

                reader
                    .frame(width: readerWidth, height: geometry.size.height - floatingInset * 2)
                    .position(
                        x: floatingInset + readerWidth / 2,
                        y: geometry.size.height / 2
                    )

                VStack(spacing: 8) {
                    ReaderControls(
                        zoom: $zoom,
                        isZoomLocked: $isZoomLocked,
                        showsTwoPages: showsTwoPages,
                        isReviewMode: $isReviewMode,
                        showsAIChat: $showsLLMChat,
                        availableWidth: panelWidth - 24,
                        openPDF: openPDF,
                        toggleTwoPages: toggleTwoPages
                    )

#if os(macOS) || os(iOS)
                    AnnotationControls(
                        tool: $annotationTool,
                        width: $annotationWidth,
                        color: $annotationColor,
                        fontName: $annotationFontName,
                        textIsBold: $annotationTextIsBold,
                        textIsItalic: $annotationTextIsItalic,
                        availableWidth: panelWidth - 24,
                        hasUnsavedChanges: hasUnsavedChanges,
                        savePDFCopy: {
#if os(iOS)
                            coordinatorRef?.commitCanvasDrawingsToPDF()
#endif
                            return savePDFCopy()
                        },
                        savePDF: {
#if os(iOS)
                            coordinatorRef?.commitCanvasDrawingsToPDF()
#endif
                            return savePDF()
                        }
                    )
#endif
                }
                .padding(12)
                .frame(width: panelWidth)
                .glassEffect(
                    .regular,
                    in: ConcentricRectangle(corners: .concentric(minimum: 24), isUniform: true)
                )
                .padding(.top, controlsTop)
                .padding(.trailing, floatingInset)
                .zIndex(30)
#if os(macOS)
                .allowsWindowActivationEvents()
#endif
                AnswerSidebar(
                    documentTitle: documentTitle,
                    currentPage: currentPage + 1,
                    pageCount: document.pageCount,
                    questions: $questions,
                    isReviewMode: $isReviewMode,
                    showsLLMChat: showsLLMChat,
                    showsAIHistory: $showsAIHistory,
                    document: document,
                    selectedAIPageIndices: $selectedAIPageIndices,
                    isSelectingAIPages: $isSelectingAIPages,
                    maximumAISelectedPages: $maximumAISelectedPages,
                    acceptsReviewShortcuts: pendingMarker == nil,
                    onNavigateToQuestion: { q in
                        navigateToQuestion(q)
                    },
                    onQuestionUpdated: {
#if os(macOS) || os(iOS)
                        hasUnsavedChanges = true
#endif
                        syncQuestionAnnotationsToDocument(document, questions: questions)
                    }
                )
                    .frame(width: panelWidth, height: panelHeight)
                    .position(
                        x: geometry.size.width - floatingInset - panelWidth / 2,
                        y: panelTop + panelHeight / 2
                    )
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle()
                            .offset(x: 6)
                            .gesture(sidebarResizeGesture)
                    }

            }
        }
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .startKaitoLLMChat)) { _ in
            showsAIHistory = false
            withAnimation(.snappy(duration: 0.25)) {
                showsLLMChat = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showKaitoAIHistory)) { _ in
            showsAIHistory = true
            withAnimation(.snappy(duration: 0.25)) {
                showsLLMChat = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showKaitoAnswerSidebar)) { _ in
            withAnimation(.snappy(duration: 0.25)) {
                showsLLMChat = false
            }
        }
        .onChange(of: showsLLMChat) { _, isShowingAI in
            if !isShowingAI {
                isSelectingAIPages = false
            }
        }
#if os(macOS)
        .background(WindowAccessor { window in
            resize(window: window, animated: false)
        })
#endif
    }

    @ViewBuilder
    private var translucentCanvas: some View {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor).opacity(0.89)
#else
        Color(uiColor: .systemBackground).opacity(0.89)
#endif
    }

    @ViewBuilder
    private var reader: some View {
        ZStack {
            Group {
#if os(macOS)
                PDFKitReader(
                    document: document,
                    currentPage: $currentPage,
                    zoom: $zoom,
                    isZoomLocked: $isZoomLocked,
                    showsTwoPages: $showsTwoPages,
                    annotationTool: annotationTool,
                    annotationWidth: annotationWidth,
                    annotationColor: annotationColor,
                    isPageSelectionEnabled: isSelectingAIPages,
                    selectedPageIndices: $selectedAIPageIndices,
                    maximumSelectedPages: maximumAISelectedPages,
                    annotationChanged: { hasUnsavedChanges = true },
                    onDoubleTap: { pageIndex, pagePoint, viewPoint in
                        if annotationTool == nil {
                            let maxNum = questions.map(\.questionNumber).max() ?? 0
                            let nextNum = max(maxNum + 1, 1)
                            pendingMarker = PendingQuestionMarker(
                                pageIndex: pageIndex,
                                pagePoint: pagePoint,
                                viewPoint: viewPoint,
                                questionNumber: nextNum
                            )
                        }
                    },
                    onMarkerDeleted: { id in
                        if let idx = questions.firstIndex(where: { $0.id == id }) {
                            questions[idx].isMarkDeleted = true
                            hasUnsavedChanges = true
                        }
                    },
                    coordinatorRef: $coordinatorRef
                )
#else
                PDFKitReader(
                    document: document,
                    currentPage: $currentPage,
                    zoom: $zoom,
                    isZoomLocked: $isZoomLocked,
                    showsTwoPages: $showsTwoPages,
                    annotationTool: annotationTool,
                    annotationWidth: $annotationWidth,
                    annotationColor: annotationColor,
                    annotationFontName: annotationFontName,
                    annotationTextIsBold: annotationTextIsBold,
                    annotationTextIsItalic: annotationTextIsItalic,
                    annotationChanged: { hasUnsavedChanges = true },
                    onDoubleTap: { pageIndex, pagePoint, viewPoint in
                        let maxNum = questions.map(\.questionNumber).max() ?? 0
                        let nextNum = max(maxNum + 1, 1)
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                            pendingMarker = PendingQuestionMarker(
                                pageIndex: pageIndex,
                                pagePoint: pagePoint,
                                viewPoint: viewPoint,
                                questionNumber: nextNum
                            )
                        }
                    },
                    onMarkerDeleted: { id in
                        if let idx = questions.firstIndex(where: { $0.id == id }) {
                            questions[idx].isMarkDeleted = true
                        }
                    },
                    coordinatorRef: $coordinatorRef
                )
#endif
            }

            if let pending = pendingMarker {
                pendingOptionOverlay(pending)
            }
        }
        .background {
            if let pending = pendingMarker {
                NumericOptionShortcuts { option in
                    commitPendingOption(pending, option: option)
                }
            }
        }
        .scaleEffect(x: isChangingLayout ? 0.94 : 1, y: isChangingLayout ? 0.98 : 1, anchor: .trailing)
        .offset(x: isChangingLayout ? 18 : 0)
        .opacity(isChangingLayout ? 0.82 : 1)
    }

#if os(iOS)
    private let optionButtonSize: CGFloat = 48
    private let optionButtonFontSize: CGFloat = 20
    private let optionButtonSpacing: CGFloat = 10
    private let optionOverlayHorizontalPadding: CGFloat = 8
#else
    private let optionButtonSize: CGFloat = 28
    private let optionButtonFontSize: CGFloat = 14
    private let optionButtonSpacing: CGFloat = 5
    private let optionOverlayHorizontalPadding: CGFloat = 6
#endif

    private func pendingOptionOverlay(_ pending: PendingQuestionMarker) -> some View {
        GeometryReader { _ in
            Color.black.opacity(0.001)
                .onTapGesture {
                    pendingMarker = nil
                }

            ZStack {
                // 放大 30% 的半透明灰色方块（高度13px长度26px），严格准心居中
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.gray.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                    )
                    .frame(width: 26, height: 13)
                    .position(x: pending.viewPoint.x, y: pending.viewPoint.y)

                // 从方块右侧展开四个选项按钮 1, 2, 3, 4（同样放大 30%）
                HStack(spacing: optionButtonSpacing) {
                    ForEach(1...4, id: \.self) { opt in
                        Button(action: {
                            commitPendingOption(pending, option: opt)
                        }) {
                            Text("\(opt)")
                                .font(.system(size: optionButtonFontSize, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: optionButtonSize, height: optionButtonSize)
                                .background(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.95, green: 0.45, blue: 0.62),
                                            Color(red: 0.88, green: 0.32, blue: 0.52)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    in: Circle()
                                )
                                .shadow(color: Color.black.opacity(0.2), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, optionOverlayHorizontalPadding)
#if os(iOS)
                .padding(.vertical, 8)
#else
                .padding(.vertical, 3)
#endif
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.6)
                )
                .shadow(color: Color.black.opacity(0.15), radius: 6, y: 2)
                .position(
                    x: pending.viewPoint.x
                        + 13
                        + 6
                        + (optionButtonSize * 4
                            + optionButtonSpacing * 3
                            + optionOverlayHorizontalPadding * 2) / 2,
                    y: pending.viewPoint.y
                )
            }
#if os(iOS)
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.72, anchor: .leading)
                        .combined(with: .opacity)
                        .combined(with: .move(edge: .leading)),
                    removal: .scale(scale: 0.88, anchor: .leading)
                        .combined(with: .opacity)
                )
            )
#else
            .transition(.scale.combined(with: .opacity))
#endif
        }
    }

    private func commitPendingOption(_ pending: PendingQuestionMarker, option: Int) {
        let newQuestion = QuestionRecord(
            id: pending.id,
            pageIndex: pending.pageIndex,
            pointX: Double(pending.pagePoint.x),
            pointY: Double(pending.pagePoint.y),
            questionNumber: pending.questionNumber,
            selectedOption: option,
            isMarkDeleted: false
        )

        if let page = document.page(at: pending.pageIndex) {
            let annotation = KaitoQuestionAnnotation(record: newQuestion)
            page.addAnnotation(annotation)
        }

        questions.append(newQuestion)
#if os(macOS)
        hasUnsavedChanges = true
#endif
        withAnimation(.easeOut(duration: 0.15)) {
            pendingMarker = nil
        }
    }

    private func navigateToQuestion(_ question: QuestionRecord) {
        coordinatorRef?.navigateToQuestion(question)
    }

    private var sidebarResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($sidebarDragTranslation) { value, translation, _ in
                translation = value.translation.width
            }
            .onEnded { value in
                let newWidth = clampedSidebarWidth(sidebarWidth + value.translation.width)
                let widthChange = newWidth - sidebarWidth
#if os(macOS)
                NSApp.keyWindow.map { resizeWindowHorizontally($0, by: widthChange) }
#endif
                sidebarWidth = newWidth
            }
    }

    private func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumSidebarWidth), maximumSidebarWidth)
    }

#if os(macOS)
    private func resizeWindowHorizontally(_ window: NSWindow, by widthChange: CGFloat) {
        guard widthChange != 0, let screen = window.screen ?? NSScreen.main else { return }
        var frame = window.frame
        frame.size.width += widthChange
        if frame.maxX > screen.visibleFrame.maxX {
            frame.origin.x -= frame.maxX - screen.visibleFrame.maxX
        }
        window.setFrame(frame, display: true)
    }
#endif

    private func toggleTwoPages() {
        guard !isChangingLayout else { return }
#if os(macOS)
        if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true {
            showsTwoPages.toggle()
            if showsTwoPages {
                currentPage = (currentPage / 2) * 2
            }
            return
        }
#endif
        withAnimation(.easeIn(duration: 0.12)) {
            isChangingLayout = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            showsTwoPages.toggle()
            if showsTwoPages {
                currentPage = (currentPage / 2) * 2
            }
#if os(macOS)
            NSApp.keyWindow.map { resize(window: $0, animated: true) }
#endif
            withAnimation(.snappy(duration: 0.34)) {
                isChangingLayout = false
            }
        }
    }

#if os(macOS)
    private func resize(window: NSWindow, animated: Bool) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let pageBounds = document.page(at: 0)?.bounds(for: .mediaBox)
            ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let ratio = pageBounds.width / max(pageBounds.height, 1)
        let contentHeight = min(max(window.contentLayoutRect.height, 620), screen.visibleFrame.height * 0.88)
        let paperHeight = contentHeight - floatingInset * 2
        let paperWidth = paperHeight * ratio
        let readerWidth = showsTwoPages ? paperWidth * 2 + floatingInset / 2 : paperWidth
        let targetWidth = min(readerWidth + sidebarWidth + floatingInset * 3, screen.visibleFrame.width * 0.95)
        let size = window.frameRect(forContentRect: CGRect(origin: .zero, size: CGSize(width: targetWidth, height: contentHeight))).size
        var frame = window.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        frame.size = size
        frame.origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        frame.origin.x = min(max(frame.origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width)
        frame.origin.y = min(max(frame.origin.y, screen.visibleFrame.minY), screen.visibleFrame.maxY - size.height)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.38
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }
#endif
}

#if os(macOS)
private struct RoundControlButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Circle())
            .background(.thinMaterial, in: Circle())
            .overlay {
                Circle()
                    .fill(
                        isSelected
                            ? Color(red: 0.98, green: 0.78, blue: 0.84).opacity(0.72)
                            : .clear
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.22), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
#endif

#if os(iOS)
private struct IPadToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
#endif

private struct ReaderControls: View {
    @Binding var zoom: Double
    @Binding var isZoomLocked: Bool
    let showsTwoPages: Bool
    @Binding var isReviewMode: Bool
    @Binding var showsAIChat: Bool
    let availableWidth: CGFloat
    let openPDF: () -> Void
    let toggleTwoPages: () -> Void

#if os(iOS)
    private let controlSize: CGFloat = 44
    private var zoomSliderWidth: CGFloat {
        max(48, availableWidth - 274)
    }
#else
    private let controlSize: CGFloat = 38
    private var zoomSliderWidth: CGFloat {
        max(48, availableWidth - 268)
    }
#endif

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.24)) {
                        isReviewMode.toggle()
                    }
                } label: {
                    Image(systemName: isReviewMode ? "checkmark.seal.fill" : "checkmark.seal")
                        .frame(width: controlSize, height: controlSize)
                }
#if os(macOS)
                .buttonStyle(RoundControlButtonStyle(isSelected: isReviewMode))
#else
                .buttonStyle(IPadToolbarButtonStyle())
                .glassEffect(
                    isReviewMode ? .regular.tint(.green).interactive() : .regular.interactive(),
                    in: Circle()
                )
#endif
                .help(isReviewMode ? "退出对答案模式" : "进入对答案模式")

                Button(action: openPDF) {
                    Image(systemName: "folder")
                        .frame(width: controlSize, height: controlSize)
                }
#if os(macOS)
                .buttonStyle(RoundControlButtonStyle(isSelected: false))
#else
                .buttonStyle(IPadToolbarButtonStyle())
                .glassEffect(.regular.interactive(), in: Circle())
#endif
                .help("打开 PDF")

                Button {
                    withAnimation(.snappy(duration: 0.28)) {
                        showsAIChat.toggle()
                    }
                } label: {
                    Image(systemName: showsAIChat ? "rectangle.and.pencil.and.ellipsis" : "sparkles")
                        .frame(width: controlSize, height: controlSize)
                }
#if os(macOS)
                .buttonStyle(RoundControlButtonStyle(isSelected: showsAIChat))
#else
                .buttonStyle(IPadToolbarButtonStyle())
                .glassEffect(
                    showsAIChat ? .regular.tint(Color(red: 0.98, green: 0.78, blue: 0.84)).interactive() : .regular.interactive(),
                    in: Circle()
                )
#endif
                .help(showsAIChat ? "返回答题卡" : "打开 AI Chat")

                HStack(spacing: 5) {
                    Image(systemName: "minus.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Slider(value: $zoom, in: 0.65...2.2)
                        .frame(width: zoomSliderWidth)
                        .disabled(isZoomLocked)
                    Image(systemName: "plus.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                }
                .padding(.horizontal, 8)
                .frame(height: controlSize)
                .glassEffect(
                    .regular.interactive(),
                    in: Capsule()
                )

                Button(action: toggleTwoPages) {
                    Image(systemName: showsTwoPages ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                        .frame(width: controlSize, height: controlSize)
                }
#if os(macOS)
                .buttonStyle(RoundControlButtonStyle(isSelected: showsTwoPages))
#else
                .buttonStyle(IPadToolbarButtonStyle())
                .glassEffect(
                    showsTwoPages ? .regular.tint(Color(red: 0.98, green: 0.78, blue: 0.84)).interactive() : .regular.interactive(),
                    in: Circle()
                )
#endif
                .help(showsTwoPages ? "切换到单页" : "切换到双页")
            }
        }
    }
}

#if os(macOS)
private struct AnnotationControls: View {
    @Binding var tool: PDFAnnotationTool?
    @Binding var width: Double
    @Binding var color: Color
    @Binding var fontName: String
    @Binding var textIsBold: Bool
    @Binding var textIsItalic: Bool
    let availableWidth: CGFloat
    let hasUnsavedChanges: Bool
    let savePDFCopy: () -> Bool
    let savePDF: () -> Bool

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ZStack {
                    MacColorWell(color: $color)

                    Circle()
                        .fill(color)
                        .allowsHitTesting(false)
                }
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
                    .clipShape(Circle())
                    .help("画笔颜色")

                Button { tool = tool == .pencil ? nil : .pencil } label: {
                    Image(systemName: "pencil.tip")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(RoundControlButtonStyle(isSelected: tool == .pencil))
                .contentShape(Circle())
                .help(tool == .pencil ? "再次点按可返回文本选择" : "铅笔（按住鼠标左键书写）")

                Button { tool = tool == .eraser ? nil : .eraser } label: {
                    Image(systemName: "eraser")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(RoundControlButtonStyle(isSelected: tool == .eraser))
                .contentShape(Circle())
                .help(tool == .eraser ? "再次点按可返回文本选择" : "橡皮擦（删除整条笔迹）")

                HStack(spacing: 5) {
                    Image(systemName: "line.diagonal")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Slider(value: $width, in: 1...10)
                        .frame(width: max(48, availableWidth - 268))
                    Text(width, format: .number.precision(.fractionLength(0...1)))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: 24, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .frame(height: 38)
                .glassEffect(
                    .regular.interactive(),
                    in: Capsule()
                )
                .disabled(tool != .pencil)
                .help("铅笔粗细")

                Button { _ = savePDFCopy() } label: {
                    Image(systemName: hasUnsavedChanges ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(RoundControlButtonStyle(isSelected: hasUnsavedChanges))
                .disabled(!hasUnsavedChanges)
                .help(hasUnsavedChanges ? "保存为新副本" : "没有未保存的修改")
                .contextMenu {
                    Button("保存为副本") {
                        _ = savePDFCopy()
                    }
                    Button("保存") {
                        _ = savePDF()
                    }
                }
            }
        }
    }
}

private struct MacColorWell: NSViewRepresentable {
    @Binding var color: Color

    func makeCoordinator() -> Coordinator {
        Coordinator(color: $color)
    }

    func makeNSView(context: Context) -> NSColorWell {
        let colorWell = NSColorWell(style: .default)
        colorWell.color = NSColor(color)
        colorWell.target = context.coordinator
        colorWell.action = #selector(Coordinator.colorChanged(_:))
        colorWell.isContinuous = true

        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.attachColorList(PresetColors.list)
        return colorWell
    }

    func updateNSView(_ colorWell: NSColorWell, context: Context) {
        context.coordinator.color = $color
        let resolved = NSColor(color)
        if colorWell.color != resolved {
            colorWell.color = resolved
        }
    }

    final class Coordinator: NSObject {
        var color: Binding<Color>

        init(color: Binding<Color>) {
            self.color = color
        }

        @objc func colorChanged(_ sender: NSColorWell) {
            color.wrappedValue = Color(nsColor: sender.color)
        }
    }

    private enum PresetColors {
        static let list: NSColorList = {
            let list = NSColorList(name: "Kaito Presets")
            list.setColor(NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1), forKey: "Black")
            list.setColor(NSColor(srgbRed: 0.12, green: 0.38, blue: 0.88, alpha: 1), forKey: "Blue")
            list.setColor(NSColor(srgbRed: 0.88, green: 0.16, blue: 0.18, alpha: 1), forKey: "Red")
            list.setColor(NSColor(srgbRed: 0.92, green: 0.35, blue: 0.58, alpha: 1), forKey: "Pink")
            return list
        }()
    }
}
#elseif os(iOS)
private struct SystemFontPicker: UIViewControllerRepresentable {
    @Binding var fontName: String
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(fontName: $fontName, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = true
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        picker.selectedFontDescriptor = UIFontDescriptor(name: fontName, size: 0)
        return picker
    }

    func updateUIViewController(_ picker: UIFontPickerViewController, context: Context) {
        context.coordinator.fontName = $fontName
        context.coordinator.dismiss = dismiss
    }

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        var fontName: Binding<String>
        var dismiss: DismissAction

        init(fontName: Binding<String>, dismiss: DismissAction) {
            self.fontName = fontName
            self.dismiss = dismiss
        }

        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            guard let descriptor = viewController.selectedFontDescriptor else { return }
            fontName.wrappedValue = descriptor.postscriptName
            dismiss()
        }

        func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
            dismiss()
        }
    }
}

private struct AnnotationControls: View {
    @Binding var tool: PDFAnnotationTool?
    @Binding var width: Double
    @Binding var color: Color
    @Binding var fontName: String
    @Binding var textIsBold: Bool
    @Binding var textIsItalic: Bool
    let availableWidth: CGFloat
    let hasUnsavedChanges: Bool
    let savePDFCopy: () -> Bool
    let savePDF: () -> Bool
    @State private var showsFontPicker = false

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                toolButton(.pencil, systemImage: "pencil.tip", help: "显示 iPadOS 标记工具栏")

                toolButton(.textBox, systemImage: "character.textbox", help: "拖出文本框")

                Menu {
                    Button("选择字体…") {
                        showsFontPicker = true
                    }
                    Picker("文字大小", selection: $width) {
                        ForEach([12.0, 14.0, 18.0, 24.0, 32.0, 48.0], id: \.self) { size in
                            Text("\(Int(size)) pt").tag(size)
                        }
                    }
                    Toggle("加粗", isOn: $textIsBold)
                    Toggle("倾斜", isOn: $textIsItalic)
                    ColorPicker("文字颜色", selection: $color, supportsOpacity: false)
                } label: {
                    HStack(spacing: 4) {
                        Text(fontName)
                            .font(.system(size: 12, weight: textIsBold ? .bold : .regular))
                            .italic(textIsItalic)
                            .lineLimit(1)
                        Text("\(Int(width))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(width: max(92, availableWidth - 206), height: 44)
                }
                .glassEffect(
                    .regular.interactive(),
                    in: ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true)
                )
                .disabled(tool != .textBox)
                .help("文本字体与样式")
                .sheet(isPresented: $showsFontPicker) {
                    SystemFontPicker(fontName: $fontName)
                }

                Button { _ = savePDFCopy() } label: {
                    Image(systemName: hasUnsavedChanges ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(IPadToolbarButtonStyle())
                .contentShape(Circle())
                .glassEffect(
                    hasUnsavedChanges
                        ? .regular.tint(Color(red: 0.98, green: 0.78, blue: 0.84)).interactive()
                        : .regular.interactive(),
                    in: Circle()
                )
                .help(hasUnsavedChanges ? "保存为新副本" : "导出 PDF 副本")
                .contextMenu {
                    Button("保存为副本") { _ = savePDFCopy() }
                    Button("保存") { _ = savePDF() }
                }
            }
        }
    }

    private func toolButton(
        _ candidate: PDFAnnotationTool,
        systemImage: String,
        help: String
    ) -> some View {
        let isSelected = tool == candidate
        return Button {
            tool = isSelected ? nil : candidate
        } label: {
            Image(systemName: systemImage)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(IPadToolbarButtonStyle())
        .contentShape(Circle())
        .glassEffect(
            isSelected
                ? .regular.tint(Color(red: 0.98, green: 0.78, blue: 0.84)).interactive()
                : .regular.interactive(),
            in: Circle()
        )
        .help(isSelected ? "再次点按可返回阅读模式" : help)
    }
}
#endif

private struct SidebarResizeHandle: View {
    var body: some View {
        Capsule()
            .fill(.secondary.opacity(0.55))
            .frame(width: 4, height: 42)
            .frame(width: 16, height: 64)
            .contentShape(Rectangle())
            .help("拖动调整答案栏宽度")
    }
}

private struct OllamaChatMessage: Identifiable, Encodable, Equatable {
    let id: UUID
    let role: String
    var content: String

    init(id: UUID = UUID(), role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case role, content
    }
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaChatMessage]
    let stream: Bool
}

private struct OllamaChatChunk: Decodable {
    let message: OllamaChatDelta?
    let done: Bool
}

private struct OllamaChatDelta: Decodable {
    let content: String
}

private enum OllamaChatError: LocalizedError {
    case invalidEndpoint
    case serverStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Ollama 服务地址无效。"
        case .serverStatus(let status):
            "Ollama 返回了 HTTP \(status)。请确认服务已启动且模型已安装。"
        case .emptyResponse:
            "Ollama 没有返回内容。"
        }
    }
}

private struct OllamaAssistantView: View {
    @AppStorage("ollamaEndpoint") private var endpoint = "http://127.0.0.1:11434"
    @AppStorage("ollamaModel") private var model = "gemma3"
    @State private var messages: [OllamaChatMessage] = []
    @State private var draft = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var showsConnectionSettings = false
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            assistantHeader
            Divider().padding(.horizontal, 16)
            conversation
            Divider().padding(.horizontal, 16)
            composer
        }
        .task {
            if messages.isEmpty {
                messages = [
                    OllamaChatMessage(
                        role: "assistant",
                        content: "你好，我是通过 Ollama 在本机运行的 AI 助手。你可以直接询问题目、知识点或解题思路。"
                    )
                ]
            }
        }
    }

    private var assistantHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Ollama AI 助手", systemImage: "sparkles")
                    .font(.headline)

                Spacer()

                Button {
                    messages = [
                        OllamaChatMessage(
                            role: "assistant",
                            content: "新对话已开始。需要我帮你分析什么？"
                        )
                    ]
                    errorMessage = nil
                } label: {
                    Image(systemName: "plus.message")
                }
                .buttonStyle(.plain)
                .help("新对话")
            }

            DisclosureGroup("连接设置", isExpanded: $showsConnectionSettings) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("服务地址", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                    TextField("模型名称", text: $model)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.top, 8)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var conversation: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(messages) { message in
                    messageBubble(message)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageBubble(_ message: OllamaChatMessage) -> some View {
        let isUser = message.role == "user"

        return HStack {
            if isUser {
                Spacer(minLength: 34)
            }

            Text(message.content.isEmpty ? "…" : message.content)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .foregroundStyle(isUser ? .white : .primary)
                .background(
                    isUser
                        ? AnyShapeStyle(Color(red: 0.388, green: 0.482, blue: 1))
                        : AnyShapeStyle(.thinMaterial),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )

            if !isUser {
                Spacer(minLength: 34)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("发送消息…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($isPromptFocused)
                .onSubmit {
                    submit()
                }

            Button(action: submit) {
                Image(systemName: isSending ? "hourglass" : "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(isSending ? "正在生成回答" : "发送")
        }
        .padding(16)
    }

    private func submit() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSending else { return }

        errorMessage = nil
        draft = ""
        let userMessage = OllamaChatMessage(role: "user", content: prompt)
        messages.append(userMessage)
        let requestMessages = messages
        let assistantID = UUID()
        messages.append(OllamaChatMessage(id: assistantID, role: "assistant", content: ""))
        isSending = true

        Task {
            await streamResponse(messages: requestMessages, assistantID: assistantID)
        }
    }

    private func streamResponse(messages requestMessages: [OllamaChatMessage], assistantID: UUID) async {
        do {
            let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: trimmedEndpoint + "/api/chat") else {
                throw OllamaChatError.invalidEndpoint
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                OllamaChatRequest(
                    model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                    messages: requestMessages,
                    stream: true
                )
            )

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw OllamaChatError.serverStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }

            var receivedContent = false
            for try await line in bytes.lines {
                guard !line.isEmpty,
                      let data = line.data(using: .utf8) else {
                    continue
                }
                let chunk = try JSONDecoder().decode(OllamaChatChunk.self, from: data)
                if let content = chunk.message?.content, !content.isEmpty {
                    receivedContent = true
                    if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[index].content += content
                    }
                }
                if chunk.done {
                    break
                }
            }

            if !receivedContent {
                throw OllamaChatError.emptyResponse
            }
        } catch {
            messages.removeAll(where: { $0.id == assistantID && $0.content.isEmpty })
            errorMessage = error.localizedDescription
        }
        isSending = false
        isPromptFocused = true
    }
}

private struct AnswerSidebar: View {
    let documentTitle: String
    let currentPage: Int
    let pageCount: Int
    @Binding var questions: [QuestionRecord]
    @Binding var isReviewMode: Bool
    let showsLLMChat: Bool
    @Binding var showsAIHistory: Bool
    let document: PDFDocument
    @Binding var selectedAIPageIndices: [Int]
    @Binding var isSelectingAIPages: Bool
    @Binding var maximumAISelectedPages: Int
    let acceptsReviewShortcuts: Bool
    let onNavigateToQuestion: (QuestionRecord) -> Void
    let onQuestionUpdated: () -> Void
    @State private var flashOpacity: Double = 0.0
    @State private var editingQuestionId: UUID?
    @State private var editQuestionNumText: String = ""
    @FocusState private var isQuestionNumFocused: Bool
    @State private var reviewFilter: ReviewFilter = .all
    @State private var expandedNoteID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsLLMChat {
                AIChatView(
                    showsHistory: $showsAIHistory,
                    document: document,
                    selectedPageIndices: $selectedAIPageIndices,
                    isSelectingPages: $isSelectingAIPages,
                    maximumSelectedPages: $maximumAISelectedPages
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                Text(documentTitle)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("第 \(currentPage) 页，共 \(pageCount) 页")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(22)

            if isReviewMode {
                ReviewModeHeader(
                    filter: $reviewFilter,
                    correctCount: correctCount,
                    answeredCount: reviewedCount,
                    totalCount: activeQuestions.count
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            Divider().padding(.horizontal, 16)

            // 答题列表区域
            if questions.isEmpty {
                ContentUnavailableView {
                    Label("答题卡已准备好", systemImage: "square.and.pencil")
                } description: {
                    Text("在 PDF 任意位置双击，即可标记题目与答案。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredQuestionIDs, id: \.self) { id in
                            if let index = questions.firstIndex(where: { $0.id == id }) {
                                questionCard(for: $questions[index])
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isReviewMode && allCorrectAnswersEntered {
                ReviewSummary(
                    correctCount: correctCount,
                    incorrectCount: incorrectCount,
                    totalCount: activeQuestions.count
                )
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            }

            Divider().padding(.horizontal, 16)

            SidebarTimerSection(onTimeElapsed: triggerFlash)
                .padding(16)
        }
        .glassEffect(
            .regular,
            in: ConcentricRectangle(corners: .concentric(minimum: 24), isUniform: true)
        )
        .background {
            if !showsLLMChat && isReviewMode && acceptsReviewShortcuts {
                NumericOptionShortcuts(action: enterNextCorrectAnswer)
            }
        }
        .overlay {
            ConcentricRectangle(corners: .concentric(minimum: 24), isUniform: true)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.98, green: 0.76, blue: 0.84),
                            Color(red: 0.95, green: 0.60, blue: 0.75)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .opacity(flashOpacity)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func questionCard(for questionBinding: Binding<QuestionRecord>) -> some View {
        let question = questionBinding.wrappedValue
        let isEditingThis = editingQuestionId == question.id

        ZStack {
            HStack(spacing: 10) {
                // 左侧题号
                if isEditingThis {
                    TextField("\(question.questionNumber)", text: $editQuestionNumText)
                        .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .frame(width: 36, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color(red: 0.9, green: 0.4, blue: 0.57), lineWidth: 1.2)
                        )
                        .focused($isQuestionNumFocused)
                        .onSubmit {
                            if let val = Int(editQuestionNumText.trimmingCharacters(in: .whitespacesAndNewlines)), val > 0 {
                                questionBinding.wrappedValue.questionNumber = val
                                onQuestionUpdated()
                            }
                            editingQuestionId = nil
                            isQuestionNumFocused = false
                        }
                } else {
                    Text("\(question.questionNumber)")
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(question.isMarkDeleted ? .secondary : .primary)
                        .frame(minWidth: 30, alignment: .center)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            editQuestionNumText = "\(question.questionNumber)"
                            editingQuestionId = question.id
                            isQuestionNumFocused = true
                        }
                        .onTapGesture(count: 1) {
                            onNavigateToQuestion(question)
                        }
                        .help("单击在 PDF 中定位，双击修改题号")
                }

                // 竖向分割线
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1, height: 22)

                if isReviewMode {
                    ReviewAnswerRow(
                        selectedOption: question.selectedOption,
                        correctOption: question.correctOption,
                        isDisabled: question.isMarkDeleted,
                        note: questionBinding.note,
                        isNotePresented: Binding(
                            get: { expandedNoteID == question.id },
                            set: { expandedNoteID = $0 ? question.id : nil }
                        ),
                        onNoteChanged: onQuestionUpdated
                    )
                } else {
                    HStack(spacing: 6) {
                        ForEach(1...4, id: \.self) { option in
                            QuestionOptionButton(
                                option: option,
                                isSelected: question.selectedOption == option,
                                isDisabled: question.isMarkDeleted,
                                action: {
                                    questionBinding.wrappedValue.selectedOption = option
                                    onQuestionUpdated()
                                }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .opacity(question.isMarkDeleted ? 0.45 : 1.0)

            // 删除后的划线
            if question.isMarkDeleted {
                Rectangle()
                    .fill(Color.secondary.opacity(0.65))
                    .frame(height: 1.5)
                    .padding(.horizontal, 8)
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                questions.removeAll(where: { $0.id == question.id })
                onQuestionUpdated()
            } label: {
                Label("删除答题记录", systemImage: "trash")
            }
        }
    }

    private var activeQuestions: [QuestionRecord] {
        questions.filter { !$0.isMarkDeleted }
    }

    private var reviewedCount: Int {
        activeQuestions.filter { $0.correctOption != nil }.count
    }

    private var correctCount: Int {
        activeQuestions.filter {
            guard let selected = $0.selectedOption, let correct = $0.correctOption else { return false }
            return selected == correct
        }.count
    }

    private var incorrectCount: Int {
        activeQuestions.filter {
            guard let selected = $0.selectedOption, let correct = $0.correctOption else { return false }
            return selected != correct
        }.count
    }

    private var allCorrectAnswersEntered: Bool {
        !activeQuestions.isEmpty && reviewedCount == activeQuestions.count
    }

    private var filteredQuestionIDs: [UUID] {
        activeQuestions
            .filter { question in
                guard isReviewMode, question.correctOption != nil else { return true }
                switch reviewFilter {
                case .all:
                    return true
                case .incorrect:
                    return question.selectedOption != question.correctOption
                case .correct:
                    return question.selectedOption == question.correctOption
                }
            }
            .sorted { $0.questionNumber < $1.questionNumber }
            .map(\.id)
    }

    private func enterNextCorrectAnswer(_ option: Int) {
        guard isReviewMode,
              let index = questions.indices
                .filter({ !questions[$0].isMarkDeleted && questions[$0].correctOption == nil })
                .min(by: { questions[$0].questionNumber < questions[$1].questionNumber })
        else { return }

        questions[index].correctOption = option
        onQuestionUpdated()
    }

    private func triggerFlash() {
        Task { @MainActor in
            // 第 1 下闪烁：快速渐变为淡粉色然后淡出
            withAnimation(.easeIn(duration: 0.18)) {
                flashOpacity = 0.52
            }
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.easeOut(duration: 0.22)) {
                flashOpacity = 0.0
            }
            try? await Task.sleep(for: .milliseconds(220))

            // 第 2 下闪烁：再次快速渐变为淡粉色然后淡出
            withAnimation(.easeIn(duration: 0.18)) {
                flashOpacity = 0.52
            }
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.easeOut(duration: 0.30)) {
                flashOpacity = 0.0
            }
        }
    }
}

private enum ReviewFilter: String, CaseIterable, Identifiable {
    case all = "总览"
    case incorrect = "错误"
    case correct = "正确"

    var id: Self { self }
}

private struct ReviewModeHeader: View {
    @Binding var filter: ReviewFilter
    let correctCount: Int
    let answeredCount: Int
    let totalCount: Int

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Label("对答案模式", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
                Spacer()
                Text("已录入 \(answeredCount)/\(totalCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Picker("筛选答案", selection: $filter) {
                ForEach(ReviewFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

private struct ReviewAnswerRow: View {
    let selectedOption: Int?
    let correctOption: Int?
    let isDisabled: Bool
    @Binding var note: String
    @Binding var isNotePresented: Bool
    let onNoteChanged: () -> Void

    private var isCorrect: Bool? {
        guard let selectedOption, let correctOption else { return nil }
        return selectedOption == correctOption
    }

    private var resultColor: Color {
        guard let isCorrect else { return .green }
        return isCorrect ? .green : .red
    }

    var body: some View {
        HStack(spacing: 7) {
            answerChip(selectedOption, placeholder: "—")
            divider
            answerChip(correctOption, placeholder: "?")

            if let isCorrect {
                divider
                Button {
                    isNotePresented = true
                } label: {
                    Text(isCorrect ? "O" : "X")
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 27, height: 27)
                        .background(resultColor, in: Circle())
                }
                .buttonStyle(.plain)
                .help("打开本题笔记")
                .popover(isPresented: $isNotePresented, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(isCorrect ? "正确答案笔记" : "错题笔记")
                            .font(.headline)
                        TextEditor(text: $note)
                            .font(.body)
                            .frame(minWidth: 300, minHeight: 150)
                            .onChange(of: note) { _, _ in onNoteChanged() }
                        Text("笔记将随 PDF 保存。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
            }
        }
        .foregroundStyle(isCorrect == nil ? Color.primary : resultColor)
        .opacity(isDisabled ? 0.45 : 1)
    }

    private func answerChip(_ option: Int?, placeholder: String) -> some View {
        Text(option.map(String.init) ?? placeholder)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .frame(minWidth: 27, minHeight: 27)
            .background(
                resultColor.opacity(option == nil ? 0.12 : 0.9),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .foregroundStyle(option == nil ? Color.secondary : Color.white)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 1, height: 20)
    }
}

private struct ReviewSummary: View {
    let correctCount: Int
    let incorrectCount: Int
    let totalCount: Int

    private var accuracy: Int {
        guard totalCount > 0 else { return 0 }
        return Int((Double(correctCount) / Double(totalCount) * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(accuracy)%")
                    .font(.system(size: 30, weight: .black, design: .rounded).monospacedDigit())
                Text("正确率")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Label("\(incorrectCount)/\(totalCount)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Label("\(correctCount)/\(totalCount)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.subheadline.weight(.bold).monospacedDigit())
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct QuestionOptionButton: View {
    let option: Int
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(option)")
                .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(borderColor, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var textColor: Color {
        if isDisabled {
            return .secondary
        }
        return isSelected ? .white : .primary.opacity(0.75)
    }

    private var backgroundColor: Color {
        if isDisabled {
            return Color.primary.opacity(0.04)
        }
        return isSelected ? Color(red: 0.18, green: 0.72, blue: 0.38) : Color.primary.opacity(0.04)
    }

    private var borderColor: Color {
        if isSelected && !isDisabled {
            return Color(red: 0.15, green: 0.65, blue: 0.32).opacity(0.5)
        }
        return Color.white.opacity(0.12)
    }
}

private struct SidebarTimerSection: View {
    var onTimeElapsed: () -> Void = {}
    @State private var configuredSeconds: Int = 40 * 60
    @State private var remainingSeconds: Int = 40 * 60
    @State private var isRunning = false
    @State private var isPaused = false
    @State private var timerTask: Task<Void, Never>?
    @State private var historyDurations: [Int] = [60 * 60, 45 * 60, 10 * 60]
    @State private var isEditing = false
    @State private var editTimeText = "40:00"
    @FocusState private var isTimeFieldFocused: Bool
    @State private var editingHistoryIndex: Int?
    @State private var editHistoryText = ""
    @FocusState private var isHistoryFieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // 主计时器（最高、最大）
            mainTimerCard

            // 历史记录（单行三个小按钮）
            historyTimersList
        }
        .onDisappear {
            timerTask?.cancel()
        }
    }

    // MARK: - 主计时器卡片
    private var mainTimerCard: some View {
        HStack(alignment: .center, spacing: 10) {
            if isEditing {
                TextField("40:00", text: $editTimeText)
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .textFieldStyle(.plain)
                    .frame(width: 82)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(red: 0.9, green: 0.4, blue: 0.57), lineWidth: 1.5)
                    )
                    .focused($isTimeFieldFocused)
                    .onChange(of: editTimeText) { _, newValue in
                        let formatted = formatTimeEntry(newValue)
                        if formatted != newValue {
                            editTimeText = formatted
                        }
                    }
                    .onSubmit { startTimer() }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatTime(remainingSeconds))
                        .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(
                            isRunning && remainingSeconds <= 60 && remainingSeconds > 0
                                ? Color(red: 0.92, green: 0.25, blue: 0.25)
                                : (isRunning && isPaused ? .secondary : .primary)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            startEditing()
                        }
                        .help("双击修改时间（最多99:99）")

                    Text(isRunning ? (isPaused ? "已暂停" : "计时中…") : "双击修改时间")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.75))
                }
            }

            Spacer(minLength: 4)

            // 开始 / 暂停 & 取消 按钮
            timerActionButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background {
            GeometryReader { geo in
                let progress = configuredSeconds > 0
                    ? CGFloat(remainingSeconds) / CGFloat(configuredSeconds)
                    : 0
                let clampedProgress = min(max(progress, 0), 1)

                ZStack(alignment: .leading) {
                    // 底层微透底色
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.04))

                    // 时间流动粉色填充（折算剩余时间比例，由右向左减少）
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.98, green: 0.78, blue: 0.84).opacity(0.55),
                                    Color(red: 0.94, green: 0.68, blue: 0.78).opacity(0.42)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * clampedProgress)
                        .animation(isRunning && !isPaused ? .linear(duration: 1.0) : .easeInOut(duration: 0.25), value: remainingSeconds)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isRunning
                        ? Color(red: 0.9, green: 0.4, blue: 0.57).opacity(0.35)
                        : Color.white.opacity(0.16),
                    lineWidth: isRunning ? 1 : 0.6
                )
        )
    }

    // MARK: - 按钮区域（开始 或 分割为 暂停 + 取消）
    @ViewBuilder
    private var timerActionButtons: some View {
        HStack(spacing: 5) {
            if !isRunning {
                Button(action: startTimer) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("开始")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 74, height: 34)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.95, green: 0.45, blue: 0.62),
                                Color(red: 0.88, green: 0.32, blue: 0.52)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                    .shadow(color: Color(red: 0.9, green: 0.35, blue: 0.55).opacity(0.3), radius: 3, y: 1.5)
                }
                .buttonStyle(.plain)
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .scale.combined(with: .opacity)
                ))
            } else {
                // 暂停 / 继续 按钮（左半边）
                Button(action: togglePause) {
                    HStack(spacing: 3) {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(isPaused ? "继续" : "暂停")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(isPaused ? Color(red: 0.88, green: 0.32, blue: 0.52) : Color.primary)
                    .frame(width: 54, height: 34)
                    .background(
                        isPaused
                            ? Color(red: 0.98, green: 0.78, blue: 0.84).opacity(0.5)
                            : Color.primary.opacity(0.08),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .stroke(
                                isPaused
                                    ? Color(red: 0.9, green: 0.4, blue: 0.57).opacity(0.4)
                                    : Color.white.opacity(0.15),
                                lineWidth: 0.5
                            )
                    )
                }
                .buttonStyle(.plain)
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

                // 取消 按钮（右半边）
                Button(action: cancelTimer) {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("取消")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 54, height: 34)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: isRunning)
    }

    // MARK: - 历史记录计时器列表（单行三个小按钮）
    private var historyTimersList: some View {
        HStack(spacing: 6) {
            ForEach(0..<historyDurations.count, id: \.self) { index in
                historyTimerButton(at: index)
            }
        }
    }

    @ViewBuilder
    private func historyTimerButton(at index: Int) -> some View {
        let duration = historyDurations[index]
        if isSystemClockPreset(index) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let appearance = systemClockAppearance(at: context.date)
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [appearance.topColor, appearance.bottomColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(appearance.usesLightText ? 0.28 : 0.18), lineWidth: 0.5)

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(appearance.foregroundColor.opacity(0.82))

                        Text(context.date, format: .dateTime.hour().minute())
                            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(appearance.foregroundColor)
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .accessibilityLabel("系统时间")
            }
        } else if editingHistoryIndex == index {
            HStack(spacing: 2) {
                TextField("60:00", text: $editHistoryText)
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(red: 0.9, green: 0.4, blue: 0.57), lineWidth: 1.2)
                    )
                    .focused($isHistoryFieldFocused)
                    .onChange(of: editHistoryText) { _, newValue in
                        let formatted = formatTimeEntry(newValue)
                        if formatted != newValue {
                            editHistoryText = formatted
                        }
                    }
                    .onSubmit { commitEditingHistory(at: index) }

                Button(action: { commitEditingHistory(at: index) }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 0.9, green: 0.4, blue: 0.57))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.035))

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)

                HStack(spacing: 3) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(formatTime(duration))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary.opacity(0.88))
                }
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                startEditingHistory(at: index)
            }
            .onTapGesture(count: 1) {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.76)) {
                    applyDuration(duration)
                }
            }
            .help("点击应用（\(formatTime(duration))），双击可修改")
        }
    }

    private func isSystemClockPreset(_ index: Int) -> Bool {
#if os(iOS)
        index == 2
#else
        false
#endif
    }

    private struct SystemClockAppearance {
        let topColor: Color
        let bottomColor: Color
        let foregroundColor: Color
        let usesLightText: Bool
    }

    private struct ClockRGB {
        let red: Double
        let green: Double
        let blue: Double

        func interpolated(to other: ClockRGB, progress: Double) -> ClockRGB {
            ClockRGB(
                red: red + (other.red - red) * progress,
                green: green + (other.green - green) * progress,
                blue: blue + (other.blue - blue) * progress
            )
        }

        var color: Color {
            Color(red: red, green: green, blue: blue)
        }

        var luminance: Double {
            0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
    }

    private func systemClockAppearance(at date: Date) -> SystemClockAppearance {
        let calendar = Calendar.autoupdatingCurrent
        let startOfDay = calendar.startOfDay(for: date)
        let seconds = date.timeIntervalSince(startOfDay)
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 172)

        // 用日期平滑推算季节性的昼长；不请求定位权限也能让日出、日落随季节缓慢变化。
        let seasonalPosition = cos(2 * Double.pi * (dayOfYear - 172) / 365.2425)
        let daylightHours = 12 + 2.25 * seasonalPosition
        let sunrise = (12 - daylightHours / 2) * 3_600
        let sunset = (12 + daylightHours / 2) * 3_600
        let solarNoon = (sunrise + sunset) / 2

        let night = ClockRGB(red: 0.08, green: 0.18, blue: 0.40)
        let twilight = ClockRGB(red: 0.20, green: 0.34, blue: 0.61)
        let dawn = ClockRGB(red: 0.62, green: 0.80, blue: 0.94)
        let daylight = ClockRGB(red: 0.55, green: 0.78, blue: 0.94)
        let noon = ClockRGB(red: 0.34, green: 0.67, blue: 0.91)
        let sunsetOrange = ClockRGB(red: 0.94, green: 0.50, blue: 0.27)

        let anchors: [(time: Double, top: ClockRGB, bottom: ClockRGB)] = [
            (0, night, ClockRGB(red: 0.12, green: 0.27, blue: 0.52)),
            (max(0, sunrise - 5_400), twilight, dawn),
            (sunrise, dawn, ClockRGB(red: 0.70, green: 0.86, blue: 0.97)),
            ((sunrise + solarNoon) / 2, daylight, ClockRGB(red: 0.67, green: 0.85, blue: 0.97)),
            (solarNoon, noon, ClockRGB(red: 0.51, green: 0.76, blue: 0.94)),
            ((solarNoon + sunset) / 2, daylight, ClockRGB(red: 0.72, green: 0.86, blue: 0.96)),
            (sunset, sunsetOrange, ClockRGB(red: 0.98, green: 0.69, blue: 0.42)),
            (min(86_400, sunset + 5_400), twilight, ClockRGB(red: 0.16, green: 0.28, blue: 0.54)),
            (86_400, night, ClockRGB(red: 0.12, green: 0.27, blue: 0.52))
        ]

        let nextIndex = anchors.firstIndex(where: { seconds <= $0.time }) ?? anchors.count - 1
        let upper = anchors[max(nextIndex, 1)]
        let lower = anchors[max(nextIndex - 1, 0)]
        let duration = max(upper.time - lower.time, 1)
        let linearProgress = min(max((seconds - lower.time) / duration, 0), 1)
        let progress = linearProgress * linearProgress * (3 - 2 * linearProgress)
        let top = lower.top.interpolated(to: upper.top, progress: progress)
        let bottom = lower.bottom.interpolated(to: upper.bottom, progress: progress)
        let usesLightText = (top.luminance + bottom.luminance) / 2 < 0.48

        return SystemClockAppearance(
            topColor: top.color,
            bottomColor: bottom.color,
            foregroundColor: usesLightText ? .white : Color(red: 0.06, green: 0.17, blue: 0.29),
            usesLightText: usesLightText
        )
    }

    // MARK: - 逻辑方法
    private func startTimer() {
        if isEditing {
            commitEditing()
        }
        if remainingSeconds == 0 {
            remainingSeconds = configuredSeconds
        }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            isRunning = true
            isPaused = false
        }
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard isRunning else { break }
                if !isPaused {
                    if remainingSeconds > 0 {
                        remainingSeconds -= 1
                    }
                    if remainingSeconds == 0 {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                            isRunning = false
                            isPaused = false
                        }
#if os(macOS)
                        NSSound.beep()
#endif
                        onTimeElapsed()
                        break
                    }
                }
            }
        }
    }

    private func togglePause() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isPaused.toggle()
        }
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            isRunning = false
            isPaused = false
            remainingSeconds = configuredSeconds
        }
    }

    private func applyDuration(_ duration: Int) {
        cancelTimer()
        configuredSeconds = duration
        remainingSeconds = duration
    }

    private func startEditing() {
        timerTask?.cancel()
        timerTask = nil
        isRunning = false
        isPaused = false
        editTimeText = formatTime(configuredSeconds)
        isEditing = true
        isTimeFieldFocused = true
    }

    private func commitEditing() {
        if let parsed = parseTimeString(editTimeText), parsed > 0 {
            configuredSeconds = parsed
            remainingSeconds = parsed
        }
        isEditing = false
        isTimeFieldFocused = false
    }

    private func startEditingHistory(at index: Int) {
        editHistoryText = formatTime(historyDurations[index])
        editingHistoryIndex = index
        isHistoryFieldFocused = true
    }

    private func commitEditingHistory(at index: Int) {
        if let parsed = parseTimeString(editHistoryText), parsed > 0 {
            historyDurations[index] = parsed
        }
        editingHistoryIndex = nil
        isHistoryFieldFocused = false
    }

    private func formatTime(_ totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func formatTimeEntry(_ input: String) -> String {
        let sanitized = input.filter { $0.isNumber || $0 == ":" }
        if let colonIndex = sanitized.firstIndex(of: ":") {
            let minutes = sanitized[..<colonIndex].filter(\.isNumber).prefix(2)
            let secondsStart = sanitized.index(after: colonIndex)
            let seconds = sanitized[secondsStart...].filter(\.isNumber).prefix(2)
            return "\(minutes):\(seconds)"
        }

        let digits = String(sanitized.filter(\.isNumber).prefix(4))
        guard digits.count >= 2 else { return digits }
        guard digits.count > 2 else { return digits + ":" }

        let splitIndex = digits.index(digits.startIndex, offsetBy: 2)
        return "\(digits[..<splitIndex]):\(digits[splitIndex...])"
    }

    private func parseTimeString(_ input: String) -> Int? {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.contains(":") {
            let parts = clean.split(separator: ":")
            if parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]) {
                let minClamped = min(max(m, 0), 99)
                let secClamped = min(max(s, 0), 99)
                return minClamped * 60 + secClamped
            } else if parts.count == 1, let m = Int(parts[0]) {
                let minClamped = min(max(m, 0), 99)
                return minClamped * 60
            }
        } else if let val = Int(clean) {
            if val > 99 {
                let m = min(val / 100, 99)
                let s = min(val % 100, 99)
                return m * 60 + s
            } else {
                return min(val, 99) * 60
            }
        }
        return nil
    }
}

private final class PDFReaderCoordinator: NSObject, PDFViewDelegate {
    var currentPage: Binding<Int>
    var zoom: Binding<Double>
    var isZoomLocked = false
    var lockedScale: CGFloat = 1
    var isApplyingScale = false
    var onDoubleTap: (Int, CGPoint, CGPoint) -> Void = { _, _, _ in }
    var onMarkerDeleted: (UUID) -> Void = { _ in }
    weak var pdfView: PDFView?
#if os(iOS)
    weak var iPadReaderView: IPadPDFReaderView?
#endif
#if os(macOS)
    var annotationTool: PDFAnnotationTool?
    var annotationWidth = 2.5
    var annotationChanged: () -> Void = {}
#elseif os(iOS)
    var annotationTool: PDFAnnotationTool?
    var annotationWidth = 2.5
    var annotationColor = UIColor.label
    var annotationFontName = "Helvetica"
    var annotationTextIsBold = false
    var annotationTextIsItalic = false
    var annotationChanged: () -> Void = {}
    private let toolPicker = PKToolPicker()
    private weak var activeCanvas: PKCanvasView?
    private weak var textBoxRecognizer: UIPanGestureRecognizer?
    private var textBoxStartPoint: CGPoint?
    private var canvasesByPage: [ObjectIdentifier: PKCanvasView] = [:]
    private var pagesByCanvas: [ObjectIdentifier: PDFPage] = [:]
    private var overlaysByPage: [ObjectIdentifier: PDFPageAnnotationOverlayView] = [:]
    private var pagesByOverlay: [ObjectIdentifier: PDFPage] = [:]
    private var committedCanvasAnnotations: [(PDFPage, PDFAnnotation)] = []
#endif

    init(currentPage: Binding<Int>, zoom: Binding<Double>) {
        self.currentPage = currentPage
        self.zoom = zoom
    }

    func observe(_ pdfView: PDFView) {
        self.pdfView = pdfView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: pdfView
        )
#if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(commitCanvasDrawingsNotification(_:)),
            name: .commitKaitoCanvasDrawings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(restoreEditingOverlaysNotification(_:)),
            name: .restoreKaitoEditingOverlays,
            object: nil
        )
#endif
    }

    func navigateToQuestion(_ question: QuestionRecord) {
#if os(iOS)
        if let iPadReaderView {
            iPadReaderView.goToPage(question.pageIndex)
            return
        }
#endif
        guard let pdfView,
              let document = pdfView.document,
              let page = document.page(at: question.pageIndex) else { return }

        let dest = PDFDestination(page: page, at: CGPoint(x: question.pointX, y: question.pointY))
        pdfView.go(to: dest)

        for annotation in page.annotations {
            if let marker = annotation as? KaitoQuestionAnnotation, marker.record.id == question.id {
                Task { @MainActor in
                    for _ in 0..<2 {
                        marker.flashOpacity = 0.85
                        pdfView.setNeedsDisplay(marker.bounds)
                        try? await Task.sleep(for: .milliseconds(180))
                        marker.flashOpacity = 0.0
                        pdfView.setNeedsDisplay(marker.bounds)
                        try? await Task.sleep(for: .milliseconds(180))
                    }
                }
                break
            }
        }
    }

    @objc private func pageChanged(_ notification: Notification) {
        guard let pdfView = notification.object as? PDFView,
              let document = pdfView.document,
              let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        guard index != currentPage.wrappedValue else { return }
        DispatchQueue.main.async { self.currentPage.wrappedValue = index }
    }

    @objc private func scaleChanged(_ notification: Notification) {
        guard !isApplyingScale,
              let pdfView = notification.object as? PDFView else { return }
        let fitScale = pdfView.scaleFactorForSizeToFit
        guard fitScale > 0 else { return }
        let relativeZoom = min(max(pdfView.scaleFactor / fitScale, 0.65), 2.2)
        guard abs(relativeZoom - zoom.wrappedValue) > 0.01 else { return }
        DispatchQueue.main.async { self.zoom.wrappedValue = relativeZoom }
    }

    func pdfViewWillChangeScaleFactor(_ sender: PDFView, toScale scale: CGFloat) -> CGFloat {
        return isZoomLocked ? lockedScale : scale
    }

#if os(iOS)
    func overlay(for page: PDFPage) -> PDFPageAnnotationOverlayView {
        let pageIdentifier = ObjectIdentifier(page)
        if let overlay = overlaysByPage[pageIdentifier] {
            return overlay
        }

        let overlay = PDFPageAnnotationOverlayView(frame: .zero)
        let canvas = overlay.canvasView
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.bounces = false
        canvas.delaysContentTouches = false
        canvas.canCancelContentTouches = false
        canvas.delegate = self
        overlaysByPage[pageIdentifier] = overlay
        pagesByOverlay[ObjectIdentifier(overlay)] = page
        canvasesByPage[pageIdentifier] = canvas
        pagesByCanvas[ObjectIdentifier(canvas)] = page
        prepareOverlay(overlay)
        return overlay
    }

    func updateAnnotationTool(
        _ tool: PDFAnnotationTool?,
        width: Double,
        color: UIColor,
        fontName: String,
        isBold: Bool,
        isItalic: Bool
    ) {
        let didChange = annotationTool != tool
            || abs(annotationWidth - width) > 0.001
            || !annotationColor.isEqual(color)
            || annotationFontName != fontName
            || annotationTextIsBold != isBold
            || annotationTextIsItalic != isItalic
        guard didChange else { return }

        let previousTool = annotationTool
        annotationTool = tool
        annotationWidth = width
        annotationColor = color
        annotationFontName = fontName
        annotationTextIsBold = isBold
        annotationTextIsItalic = isItalic
        for canvas in canvasesByPage.values {
            guard let page = pagesByCanvas[ObjectIdentifier(canvas)],
                  let overlay = overlaysByPage[ObjectIdentifier(page)] else { continue }
            configure(overlay)
        }
        if tool == .pencil, previousTool != tool {
            annotationChanged()
        }
        updateTextBoxRecognizer()
    }

    private func configure(_ overlay: PDFPageAnnotationOverlayView) {
        let canvas = overlay.canvasView
        let isDrawing = annotationTool == .pencil
        let isCreatingTextBox = annotationTool == .textBox
        overlay.isUserInteractionEnabled = isDrawing || isCreatingTextBox
        canvas.drawingPolicy = .pencilOnly
        canvas.isUserInteractionEnabled = isDrawing
        canvas.drawingGestureRecognizer.isEnabled = isDrawing
        overlay.gestureRecognizers?
            .compactMap { $0 as? UIPanGestureRecognizer }
            .filter { $0.name == "KaitoPageTextBoxPan" }
            .forEach { $0.isEnabled = isCreatingTextBox }

        switch annotationTool {
        case .pencil:
            activeCanvas = canvas
            toolPicker.addObserver(canvas)
            canvas.pencilKitResponderState.activeToolPicker = toolPicker
            canvas.pencilKitResponderState.toolPickerVisibility = .visible
        case .textBox:
            canvas.pencilKitResponderState.toolPickerVisibility = .inactive
        case nil:
            canvas.pencilKitResponderState.toolPickerVisibility = .inactive
            break
        }

        if isDrawing {
            DispatchQueue.main.async { [weak canvas] in
                guard let canvas, canvas.window != nil else { return }
                canvas.contentSize = canvas.bounds.size
                canvas.drawingGestureRecognizer.isEnabled = true
                canvas.becomeFirstResponder()
            }
        }
    }

    func installTextBoxRecognizer(on view: PDFView) {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleTextBoxPan(_:)))
        recognizer.name = "KaitoTextBoxPan"
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.isEnabled = false
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = true
        view.addGestureRecognizer(recognizer)
        textBoxRecognizer = recognizer
    }

    private func updateTextBoxRecognizer() {
        textBoxRecognizer?.isEnabled = false
        guard let pdfView else { return }
        let isCreatingTextBox = annotationTool == .textBox
        pdfView.descendantScrollViews.forEach { scrollView in
            guard !(scrollView is PKCanvasView) else {
                scrollView.isScrollEnabled = false
                return
            }
            scrollView.isScrollEnabled = !isCreatingTextBox
        }
        if annotationTool == .pencil {
            pdfView.isInMarkupMode = false
            pdfView.pencilKitResponderState.activeToolPicker = toolPicker
            pdfView.pencilKitResponderState.toolPickerVisibility = .visible
        } else {
            pdfView.isInMarkupMode = false
            pdfView.pencilKitResponderState.toolPickerVisibility = .inactive
        }
    }

    @objc private func handleTextBoxPan(_ recognizer: UIPanGestureRecognizer) {
        guard annotationTool == .textBox, let pdfView else { return }
        let point = recognizer.location(in: pdfView)
        switch recognizer.state {
        case .began:
            textBoxStartPoint = point
        case .ended:
            guard let start = textBoxStartPoint else { return }
            textBoxStartPoint = nil
            let viewRect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
            guard viewRect.width >= 24, viewRect.height >= 18,
                  let page = pdfView.page(for: CGPoint(x: viewRect.midX, y: viewRect.midY), nearest: false) else { return }
            let first = pdfView.convert(viewRect.origin, to: page)
            let opposite = pdfView.convert(CGPoint(x: viewRect.maxX, y: viewRect.maxY), to: page)
            let pageRect = CGRect(
                x: min(first.x, opposite.x),
                y: min(first.y, opposite.y),
                width: abs(opposite.x - first.x),
                height: abs(opposite.y - first.y)
            )
            presentTextEditor(for: page, bounds: pageRect)
        default:
            break
        }
    }

    private func presentTextEditor(for page: PDFPage, bounds: CGRect) {
        guard let presenter = pdfView?.window?.rootViewController?.topmostPresentedViewController else { return }
        let alert = UIAlertController(title: "文本框", message: "输入要写入 PDF 的文字", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "文字"
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "添加", style: .default) { [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text, !text.isEmpty else { return }
            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.color = .clear
            annotation.fontColor = self.annotationColor
            annotation.font = self.textAnnotationFont()
            annotation.alignment = .left
            annotation.userName = "KaitoTextBox"
            page.addAnnotation(annotation)
            self.annotationChanged()
            self.pdfView?.setNeedsDisplay()
        })
        presenter.present(alert, animated: true)
    }

    private func textAnnotationFont() -> UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if annotationTextIsBold { traits.insert(.traitBold) }
        if annotationTextIsItalic { traits.insert(.traitItalic) }
        let base = UIFont(name: annotationFontName, size: annotationWidth) ?? .systemFont(ofSize: annotationWidth)
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: annotationWidth)
    }

    func prepareOverlay(_ overlay: PDFPageAnnotationOverlayView) {
        let canvas = overlay.canvasView
        canvas.contentSize = canvas.bounds.size
        if !(overlay.gestureRecognizers ?? []).contains(where: { $0.name == "KaitoPageTextBoxPan" }) {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePageTextBoxPan(_:)))
            recognizer.name = "KaitoPageTextBoxPan"
            recognizer.minimumNumberOfTouches = 1
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = true
            overlay.addGestureRecognizer(recognizer)
        }
        configure(overlay)
    }

    @objc private func handlePageTextBoxPan(_ recognizer: UIPanGestureRecognizer) {
        guard annotationTool == .textBox,
              let overlay = recognizer.view as? PDFPageAnnotationOverlayView,
              let page = pagesByOverlay[ObjectIdentifier(overlay)],
              let pdfView else { return }
        let point = recognizer.location(in: overlay)
        switch recognizer.state {
        case .began:
            textBoxStartPoint = point
            overlay.showTextBoxPreview(from: point, to: point)
        case .changed:
            guard let start = textBoxStartPoint else { return }
            overlay.showTextBoxPreview(from: start, to: point)
        case .ended:
            guard let start = textBoxStartPoint else { return }
            textBoxStartPoint = nil
            overlay.hideTextBoxPreview()
            let firstInPDFView = pdfView.convert(start, from: overlay)
            let oppositeInPDFView = pdfView.convert(point, from: overlay)
            let first = pdfView.convert(firstInPDFView, to: page)
            let opposite = pdfView.convert(oppositeInPDFView, to: page)
            let pageRect = CGRect(
                x: min(first.x, opposite.x),
                y: min(first.y, opposite.y),
                width: abs(opposite.x - first.x),
                height: abs(opposite.y - first.y)
            )
            guard pageRect.width >= 12, pageRect.height >= 12 else { return }
            presentTextEditor(for: page, bounds: pageRect)
        case .cancelled, .failed:
            textBoxStartPoint = nil
            overlay.hideTextBoxPreview()
        default:
            break
        }
    }

    func commitCanvasDrawingsToPDF() {
        if let iPadReaderView {
            iPadReaderView.commitPendingEditsToPDF()
            return
        }
        guard let pdfView else { return }

        for (page, annotation) in committedCanvasAnnotations {
            page.removeAnnotation(annotation)
        }
        committedCanvasAnnotations.removeAll(keepingCapacity: true)

        for canvas in canvasesByPage.values {
            guard let page = pagesByCanvas[ObjectIdentifier(canvas)] else { continue }
            let pageBounds = page.bounds(for: .mediaBox)

            for stroke in canvas.drawing.strokes {
                let points = stroke.path.map { strokePoint -> CGPoint in
                    let pdfPoint = pdfView.convert(strokePoint.location, from: canvas)
                    return pdfView.convert(pdfPoint, to: page)
                }
                guard let first = points.first, points.count > 1 else { continue }

                let path = UIBezierPath()
                path.move(to: CGPoint(x: first.x - pageBounds.minX, y: first.y - pageBounds.minY))
                for point in points.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x - pageBounds.minX, y: point.y - pageBounds.minY))
                }

                let annotation = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
                let border = PDFBorder()
                let strokeWidth = Double(stroke.path.first?.size.width ?? CGFloat(annotationWidth))
                border.lineWidth = max(strokeWidth, 1) / Double(max(pdfView.scaleFactor, 0.01))
                annotation.border = border
                annotation.color = stroke.ink.color
                annotation.add(path)
                annotation.userName = "KaitoPencilStroke"
                page.addAnnotation(annotation)
                committedCanvasAnnotations.append((page, annotation))
            }
        }
    }

    @objc private func commitCanvasDrawingsNotification(_ notification: Notification) {
        commitCanvasDrawingsToPDF()
    }

    @objc private func restoreEditingOverlaysNotification(_ notification: Notification) {
        iPadReaderView?.restoreEditingOverlays()
    }

    func installDoubleTapRecognizer(on view: UIView) {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        recognizer.name = "KaitoDoubleTap"
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
    }

    func disableNativeDoubleTapZoom(in view: UIView) {
        for recognizer in view.gestureRecognizers ?? [] {
            if let tap = recognizer as? UITapGestureRecognizer,
               tap.numberOfTapsRequired == 2,
               tap.name != "KaitoDoubleTap" {
                tap.isEnabled = false
            }
        }
        for subview in view.subviews {
            disableNativeDoubleTapZoom(in: subview)
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard annotationTool == nil,
              recognizer.state == .recognized,
              let sourceView = recognizer.view,
              let pdfView,
              let document = pdfView.document else { return }

        let sourcePoint = recognizer.location(in: sourceView)
        let pdfPoint = pdfView.convert(sourcePoint, from: sourceView)
        guard let page = pdfView.page(for: pdfPoint, nearest: false) else { return }

        let pageIndex = document.index(for: page)
        let pagePoint = pdfView.convert(pdfPoint, to: page)
        onDoubleTap(pageIndex, pagePoint, pdfPoint)
    }
#endif
}

#if os(iOS)
extension PDFReaderCoordinator: UIGestureRecognizerDelegate, PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        annotationChanged()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer.name == "KaitoTextBoxPan"
            || otherGestureRecognizer.name == "KaitoTextBoxPan"
            || gestureRecognizer.name == "KaitoPageTextBoxPan"
            || otherGestureRecognizer.name == "KaitoPageTextBoxPan" {
            return false
        }
        return true
    }
}
#endif

#if os(iOS)
extension PDFReaderCoordinator: PDFPageOverlayViewProvider {
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        overlay(for: page)
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? PDFPageAnnotationOverlayView else { return }
        prepareOverlay(overlay)
    }
}
#endif

#if os(macOS)
private final class AnnotatingPDFView: PDFView {
    var tool: PDFAnnotationTool?
    var lineWidth = 2.5
    var inkColor = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
    var onAnnotationChanged: () -> Void = {}
    var onDoubleTap: (Int, CGPoint, CGPoint) -> Void = { _, _, _ in }
    var onMarkerDeleted: (UUID) -> Void = { _ in }
    var isPageSelectionEnabled = false {
        didSet {
            if !isPageSelectionEnabled { pageSelectionLayer.isHidden = true }
            window?.invalidateCursorRects(for: self)
        }
    }
    var selectedPageIndices: Set<Int> = [] {
        didSet { syncSelectedPageLayers() }
    }
    var maximumSelectedPages = 5
    var onPageSelectionChanged: ([Int]) -> Void = { _ in }

    private var activePoints: [CGPoint] = []
    private weak var activePage: PDFPage?
    private var pageTrackingArea: NSTrackingArea?
    private struct SelectedPageEffect {
        let glowLayer: CAShapeLayer
        let gradientLayer: CAGradientLayer
    }
    private var selectedPageLayers: [Int: SelectedPageEffect] = [:]
    private lazy var pageSelectionLayer: CAShapeLayer = {
        let selectionLayer = CAShapeLayer()
        selectionLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.08).cgColor
        selectionLayer.strokeColor = NSColor.systemBlue.cgColor
        selectionLayer.lineWidth = 3
        selectionLayer.lineJoin = .round
        selectionLayer.isHidden = true
        wantsLayer = true
        layer?.addSublayer(selectionLayer)
        return selectionLayer
    }()
    private lazy var previewLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.lineCap = .round
        layer.lineJoin = .round
        return layer
    }()

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pageTrackingArea { removeTrackingArea(pageTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        pageTrackingArea = trackingArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isPageSelectionEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        syncSelectedPageLayers()
        guard isPageSelectionEnabled else {
            pageSelectionLayer.isHidden = true
            return
        }
        showPageSelection(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        pageSelectionLayer.isHidden = true
    }

    override func layout() {
        super.layout()
        keepPDFOverflowVisible(in: self)
        syncSelectedPageLayers()
    }

    private func keepPDFOverflowVisible(in view: NSView) {
        view.clipsToBounds = false
        view.layer?.masksToBounds = false
        if let scrollView = view as? NSScrollView {
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
        }
        if let clipView = view as? NSClipView {
            clipView.drawsBackground = false
            clipView.backgroundColor = .clear
        }
        view.subviews.forEach(keepPDFOverflowVisible(in:))
    }

    func transition(to displayMode: PDFDisplayMode) {
        wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.22
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(transition, forKey: "KaitoDisplayModeTransition")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.displayMode = displayMode
        displaysAsBook = false
        autoScales = true
        layoutDocumentView()
        layoutSubtreeIfNeeded()
        keepPDFOverflowVisible(in: self)
        setNeedsDisplay(bounds)
        CATransaction.commit()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "z" else {
            return super.performKeyEquivalent(with: event)
        }
        if event.modifierFlags.contains(.shift) {
            undoManager?.redo()
        } else {
            undoManager?.undo()
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if isPageSelectionEnabled {
            let viewPoint = convert(event.locationInWindow, from: nil)
            guard let page = page(for: viewPoint, nearest: false), let document else { return }
            let pageIndex = document.index(for: page)
            if selectedPageIndices.contains(pageIndex) {
                selectedPageIndices.remove(pageIndex)
            } else if selectedPageIndices.count < maximumSelectedPages {
                selectedPageIndices.insert(pageIndex)
            } else {
                NSSound.beep()
            }
            onPageSelectionChanged(selectedPageIndices.sorted())
            showPageSelection(at: viewPoint)
            return
        }

        if let tool {
            let viewPoint = convert(event.locationInWindow, from: nil)
            guard let page = page(for: viewPoint, nearest: false) else {
                super.mouseDown(with: event)
                return
            }
            let pagePoint = convert(viewPoint, to: page)
            switch tool {
            case .pencil:
                activePage = page
                activePoints = [pagePoint]
                beginPreview()
            case .eraser:
                eraseStroke(at: pagePoint, on: page)
            case .textBox:
                super.mouseDown(with: event)
            }
            return
        }

        if event.clickCount == 2 {
            let viewPoint = convert(event.locationInWindow, from: nil)
            if let page = page(for: viewPoint, nearest: false),
               let doc = document {
                let pageIndex = doc.index(for: page)
                let pagePoint = convert(viewPoint, to: page)
                // 将 AppKit 坐标系（左下角原点）转换为 SwiftUI 坐标系（左上角原点），防止气泡首次生成时垂直漂移
                let swiftUIViewPoint = CGPoint(x: viewPoint.x, y: bounds.height - viewPoint.y)
                onDoubleTap(pageIndex, pagePoint, swiftUIViewPoint)
                return
            }
        }

        super.mouseDown(with: event)
    }

    private func showPageSelection(at viewPoint: CGPoint) {
        guard let page = page(for: viewPoint, nearest: false) else {
            pageSelectionLayer.isHidden = true
            return
        }
        let pageRect = convert(page.bounds(for: .cropBox), from: page).insetBy(dx: -2, dy: -2)
        pageSelectionLayer.frame = bounds
        pageSelectionLayer.path = CGPath(
            roundedRect: pageRect,
            cornerWidth: 5,
            cornerHeight: 5,
            transform: nil
        )
        pageSelectionLayer.isHidden = false
    }

    private func syncSelectedPageLayers() {
        guard let document else { return }

        let removedIndices = selectedPageLayers.keys.filter { !selectedPageIndices.contains($0) }
        for pageIndex in removedIndices {
            guard let effect = selectedPageLayers.removeValue(forKey: pageIndex) else { continue }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.32)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            CATransaction.setCompletionBlock {
                effect.glowLayer.removeFromSuperlayer()
                effect.gradientLayer.removeFromSuperlayer()
            }
            effect.glowLayer.opacity = 0
            effect.gradientLayer.opacity = 0
            CATransaction.commit()
        }

        for pageIndex in selectedPageIndices {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageRect = convert(page.bounds(for: .cropBox), from: page).insetBy(dx: -2, dy: -2)
            let effect = selectedPageLayers[pageIndex] ?? makeSelectedPageLayer(pageIndex: pageIndex)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            effect.glowLayer.frame = bounds
            effect.gradientLayer.frame = pageRect
            let localPath = CGPath(
                roundedRect: effect.gradientLayer.bounds.insetBy(dx: 3, dy: 3),
                cornerWidth: 7,
                cornerHeight: 7,
                transform: nil
            )
            if let strokeMask = effect.gradientLayer.mask as? CAShapeLayer {
                strokeMask.frame = effect.gradientLayer.bounds
                strokeMask.path = localPath
            }
            effect.glowLayer.path = CGPath(
                roundedRect: pageRect.insetBy(dx: -1, dy: -1),
                cornerWidth: 8,
                cornerHeight: 8,
                transform: nil
            )
            CATransaction.commit()
        }
    }

    private func makeSelectedPageLayer(pageIndex: Int) -> SelectedPageEffect {
        wantsLayer = true
        let colors = [
            NSColor.systemBlue.cgColor,
            NSColor.systemPurple.cgColor,
            NSColor.systemPink.cgColor,
            NSColor.systemTeal.cgColor,
            NSColor.systemBlue.cgColor
        ]
        let gradientLayer = CAGradientLayer()
        gradientLayer.type = .conic
        gradientLayer.colors = colors
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.opacity = 0

        let strokeMask = CAShapeLayer()
        strokeMask.fillColor = NSColor.clear.cgColor
        strokeMask.strokeColor = NSColor.white.cgColor
        strokeMask.lineWidth = 5.2
        strokeMask.lineJoin = .round
        gradientLayer.mask = strokeMask

        let glowLayer = CAShapeLayer()
        glowLayer.fillColor = NSColor.clear.cgColor
        glowLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.62).cgColor
        glowLayer.lineWidth = 8
        glowLayer.lineJoin = .round
        glowLayer.shadowColor = NSColor.systemPurple.cgColor
        glowLayer.shadowOpacity = 0.72
        glowLayer.shadowRadius = 9
        glowLayer.shadowOffset = .zero
        glowLayer.opacity = 0

        let flow = CABasicAnimation(keyPath: "colors")
        flow.fromValue = colors
        flow.toValue = Array(colors.dropFirst()) + [colors[1]]
        flow.duration = 2.4
        flow.repeatCount = .infinity
        flow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradientLayer.add(flow, forKey: "KaitoAIPageSelectionFlow")
        layer?.addSublayer(glowLayer)
        layer?.addSublayer(gradientLayer)
        let effect = SelectedPageEffect(glowLayer: glowLayer, gradientLayer: gradientLayer)
        selectedPageLayers[pageIndex] = effect

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.34)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        glowLayer.opacity = 1
        gradientLayer.opacity = 1
        CATransaction.commit()
        return effect
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            return super.menu(for: event)
        }
        let pagePoint = convert(viewPoint, to: page)

        for annotation in page.annotations {
            if let marker = annotation as? KaitoQuestionAnnotation,
               !marker.record.isMarkDeleted,
               marker.bounds.insetBy(dx: -8, dy: -8).contains(pagePoint) {
                let menu = NSMenu()
                let item = NSMenuItem(
                    title: "删除标记",
                    action: #selector(deleteMarkerItemAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = marker
                menu.addItem(item)
                return menu
            }
        }
        return super.menu(for: event)
    }

    @objc private func deleteMarkerItemAction(_ sender: NSMenuItem) {
        guard let marker = sender.representedObject as? KaitoQuestionAnnotation,
              let page = marker.page else { return }
        marker.record.isMarkDeleted = true
        marker.updateContents()
        page.removeAnnotation(marker)
        onMarkerDeleted(marker.record.id)
        setNeedsDisplay(marker.bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        switch tool {
        case .pencil:
            guard let activePage else { return }
            activePoints.append(convert(viewPoint, to: activePage))
            updatePreview()
        case .eraser:
            guard let page = page(for: viewPoint, nearest: false) else { return }
            eraseStroke(at: convert(viewPoint, to: page), on: page)
        case .textBox:
            super.mouseDragged(with: event)
        case nil:
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if tool == .pencil {
            commitStroke()
        } else if tool == nil {
            super.mouseUp(with: event)
        }
    }

    private func beginPreview() {
        guard let previewHost = documentView else { return }
        previewHost.wantsLayer = true
        if previewLayer.superlayer !== previewHost.layer {
            previewLayer.removeFromSuperlayer()
            previewHost.layer?.addSublayer(previewLayer)
        }
        previewLayer.frame = previewHost.bounds
        previewLayer.strokeColor = inkColor.cgColor
        previewLayer.lineWidth = lineWidth
        updatePreview()
    }

    private func updatePreview() {
        guard let activePage, let previewHost = documentView else { return }
        previewLayer.frame = previewHost.bounds
        let documentPoints = activePoints.map { pagePoint in
            let pdfViewPoint = convert(pagePoint, from: activePage)
            return previewHost.convert(pdfViewPoint, from: self)
        }
        previewLayer.path = makePath(from: documentPoints).cgPath
    }

    private func commitStroke() {
        defer {
            activePoints.removeAll(keepingCapacity: true)
            activePage = nil
            previewLayer.path = nil
        }
        guard let page = activePage, activePoints.count > 1 else { return }

        let pageBounds = page.bounds(for: .mediaBox)
        let annotation = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        annotation.color = inkColor
        let annotationPoints = activePoints.map {
            CGPoint(x: $0.x - pageBounds.minX, y: $0.y - pageBounds.minY)
        }
        annotation.add(makePath(from: annotationPoints))
        add(annotation, to: page, registersUndo: true)
    }

    private func eraseStroke(at pagePoint: CGPoint, on page: PDFPage) {
        let tolerance = max(lineWidth, 8)

        for annotation in page.annotations.reversed() where annotation.type == "Ink" {
            let annotationPoint = CGPoint(
                x: pagePoint.x - annotation.bounds.minX,
                y: pagePoint.y - annotation.bounds.minY
            )
            let hit = (annotation.paths ?? []).contains { path in
                path.cgPath.copy(
                    strokingWithWidth: tolerance * 2,
                    lineCap: .round,
                    lineJoin: .round,
                    miterLimit: 0
                ).contains(annotationPoint)
            }
            if hit {
                remove(annotation, from: page, registersUndo: true)
                return
            }
        }
    }

    private func add(_ annotation: PDFAnnotation, to page: PDFPage, registersUndo: Bool) {
        page.addAnnotation(annotation)
        onAnnotationChanged()
        guard registersUndo else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            target.remove(annotation, from: page, registersUndo: true)
        }
        undoManager?.setActionName("笔迹")
    }

    private func remove(_ annotation: PDFAnnotation, from page: PDFPage, registersUndo: Bool) {
        page.removeAnnotation(annotation)
        onAnnotationChanged()
        guard registersUndo else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            target.add(annotation, to: page, registersUndo: true)
        }
        undoManager?.setActionName("删除笔迹")
    }

    private func makePath(from points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        return path
    }
}

private struct PDFKitReader: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int
    @Binding var zoom: Double
    @Binding var isZoomLocked: Bool
    @Binding var showsTwoPages: Bool
    let annotationTool: PDFAnnotationTool?
    let annotationWidth: Double
    let annotationColor: Color
    let isPageSelectionEnabled: Bool
    @Binding var selectedPageIndices: [Int]
    let maximumSelectedPages: Int
    let annotationChanged: () -> Void
    let onDoubleTap: (Int, CGPoint, CGPoint) -> Void
    let onMarkerDeleted: (UUID) -> Void
    @Binding var coordinatorRef: PDFReaderCoordinator?

    func makeCoordinator() -> PDFReaderCoordinator {
        let coordinator = PDFReaderCoordinator(currentPage: $currentPage, zoom: $zoom)
        coordinator.onDoubleTap = onDoubleTap
        coordinator.onMarkerDeleted = onMarkerDeleted
        DispatchQueue.main.async {
            self.coordinatorRef = coordinator
        }
        return coordinator
    }

    func makeNSView(context: Context) -> PDFView {
        makePDFView(coordinator: context.coordinator)
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        updatePDFView(pdfView, coordinator: context.coordinator)
    }
}
#else
private final class EditablePDFTextBox: UITextView, UITextViewDelegate, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    var onSelected: (EditablePDFTextBox) -> Void = { _ in }
    var onChanged: () -> Void = {}
    var onDelete: (EditablePDFTextBox) -> Void = { _ in }
    var onFontSizeChanged: (CGFloat) -> Void = { _ in }
    private var dragStartFrame = CGRect.zero
    private var dragStartFontSize: CGFloat = 18
    private var isSelectedBox = false
    private var isEditingText = false
    private var isResizeGesture = false
    private var resizesFromLeft = false
    private var resizesFromTop = false
    private let handles = (0..<4).map { _ in UIView(frame: .zero) }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.82)
        layer.borderColor = UIColor.systemBlue.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 4
        isScrollEnabled = false
        isEditable = false
        isSelectable = true
        allowsEditingTextAttributes = true
        delegate = self
        textContainerInset = UIEdgeInsets(top: 4, left: 5, bottom: 4, right: 5)
        for handle in handles {
            handle.backgroundColor = .systemBlue
            handle.layer.cornerRadius = 5
            handle.isHidden = true
            handle.isUserInteractionEnabled = false
            addSubview(handle)
        }
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(selectBox))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(editBox))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressMove(_:)))
        longPress.minimumPressDuration = 0.35
        addGestureRecognizer(longPress)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
        pan.name = "KaitoTextBoxResize"
        pan.delegate = self
        addGestureRecognizer(pan)
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size: CGFloat = 10
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0), CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height)]
        for (handle, point) in zip(handles, points) {
            handle.frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "z", modifierFlags: .control, action: #selector(performControlUndo)),
            UIKeyCommand(input: "z", modifierFlags: [.control, .shift], action: #selector(performControlRedo)),
            UIKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [], action: #selector(deleteSelectedBox))
        ]
    }

    @objc private func selectBox() {
        isEditingText = false
        isEditable = false
        setSelected(true)
        _ = becomeFirstResponder()
        onSelected(self)
    }

    @objc private func editBox() {
        isEditingText = true
        isEditable = true
        setSelected(true)
        _ = becomeFirstResponder()
        onSelected(self)
    }

    func setSelected(_ selected: Bool) {
        isSelectedBox = selected
        layer.borderWidth = selected ? 2 : 0
        handles.forEach { $0.isHidden = !selected }
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            layer.borderWidth = 2
            onSelected(self)
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isEditingText {
            isEditingText = false
            isEditable = false
        }
        return resigned
    }

    func textViewDidChange(_ textView: UITextView) {
        onChanged()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        isEditingText = false
        isEditable = false
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.name == "KaitoTextBoxResize" else { return true }
        guard isSelectedBox else { return false }
        let point = gestureRecognizer.location(in: self)
        let edgeInset: CGFloat = 26
        let nearHorizontalEdge = point.x <= edgeInset || point.x >= bounds.width - edgeInset
        let nearVerticalEdge = point.y <= edgeInset || point.y >= bounds.height - edgeInset
        return nearHorizontalEdge && nearVerticalEdge
    }

    @objc private func handleMove(_ recognizer: UIPanGestureRecognizer) {
        guard let superview else { return }
        switch recognizer.state {
        case .began:
            dragStartFrame = frame
            dragStartFontSize = font?.pointSize ?? 18
            let location = recognizer.location(in: self)
            resizesFromLeft = location.x < bounds.midX
            resizesFromTop = location.y < bounds.midY
            isResizeGesture = true
            setSelected(true)
            onSelected(self)
        case .changed:
            let translation = recognizer.translation(in: superview)
            let proposedWidth = resizesFromLeft ? dragStartFrame.width - translation.x : dragStartFrame.width + translation.x
            let proposedHeight = resizesFromTop ? dragStartFrame.height - translation.y : dragStartFrame.height + translation.y
            let scale = max(min(proposedWidth / max(dragStartFrame.width, 1), proposedHeight / max(dragStartFrame.height, 1)), 0.35)
            let newSize = CGSize(width: dragStartFrame.width * scale, height: dragStartFrame.height * scale)
            let newOrigin = CGPoint(
                x: resizesFromLeft ? dragStartFrame.maxX - newSize.width : dragStartFrame.minX,
                y: resizesFromTop ? dragStartFrame.maxY - newSize.height : dragStartFrame.minY
            )
            frame = CGRect(origin: newOrigin, size: newSize).intersection(superview.bounds)
            let newFontSize = max(dragStartFontSize * scale, 6)
            font = font.map { UIFont(descriptor: $0.fontDescriptor, size: newFontSize) }
            onFontSizeChanged(newFontSize)
        case .ended, .cancelled:
            isResizeGesture = false
            let oldFrame = dragStartFrame
            let newFrame = frame
            let oldFontSize = dragStartFontSize
            if oldFrame != newFrame {
                undoManager?.registerUndo(withTarget: self) { target in
                    target.frame = oldFrame
                    if let currentFont = target.font {
                        target.font = UIFont(descriptor: currentFont.fontDescriptor, size: oldFontSize)
                    }
                    target.onFontSizeChanged(oldFontSize)
                    target.onChanged()
                }
                undoManager?.setActionName("调整文本框")
                onChanged()
            }
        default:
            break
        }
    }

    @objc private func handleLongPressMove(_ recognizer: UILongPressGestureRecognizer) {
        guard let superview, !isResizeGesture else { return }
        switch recognizer.state {
        case .began:
            dragStartFrame = frame
            setSelected(true)
            onSelected(self)
        case .changed:
            let location = recognizer.location(in: superview)
            frame.origin = CGPoint(
                x: min(max(location.x - frame.width / 2, 0), max(superview.bounds.width - frame.width, 0)),
                y: min(max(location.y - frame.height / 2, 0), max(superview.bounds.height - frame.height, 0))
            )
        case .ended, .cancelled:
            let oldFrame = dragStartFrame
            guard oldFrame != frame else { return }
            undoManager?.registerUndo(withTarget: self) { target in
                target.frame = oldFrame
                target.onChanged()
            }
            undoManager?.setActionName("移动文本框")
            onChanged()
        default:
            break
        }
    }

    @objc private func deleteSelectedBox() {
        guard isSelectedBox, !isEditingText else { return }
        onDelete(self)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        setSelected(true)
        onSelected(self)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu() }
            return UIMenu(children: [
                UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    self.onDelete(self)
                }
            ])
        }
    }

    @objc private func performControlUndo() {
        undoManager?.undo()
    }

    @objc private func performControlRedo() {
        undoManager?.redo()
    }

}

private final class IPadPDFPageView: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    let page: PDFPage
    let pageIndex: Int
    let canvasView = PKCanvasView(frame: .zero)
    var annotationChanged: () -> Void = {}
    var onDoubleTap: (Int, CGPoint, CGPoint) -> Void = { _, _, _ in }
    var onFontSizeChanged: (CGFloat) -> Void = { _ in }
    var textFont = UIFont.systemFont(ofSize: 18)
    var textColor = UIColor.label
    private var textMode = false
    private weak var selectedTextBox: EditablePDFTextBox?
    private var textBoxes: [EditablePDFTextBox] = []
    private var transientAnnotations: [PDFAnnotation] = []
    private var textStart: CGPoint?
    private let previewLayer = CAShapeLayer()
    private var cachedPageImage: UIImage?
    private var cachedImageSize = CGSize.zero
    private var annotationSignature = ""
    private weak var observedToolPicker: PKToolPicker?

    var aspectHeightMultiplier: CGFloat {
        let pageBounds = page.bounds(for: .cropBox)
        if abs(page.rotation) % 180 == 90 {
            return pageBounds.width / max(pageBounds.height, 1)
        }
        return pageBounds.height / max(pageBounds.width, 1)
    }

    init(page: PDFPage, pageIndex: Int) {
        self.page = page
        self.pageIndex = pageIndex
        super.init(frame: .zero)
        backgroundColor = .white
        isOpaque = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 2)

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .pencilOnly
        canvasView.isScrollEnabled = false
        canvasView.delegate = self
        addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        previewLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        previewLayer.strokeColor = UIColor.systemBlue.cgColor
        previewLayer.lineWidth = 2
        previewLayer.lineDashPattern = [6, 4]
        previewLayer.isHidden = true
        layer.addSublayer(previewLayer)

        let textPan = UIPanGestureRecognizer(target: self, action: #selector(handleTextPan(_:)))
        textPan.name = "KaitoCustomPageTextPan"
        textPan.delegate = self
        addGestureRecognizer(textPan)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.name = "KaitoCustomPageDoubleTap"
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        doubleTap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        UIColor.white.setFill()
        UIRectFill(bounds)
        let longestSide = max(bounds.width, bounds.height)
        let displayScale = min(traitCollection.displayScale, 1800 / max(longestSide, 1))
        let pixelSize = CGSize(
            width: max(bounds.width * displayScale, 1),
            height: max(bounds.height * displayScale, 1)
        )
        if cachedPageImage == nil || cachedImageSize != pixelSize {
            cachedPageImage = page.thumbnail(of: pixelSize, for: .cropBox)
            cachedImageSize = pixelSize
        }
        cachedPageImage?.draw(in: bounds)
    }

    func refreshPageRendering() {
        let signature = page.annotations.map {
            "\($0.userName ?? "")|\($0.contents ?? "")|\($0.bounds)"
        }.joined(separator: ";")
        guard signature != annotationSignature else { return }
        annotationSignature = signature
        cachedPageImage = nil
        setNeedsDisplay()
    }

    func releaseCachedPageImage() {
        cachedPageImage = nil
    }

    func ensurePageRendering() {
        if cachedPageImage == nil { setNeedsDisplay() }
    }

    func configure(tool: PDFAnnotationTool?, picker: PKToolPicker, font: UIFont, color: UIColor) {
        textFont = font
        textColor = color
        textMode = tool == .textBox
        canvasView.isUserInteractionEnabled = tool == .pencil
        canvasView.drawingGestureRecognizer.isEnabled = tool == .pencil
        gestureRecognizers?.first(where: { $0.name == "KaitoCustomPageTextPan" })?.isEnabled = textMode
        isUserInteractionEnabled = true
        if textMode, let selectedTextBox {
            if selectedTextBox.font != font || selectedTextBox.textColor != color {
                selectedTextBox.font = font
                selectedTextBox.textColor = color
                annotationChanged()
            }
        }
        if tool == .pencil {
            if observedToolPicker !== picker {
                if let observedToolPicker {
                    observedToolPicker.removeObserver(canvasView)
                }
                picker.addObserver(canvasView)
                observedToolPicker = picker
            }
            canvasView.pencilKitResponderState.activeToolPicker = picker
            canvasView.pencilKitResponderState.toolPickerVisibility = .visible
            DispatchQueue.main.async { [weak canvasView] in
                guard let canvasView, canvasView.window != nil else { return }
                canvasView.becomeFirstResponder()
            }
        } else {
            canvasView.pencilKitResponderState.toolPickerVisibility = .inactive
        }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        annotationChanged()
    }

    func commitDrawingToPDF() {
        restoreEditingOverlays()
        let pageBounds = page.bounds(for: .cropBox)
        for stroke in canvasView.drawing.strokes {
            let points = stroke.path.map { pagePoint(for: $0.location, pageBounds: pageBounds) }
            guard let first = points.first, points.count > 1 else { continue }
            let path = UIBezierPath()
            path.move(to: CGPoint(x: first.x - pageBounds.minX, y: first.y - pageBounds.minY))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x - pageBounds.minX, y: point.y - pageBounds.minY))
            }
            let annotation = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
            let border = PDFBorder()
            border.lineWidth = Double(max(stroke.path.first?.size.width ?? 1, 1))
            annotation.border = border
            annotation.color = stroke.ink.color
            annotation.add(path)
            annotation.userName = "KaitoPencilStroke"
            page.addAnnotation(annotation)
            transientAnnotations.append(annotation)
        }
        for textBox in textBoxes where !textBox.text.isEmpty {
            let annotation = PDFAnnotation(bounds: pdfRect(from: textBox.frame), forType: .freeText, withProperties: nil)
            annotation.contents = textBox.text
            annotation.color = .clear
            annotation.font = textBox.font
            annotation.fontColor = textBox.textColor
            annotation.userName = "KaitoTextBox"
            page.addAnnotation(annotation)
            transientAnnotations.append(annotation)
        }
    }

    func restoreEditingOverlays() {
        transientAnnotations.forEach { page.removeAnnotation($0) }
        transientAnnotations.removeAll()
    }

    @objc private func handleTextPan(_ recognizer: UIPanGestureRecognizer) {
        guard textMode else { return }
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            textStart = point
            showPreview(from: point, to: point)
        case .changed:
            guard let start = textStart else { return }
            showPreview(from: start, to: point)
        case .ended:
            guard let start = textStart else { return }
            textStart = nil
            hidePreview()
            let rect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
            guard rect.width >= 24, rect.height >= 18 else { return }
            addTextBox(frame: rect)
        case .cancelled, .failed:
            textStart = nil
            hidePreview()
        default:
            break
        }
    }

    private func addTextBox(frame: CGRect) {
        let textBox = EditablePDFTextBox(frame: frame)
        textBox.font = textFont
        textBox.textColor = textColor
        textBox.onSelected = { [weak self] selectedTextBox in
            guard let self else { return }
            self.textBoxes.filter { $0 !== selectedTextBox }.forEach { $0.setSelected(false) }
            self.selectedTextBox = selectedTextBox
        }
        textBox.onChanged = { [weak self] in
            self?.annotationChanged()
        }
        textBox.onDelete = { [weak self] textBox in
            self?.removeTextBox(textBox, registersUndo: true)
        }
        textBox.onFontSizeChanged = { [weak self] size in
            self?.onFontSizeChanged(size)
        }
        addSubview(textBox)
        textBoxes.append(textBox)
        textBoxes.filter { $0 !== textBox }.forEach { $0.setSelected(false) }
        textBox.setSelected(true)
        selectedTextBox = textBox
        undoManager?.registerUndo(withTarget: self) { target in
            target.removeTextBox(textBox, registersUndo: true)
        }
        annotationChanged()
        _ = textBox.becomeFirstResponder()
    }

    private func removeTextBox(_ textBox: EditablePDFTextBox, registersUndo: Bool) {
        guard let index = textBoxes.firstIndex(where: { $0 === textBox }) else { return }
        let frame = textBox.frame
        textBoxes.remove(at: index)
        textBox.removeFromSuperview()
        if registersUndo {
            undoManager?.registerUndo(withTarget: self) { target in
                textBox.frame = frame
                target.addSubview(textBox)
                target.textBoxes.insert(textBox, at: min(index, target.textBoxes.count))
                target.annotationChanged()
            }
        }
        annotationChanged()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .recognized, !textMode else { return }
        let point = recognizer.location(in: self)
        let pdfPoint = pagePoint(for: point, pageBounds: page.bounds(for: .cropBox))
        onDoubleTap(pageIndex, pdfPoint, point)
    }

    private func pagePoint(for point: CGPoint, pageBounds: CGRect) -> CGPoint {
        CGPoint(
            x: pageBounds.minX + point.x / max(bounds.width, 1) * pageBounds.width,
            y: pageBounds.minY + (1 - point.y / max(bounds.height, 1)) * pageBounds.height
        )
    }

    private func pdfRect(from rect: CGRect) -> CGRect {
        let pageBounds = page.bounds(for: .cropBox)
        let lowerLeft = pagePoint(for: CGPoint(x: rect.minX, y: rect.maxY), pageBounds: pageBounds)
        return CGRect(
            x: lowerLeft.x,
            y: lowerLeft.y,
            width: rect.width / max(bounds.width, 1) * pageBounds.width,
            height: rect.height / max(bounds.height, 1) * pageBounds.height
        )
    }

    private func showPreview(from start: CGPoint, to end: CGPoint) {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        previewLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 4).cgPath
        previewLayer.isHidden = false
    }

    private func hidePreview() {
        previewLayer.isHidden = true
        previewLayer.path = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.name == "KaitoCustomPageDoubleTap" else {
            return true
        }
        let point = gestureRecognizer.location(in: self)
        var hitView = hitTest(point, with: nil)
        while let current = hitView {
            if current is EditablePDFTextBox { return false }
            hitView = current.superview
        }
        return true
    }
}

private final class IPadPDFReaderView: UIView, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let toolPicker = PKToolPicker()
    private(set) var pageViews: [IPadPDFPageView] = []
    private var pageLayoutConstraints: [NSLayoutConstraint] = []
    private var showsTwoPages = false
    private(set) var currentPageIndex = 0
    var currentPageChanged: (Int) -> Void = { _ in }
    var onDoubleTap: (Int, CGPoint, CGPoint) -> Void = { _, _, _ in }
    var zoomChanged: (Double) -> Void = { _ in }
    var fontSizeChanged: (Double) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.clipsToBounds = false
        scrollView.backgroundColor = .clear
        scrollView.alwaysBounceVertical = true
        scrollView.minimumZoomScale = 0.65
        scrollView.maximumZoomScale = 2.2
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 18
        stackView.alignment = .center
        scrollView.addSubview(stackView)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 18),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -18),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        keepPDFOverflowVisible()
    }

    private func keepPDFOverflowVisible() {
        scrollView.clipsToBounds = false
        scrollView.layer.masksToBounds = false
        scrollView.backgroundColor = .clear
    }

    func setDocument(_ document: PDFDocument, annotationChanged: @escaping () -> Void) {
        guard pageViews.count != document.pageCount else { return }
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        pageViews.removeAll()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let pageView = IPadPDFPageView(page: page, pageIndex: index)
            pageView.annotationChanged = annotationChanged
            pageView.onDoubleTap = { [weak self, weak pageView] pageIndex, pagePoint, pageViewPoint in
                guard let self, let pageView else { return }
                self.onDoubleTap(pageIndex, pagePoint, pageView.convert(pageViewPoint, to: self))
            }
            pageView.onFontSizeChanged = { [weak self] size in
                self?.fontSizeChanged(Double(size))
            }
            pageViews.append(pageView)
        }
        layoutPages(animated: false)
    }

    func setShowsTwoPages(_ showsTwoPages: Bool) {
        guard self.showsTwoPages != showsTwoPages else { return }
        self.showsTwoPages = showsTwoPages
        layoutPages(animated: true)
    }

    private func layoutPages(animated: Bool) {
        pageLayoutConstraints.forEach { $0.isActive = false }
        pageLayoutConstraints.removeAll()
        for arrangedView in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(arrangedView)
            if let row = arrangedView as? UIStackView {
                for pageView in row.arrangedSubviews {
                    row.removeArrangedSubview(pageView)
                    pageView.removeFromSuperview()
                }
            }
            arrangedView.removeFromSuperview()
        }

        if showsTwoPages {
            for startIndex in stride(from: 0, to: pageViews.count, by: 2) {
                let row = UIStackView()
                row.axis = .horizontal
                row.alignment = .top
                row.distribution = .fillEqually
                row.spacing = 18
                row.translatesAutoresizingMaskIntoConstraints = false
                stackView.addArrangedSubview(row)
                pageLayoutConstraints.append(row.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -36))
                for index in startIndex..<min(startIndex + 2, pageViews.count) {
                    let pageView = pageViews[index]
                    row.addArrangedSubview(pageView)
                    pageLayoutConstraints.append(
                        pageView.heightAnchor.constraint(
                            equalTo: pageView.widthAnchor,
                            multiplier: pageView.aspectHeightMultiplier
                        )
                    )
                }
            }
        } else {
            for pageView in pageViews {
                stackView.addArrangedSubview(pageView)
                pageLayoutConstraints.append(pageView.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -36))
                pageLayoutConstraints.append(
                    pageView.heightAnchor.constraint(
                        equalTo: pageView.widthAnchor,
                        multiplier: pageView.aspectHeightMultiplier
                    )
                )
            }
        }
        NSLayoutConstraint.activate(pageLayoutConstraints)
        let changes = {
            self.stackView.layoutIfNeeded()
            self.scrollView.layoutIfNeeded()
        }
        if animated, window != nil {
            UIView.animate(
                withDuration: 0.24,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
                animations: changes
            )
        } else {
            changes()
        }
    }

    func configure(tool: PDFAnnotationTool?, font: UIFont, color: UIColor) {
        scrollView.isScrollEnabled = tool != .textBox
        scrollView.pencilKitResponderState.activeToolPicker = toolPicker
        scrollView.pencilKitResponderState.toolPickerVisibility = tool == .pencil ? .visible : .inactive
        pageViews.forEach { $0.configure(tool: tool, picker: toolPicker, font: font, color: color) }
    }

    func setZoom(_ zoom: Double, isLocked: Bool) {
        scrollView.pinchGestureRecognizer?.isEnabled = !isLocked
        let scale = min(max(CGFloat(zoom), scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        if abs(scrollView.zoomScale - scale) > 0.01 {
            scrollView.setZoomScale(scale, animated: false)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        stackView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        keepPDFOverflowVisible()
        zoomChanged(Double(scrollView.zoomScale))
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        keepPDFOverflowVisible()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        keepPDFOverflowVisible()
    }

    func commitPendingEditsToPDF() {
        pageViews.forEach { $0.commitDrawingToPDF() }
    }

    func restoreEditingOverlays() {
        pageViews.forEach { $0.restoreEditingOverlays() }
    }

    func refreshPages() {
        pageViews.forEach { $0.refreshPageRendering() }
    }

    func goToPage(_ index: Int) {
        guard pageViews.indices.contains(index) else { return }
        currentPageIndex = index
        let rect = pageViews[index].convert(pageViews[index].bounds, to: scrollView)
        scrollView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -12), animated: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let midpoint = scrollView.contentOffset.y + scrollView.bounds.midY
        let nearest = pageViews.min {
            abs($0.convert($0.bounds, to: scrollView).midY - midpoint)
                < abs($1.convert($1.bounds, to: scrollView).midY - midpoint)
        }
        if let nearest {
            currentPageIndex = nearest.pageIndex
            currentPageChanged(nearest.pageIndex)
        }
        let retentionRect = scrollView.bounds
            .offsetBy(dx: scrollView.contentOffset.x, dy: scrollView.contentOffset.y)
            .insetBy(dx: 0, dy: -scrollView.bounds.height)
        for pageView in pageViews {
            let pageRect = pageView.convert(pageView.bounds, to: scrollView)
            if !retentionRect.intersects(pageRect) {
                pageView.releaseCachedPageImage()
            } else {
                pageView.ensurePageRendering()
            }
        }
    }
}

private struct PDFKitReader: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int
    @Binding var zoom: Double
    @Binding var isZoomLocked: Bool
    @Binding var showsTwoPages: Bool
    let annotationTool: PDFAnnotationTool?
    @Binding var annotationWidth: Double
    let annotationColor: Color
    let annotationFontName: String
    let annotationTextIsBold: Bool
    let annotationTextIsItalic: Bool
    let annotationChanged: () -> Void
    let onDoubleTap: (Int, CGPoint, CGPoint) -> Void
    let onMarkerDeleted: (UUID) -> Void
    @Binding var coordinatorRef: PDFReaderCoordinator?

    func makeCoordinator() -> PDFReaderCoordinator {
        let coordinator = PDFReaderCoordinator(currentPage: $currentPage, zoom: $zoom)
        coordinator.onDoubleTap = onDoubleTap
        coordinator.onMarkerDeleted = onMarkerDeleted
        coordinator.annotationChanged = annotationChanged
        DispatchQueue.main.async {
            self.coordinatorRef = coordinator
        }
        return coordinator
    }

    func makeUIView(context: Context) -> IPadPDFReaderView {
        let readerView = IPadPDFReaderView()
        readerView.setDocument(document, annotationChanged: annotationChanged)
        readerView.setShowsTwoPages(showsTwoPages)
        readerView.currentPageChanged = { index in
            guard currentPage != index else { return }
            currentPage = index
        }
        readerView.onDoubleTap = onDoubleTap
        readerView.zoomChanged = { value in
            guard abs(zoom - value) > 0.01 else { return }
            zoom = value
        }
        readerView.fontSizeChanged = { value in
            annotationWidth = min(max(value, 6), 144)
        }
        context.coordinator.iPadReaderView = readerView
        return readerView
    }

    func updateUIView(_ readerView: IPadPDFReaderView, context: Context) {
        context.coordinator.currentPage = $currentPage
        context.coordinator.zoom = $zoom
        context.coordinator.iPadReaderView = readerView
        readerView.setDocument(document, annotationChanged: annotationChanged)
        readerView.setShowsTwoPages(showsTwoPages)
        readerView.onDoubleTap = onDoubleTap
        readerView.fontSizeChanged = { value in
            annotationWidth = min(max(value, 6), 144)
        }
        readerView.refreshPages()
        readerView.setZoom(zoom, isLocked: isZoomLocked)
        if readerView.currentPageIndex != currentPage {
            readerView.goToPage(currentPage)
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if annotationTextIsBold { traits.insert(.traitBold) }
        if annotationTextIsItalic { traits.insert(.traitItalic) }
        let baseFont = UIFont(name: annotationFontName, size: annotationWidth) ?? .systemFont(ofSize: annotationWidth)
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) ?? baseFont.fontDescriptor
        readerView.configure(
            tool: annotationTool,
            font: UIFont(descriptor: descriptor, size: annotationWidth),
            color: UIColor(annotationColor)
        )
    }
}
#endif

#if os(macOS)
private extension PDFKitReader {
    func makePDFView(coordinator: PDFReaderCoordinator) -> PDFView {
#if os(macOS)
        let annotatingView = AnnotatingPDFView()
        annotatingView.onDoubleTap = onDoubleTap
        annotatingView.onMarkerDeleted = onMarkerDeleted
        annotatingView.onPageSelectionChanged = { selectedPageIndices = $0 }
        let pdfView: PDFView = annotatingView
#else
        let pdfView = PDFView()
#endif
        pdfView.delegate = coordinator
        pdfView.document = document
        pdfView.displayDirection = .vertical
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysAsBook = false
        pdfView.displaysPageBreaks = true
#if os(macOS)
        pdfView.pageBreakMargins = NSEdgeInsets(top: 14, left: 7, bottom: 14, right: 7)
#else
        pdfView.pageBreakMargins = UIEdgeInsets(top: 14, left: 7, bottom: 14, right: 7)
#endif
        pdfView.backgroundColor = .clear
        pdfView.autoScales = true
#if os(iOS)
        pdfView.pageOverlayViewProvider = coordinator
        coordinator.installDoubleTapRecognizer(on: pdfView)
        coordinator.installTextBoxRecognizer(on: pdfView)
        DispatchQueue.main.async {
            coordinator.disableNativeDoubleTapZoom(in: pdfView)
        }
#endif
        coordinator.observe(pdfView)
        pdfView.clipsToBounds = false
        DispatchQueue.main.async {
            removeVisualClipping(from: pdfView)
        }
        return pdfView
    }

    private func removeVisualClipping(from view: NSView) {
        view.clipsToBounds = false
        view.layer?.masksToBounds = false
        if let scrollView = view as? NSScrollView {
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
        }
        if let clipView = view as? NSClipView {
            clipView.drawsBackground = false
            clipView.backgroundColor = .clear
        }
        view.subviews.forEach(removeVisualClipping(from:))
    }

    func updatePDFView(_ pdfView: PDFView, coordinator: PDFReaderCoordinator) {
        coordinator.currentPage = $currentPage
        coordinator.zoom = $zoom
        coordinator.onDoubleTap = onDoubleTap
        coordinator.onMarkerDeleted = onMarkerDeleted
#if os(iOS)
        coordinator.annotationChanged = annotationChanged
        coordinator.updateAnnotationTool(
            annotationTool,
            width: annotationWidth,
            color: UIColor(annotationColor),
            fontName: annotationFontName,
            isBold: annotationTextIsBold,
            isItalic: annotationTextIsItalic
        )
#elseif os(macOS)
        if let annotatingView = pdfView as? AnnotatingPDFView {
            annotatingView.tool = annotationTool
            annotatingView.lineWidth = annotationWidth
            annotatingView.inkColor = NSColor(annotationColor).usingColorSpace(.sRGB) ?? .black
            annotatingView.onAnnotationChanged = annotationChanged
            annotatingView.onDoubleTap = onDoubleTap
            annotatingView.onMarkerDeleted = onMarkerDeleted
            annotatingView.isPageSelectionEnabled = isPageSelectionEnabled
            annotatingView.selectedPageIndices = Set(selectedPageIndices)
            annotatingView.maximumSelectedPages = maximumSelectedPages
            annotatingView.onPageSelectionChanged = { selectedPageIndices = $0 }
        }
#endif

        if pdfView.document !== document {
            pdfView.document = document
        }

        let desiredMode: PDFDisplayMode = showsTwoPages ? .twoUpContinuous : .singlePageContinuous
        let layoutChanged = pdfView.displayMode != desiredMode
        if layoutChanged {
            coordinator.isApplyingScale = true
            if let annotatingView = pdfView as? AnnotatingPDFView {
                annotatingView.transition(to: desiredMode)
            } else {
                pdfView.displayMode = desiredMode
                pdfView.displaysAsBook = false
                pdfView.autoScales = true
            }
            removeVisualClipping(from: pdfView)
        }

        let wasLocked = coordinator.isZoomLocked
        coordinator.isZoomLocked = isZoomLocked
        if isZoomLocked && !wasLocked {
            coordinator.lockedScale = pdfView.scaleFactor
        }

        let targetIndex = min(max(currentPage, 0), document.pageCount - 1)
        if let page = document.page(at: targetIndex), pdfView.currentPage !== page {
            pdfView.go(to: page)
        }

        guard !isZoomLocked else {
            coordinator.isApplyingScale = false
            return
        }
        DispatchQueue.main.async {
            let fitScale = pdfView.scaleFactorForSizeToFit
            guard fitScale > 0 else {
                coordinator.isApplyingScale = false
                return
            }
            let targetScale = fitScale * zoom
            guard abs(pdfView.scaleFactor - targetScale) > 0.002 else {
                coordinator.isApplyingScale = false
                return
            }
            coordinator.isApplyingScale = true
            pdfView.autoScales = false
            pdfView.minScaleFactor = fitScale * 0.65
            pdfView.maxScaleFactor = fitScale * 2.2
            pdfView.scaleFactor = targetScale
            coordinator.isApplyingScale = false
        }
    }
}
#endif

private struct PDFWelcomeView: View {
    let openPDF: () -> Void
    let openLastPDF: () -> Void
    let hasLastPDF: Bool
    let openDroppedPDF: (URL) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            welcomeBackground
            rightPaneBackground

            BundledPNGImage(resourceName: "Kaito")
                .scaledToFit()
                .frame(width: 840, height: 1492)
                .position(x: 116, y: 720)
                .opacity(0.45)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(1)

            VStack(alignment: .leading, spacing: 22) {
                Text("Kaito")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Kaito")

                WelcomeActionButtons(
                    openPDF: openPDF,
                    openLastPDF: openLastPDF,
                    hasLastPDF: hasLastPDF
                )

                if isDropTargeted {
                    Label("松开以打开 PDF", systemImage: "arrow.down.doc.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color(red: 0.98, green: 0.78, blue: 0.84))
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: 268, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 44)
            .zIndex(2)
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.18), value: isDropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let pdfURL = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else {
                return false
            }
            openDroppedPDF(pdfURL)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
    }

    private var welcomeBackground: some View {
        HStack(spacing: 0) {
            Group {
#if os(macOS)
                Color(nsColor: .windowBackgroundColor)
#else
                Color(uiColor: .systemBackground)
#endif
            }
            .frame(width: 340)

            Color.clear
        }
        .ignoresSafeArea()
    }

    private var rightPaneBackground: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 340)

            Group {
#if os(macOS)
                FrostedWindowMaterial(alpha: 0.8)
#else
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.8)
#endif
            }
            .overlay {
                FluidAmbientEffect()
                    .opacity(0.8)
                    .allowsHitTesting(false)
            }
            .clipped()
            .overlay(alignment: .leading) {
                Divider()
                    .opacity(0.55)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

private struct WelcomeActionButtons: View {
    let openPDF: () -> Void
    let openLastPDF: () -> Void
    let hasLastPDF: Bool

    var body: some View {
        VStack(spacing: 10) {
            Button(action: openPDF) {
                WelcomeButtonLabel(
                    title: "打开文件",
                    systemImage: "folder.fill"
                )
            }
            .buttonStyle(.glassProminent)
            .tint(Color(red: 0.98, green: 0.78, blue: 0.84))

            Button(action: openLastPDF) {
                WelcomeButtonLabel(
                    title: "回到上次",
                    systemImage: "clock.arrow.circlepath"
                )
            }
            .buttonStyle(.glass)
            .disabled(!hasLastPDF)
            .help(hasLastPDF ? "打开上一次使用的 PDF" : "还没有最近打开的 PDF")
        }
        .controlSize(.large)
    }
}

private struct WelcomeButtonLabel: View {
    let title: LocalizedStringResource
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .font(.headline)
        } icon: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 22)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

#if os(macOS)
private struct FrostedWindowMaterial: NSViewRepresentable {
    let alpha: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.alphaValue = alpha
        configureWindow(from: effectView)
        return effectView
    }

    func updateNSView(_ effectView: NSVisualEffectView, context: Context) {
        effectView.alphaValue = alpha
        configureWindow(from: effectView)
    }

    private func configureWindow(from effectView: NSVisualEffectView) {
        DispatchQueue.main.async {
            guard let window = effectView.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}
#endif

private struct FluidAmbientEffect: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let colors: [Color] = [
        Color(red: 1.000, green: 0.369, blue: 0.659),
        Color(red: 0.718, green: 0.361, blue: 1.000),
        Color(red: 0.388, green: 0.482, blue: 1.000),
        Color(red: 0.235, green: 0.796, blue: 0.922),
        Color(red: 1.000, green: 0.604, blue: 0.384),
        Color(red: 1.000, green: 0.369, blue: 0.659)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let drift = sin(time * 0.73) + sin(time * 1.37 + 1.9) * 0.46
            let orbitX = 0.5 + sin(time * 0.41 + sin(time * 0.17)) * 0.18
            let orbitY = 0.5 + cos(time * 0.53 + sin(time * 0.29)) * 0.18

            ZStack {
                AngularGradient(
                    colors: colors,
                    center: UnitPoint(x: orbitX, y: orbitY),
                    startAngle: .radians(drift),
                    endAngle: .radians(drift + .pi * 2)
                )
                .scaleEffect(1.3)
                .blur(radius: 32)

                AngularGradient(
                    colors: [
                        .clear,
                        .white.opacity(0.62),
                        Color(red: 1.000, green: 0.369, blue: 0.659).opacity(0.28),
                        .clear
                    ],
                    center: UnitPoint(
                        x: 0.5 + sin(time * 0.61 + 0.8) * 0.24,
                        y: 0.5 + cos(time * 0.47 + 1.4) * 0.22
                    ),
                    startAngle: .radians(-drift * 0.7),
                    endAngle: .radians(-drift * 0.7 + .pi * 2)
                )
                .scaleEffect(1.15)
                .blur(radius: 44)
            }
            .compositingGroup()
        }
    }
}

private struct NumericOptionShortcuts: View {
    let action: (Int) -> Void

    var body: some View {
        HStack {
            Button("选项 1") { action(1) }.keyboardShortcut("1", modifiers: [])
            Button("选项 2") { action(2) }.keyboardShortcut("2", modifiers: [])
            Button("选项 3") { action(3) }.keyboardShortcut("3", modifiers: [])
            Button("选项 4") { action(4) }.keyboardShortcut("4", modifiers: [])
        }
        .hidden()
    }
}

private struct KeyboardShortcuts: View {
    let previousPage: () -> Void
    let nextPage: () -> Void
    let openPDF: () -> Void
    let savePDF: () -> Bool

    var body: some View {
        HStack {
            Button("上一页", action: previousPage).keyboardShortcut(.upArrow, modifiers: [])
            Button("下一页", action: nextPage).keyboardShortcut(.downArrow, modifiers: [])
            Button("打开 PDF", action: openPDF).keyboardShortcut("o", modifiers: .command)
            Button("保存 PDF") { _ = savePDF() }.keyboardShortcut("s", modifiers: .control)
        }
        .hidden()
    }
}

#if os(macOS)
private struct WindowCloseGuard: NSViewRepresentable {
    let hasUnsavedChanges: Bool
    let saveCopy: () -> Bool
    let saveOriginal: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        updateCoordinator(context.coordinator)
        installGuard(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        updateCoordinator(context.coordinator)
        installGuard(from: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let window = view.window, window.delegate === coordinator {
            window.delegate = coordinator.previousDelegate
        }
    }

    private func updateCoordinator(_ coordinator: Coordinator) {
        coordinator.hasUnsavedChanges = hasUnsavedChanges
        coordinator.saveCopy = saveCopy
        coordinator.saveOriginal = saveOriginal
    }

    private func installGuard(from view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window, window.delegate !== coordinator else { return }
            coordinator.previousDelegate = window.delegate
            window.delegate = coordinator
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        weak var previousDelegate: (any NSWindowDelegate)?
        var hasUnsavedChanges = false
        var saveCopy: () -> Bool = { false }
        var saveOriginal: () -> Bool = { false }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if previousDelegate?.windowShouldClose?(sender) == false {
                return false
            }
            guard hasUnsavedChanges else { return true }

            let alert = NSAlert()
            alert.messageText = "是否保存修改？"
            alert.informativeText = "关闭前请选择保存为副本、覆盖原文件或放弃修改。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "保存为副本")
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "放弃修改")
            alert.addButton(withTitle: "取消")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return saveCopy()
            case .alertSecondButtonReturn:
                return saveOriginal()
            case .alertThirdButtonReturn:
                return true
            default:
                return false
            }
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (previousDelegate?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previousDelegate?.responds(to: selector) == true {
                return previousDelegate
            }
            return super.forwardingTarget(for: selector)
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onWindowAvailable: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        provideWindow(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        provideWindow(from: view, coordinator: context.coordinator)
    }

    private func provideWindow(from view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard !coordinator.didProvideWindow, let window = view.window else { return }
            coordinator.didProvideWindow = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            onWindowAvailable(window)
        }
    }

    final class Coordinator {
        var didProvideWindow = false
    }
}
#endif

#Preview {
    ContentView()
}
