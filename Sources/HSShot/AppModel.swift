import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

enum LibrarySection: String, CaseIterable {
    case all = "すべてのキャプチャ", images = "スクリーンショット", videos = "画面録画", favorites = "お気に入り", settings = "設定"
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .images: return "photo.on.rectangle"
        case .videos: return "video"
        case .favorites: return "star"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct CaptureStorageError: LocalizedError {
    let recoveryURL: URL
    let underlyingError: Error

    var errorDescription: String? {
        "ライブラリに保存できませんでした。撮影ファイルは次の場所に保持しています。\n\(recoveryURL.path)\n\(underlyingError.localizedDescription)"
    }
}

@MainActor final class AppModel: ObservableObject {
    let library: LibraryStore
    let captureService = CaptureService()
    let recorder = RecordingService()
    @Published var section: LibrarySection = .all
    @Published var search = ""
    @Published var selectedID: UUID?
    @Published var isBusy = false
    @Published var toast: String?
    @Published var errorMessage: String?
    @Published var scrollingFrames: [NSImage] = []
    @Published var scrollingActive = false
    @Published var scrollingError: String?
    @Published var screenPermission = CGPreflightScreenCaptureAccess()
    @AppStorage("captureDelay") var captureDelay = 0.0
    @AppStorage("autoCopy") var autoCopy = true
    @AppStorage("showQuickAccess") var showQuickAccess = true
    @AppStorage("recordAudio") var recordAudio = false

    var showWorkspace: () -> Void = {}
    var hideWorkspace: () -> Void = {}
    var restoreAfterCapture: (_ includeWorkspace: Bool) -> Void = { _ in }
    var showQuickPanel: (CaptureItem) -> Void = { _ in }
    var previewForEditing: (CaptureItem) -> QuickAccessPreviewState = { QuickAccessPreviewState(item: $0) }
    var refreshQuickPanels: () -> Void = {}
    var showPin: (NSImage) -> Void = { _ in }
    var showRecordingPanel: () -> Void = {}
    var showScrollPanel: () -> Void = {}
    var closeActivityPanels: () -> Void = {}
    private var subscriptions = Set<AnyCancellable>()
    private var scrollingFrameURLs: [URL] = []

    init(library: LibraryStore) {
        self.library = library
        library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    var filteredItems: [CaptureItem] {
        library.items.filter { item in
            let matchesSection = section == .all || section == .settings ||
                (section == .images && item.kind == .image) || (section == .videos && item.kind == .video) ||
                (section == .favorites && item.isFavorite)
            return matchesSection && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search))
        }
    }
    var selected: CaptureItem? { library.items.first { $0.id == selectedID } }
    var totalSize: String { ByteCountFormatter.string(fromByteCount: library.items.reduce(0) { $0 + $1.byteCount }, countStyle: .file) }

    func capture(_ mode: CaptureMode, delay: Double? = nil, forOCR: Bool = false) {
        guard !isBusy, !recorder.isRecording, !recorder.isFinishing, !scrollingActive else { return }
        isBusy = true
        hideWorkspace()
        Task {
            do {
                try await Task.sleep(nanoseconds: 280_000_000)
                let result = try await captureService.capture(mode, delay: delay ?? captureDelay)
                screenPermission = CGPreflightScreenCaptureAccess()
                if let url = result {
                    let item = try storeCapturedFile(url, title: Self.captureTitle())
                    selectedID = item.id
                    restoreAfterCapture(false)
                    if forOCR { recognize(item) }
                    else { captureFinished(item) }
                } else { restoreAfterCapture(true) }
            } catch { restoreAfterCapture(true); fail(error); showWorkspace() }
            isBusy = false
        }
    }

    /// Keep the completed capture recoverable until both the media and metadata persist.
    @discardableResult
    func storeCapturedFile(_ url: URL, title: String) throws -> CaptureItem {
        let item: CaptureItem
        do { item = try library.add(file: url, title: title) }
        catch { throw CaptureStorageError(recoveryURL: url, underlyingError: error) }
        try? FileManager.default.removeItem(at: url)
        return item
    }

    private func captureFinished(_ item: CaptureItem) {
        if autoCopy && item.kind == .image { copy(item, feedback: false) }
        if showQuickAccess { showQuickPanel(item) }
        else { showWorkspace(); notify("ライブラリに保存しました") }
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = true
        panel.prompt = "読み込む"
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    func importURLs(_ urls: [URL]) {
        for url in urls {
            do { let item = try library.add(file: url); selectedID = item.id }
            catch { fail(error) }
        }
        section = .all
    }

    func pasteImage() {
        guard let image = NSImage(pasteboard: .general) else { notify("クリップボードに画像がありません"); return }
        do { let item = try library.add(image: image, title: "ペーストした画像"); selectedID = item.id }
        catch { fail(error) }
    }

    func edit(_ item: CaptureItem) {
        guard item.kind == .image else {
            NSWorkspace.shared.open(library.url(for: item)); return
        }
        let preview = previewForEditing(item)
        let document: EditorDocument
        do { document = try preview.prepareDocument(using: library, preferences: EditorPreferences(defaults: .standard)) }
        catch { showWorkspace(); fail(error); return }
        preview.isEditing = true
        refreshQuickPanels()
        EditorWindow.open(sessionID: preview.sessionID, document: document, title: preview.originalItem.title, onSave: { [weak self] edited in
            guard let self else { throw LibraryError.missingFile }
            try self.saveEditedImage(edited, original: preview.originalItem, document: document, updating: preview)
        }, onClose: { [weak self] in
            preview.isEditing = false
            self?.refreshQuickPanels()
        })
    }

    @discardableResult
    func saveEditedImage(_ image: NSImage, original: CaptureItem, document: EditorDocument,
                         updating preview: QuickAccessPreviewState? = nil) throws -> CaptureItem {
        let sourceTitle = preview?.sourceTitle ?? original.title
        let project = try EditorProject(document: document, sourceTitle: sourceTitle)
        let saved = try library.add(image: image, project: project, title: "\(sourceTitle) — 編集済み")
        selectedID = saved.id
        preview?.replace(sourceID: original.id, with: saved)
        notify("編集した画像を保存しました")
        return saved
    }

    func copy(_ item: CaptureItem, feedback: Bool = true) {
        let pasteboard = NSPasteboard.general
        if item.kind == .image, let image = NSImage(contentsOf: library.url(for: item)) {
            pasteboard.clearContents(); pasteboard.writeObjects([image])
        } else {
            pasteboard.clearContents(); pasteboard.writeObjects([library.url(for: item) as NSURL])
        }
        if feedback { notify("コピーしました") }
    }

    func export(_ item: CaptureItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.title.replacingOccurrences(of: "/", with: "-") + "." + library.url(for: item).pathExtension
        panel.allowedContentTypes = item.kind == .image ? [.png] : [.mpeg4Movie, .quickTimeMovie]
        panel.prompt = "書き出す"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let source = library.url(for: item)
            guard source.standardizedFileURL != url.standardizedFileURL else { return }
            // Atomic write preserves the old file if reading or writing fails.
            try Data(contentsOf: source).write(to: url, options: .atomic)
            notify("書き出しました")
        } catch { fail(error) }
    }

    func pin(_ item: CaptureItem) {
        guard let image = NSImage(contentsOf: library.url(for: item)) else { return }
        showPin(image)
    }

    func favorite(_ item: CaptureItem) { do { try library.toggleFavorite(item.id) } catch { fail(error) } }
    func reveal(_ item: CaptureItem) { NSWorkspace.shared.activateFileViewerSelecting([library.url(for: item)]) }
    func delete(_ item: CaptureItem) {
        let alert = NSAlert()
        alert.messageText = "このキャプチャを削除しますか？"
        alert.informativeText = "ライブラリ内のファイルを削除します。書き出したファイルは残ります。"
        alert.addButton(withTitle: "削除"); alert.addButton(withTitle: "キャンセル")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try library.delete(item.id); if selectedID == item.id { selectedID = nil } }
        catch { fail(error) }
    }

    func recognize(_ item: CaptureItem) {
        guard item.kind == .image, let image = NSImage(contentsOf: library.url(for: item)) else { return }
        Task {
            do {
                let text = try await ImageServices.recognizeText(in: image)
                showWorkspace()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { notify("文字を検出できませんでした"); return }
                let alert = NSAlert()
                alert.messageText = "テキストを認識しました"
                alert.informativeText = "日本語・英語をMac上で読み取りました。"
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 260))
                let field = NSTextView(frame: scroll.bounds)
                field.string = text; field.isEditable = false
                field.isVerticallyResizable = true
                field.autoresizingMask = [.width]
                scroll.documentView = field; scroll.hasVerticalScroller = true
                alert.accessoryView = scroll
                alert.addButton(withTitle: "全文をコピー"); alert.addButton(withTitle: "閉じる")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    notify("テキストをコピーしました")
                }
            } catch { fail(error); showWorkspace() }
        }
    }

    func startRecording() {
        guard !isBusy, !recorder.isRecording, !recorder.isFinishing, !scrollingActive else { return }
        isBusy = true
        hideWorkspace()
        Task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                try await recorder.start(includeAudio: recordAudio)
                restoreAfterCapture(true)
                showRecordingPanel()
            } catch { restoreAfterCapture(true); fail(error); showWorkspace() }
            isBusy = false
        }
    }

    func stopRecording() {
        guard recorder.isRecording, !recorder.isFinishing else { return }
        Task {
            do {
                if let url = try await recorder.stop() {
                    let item = try storeCapturedFile(url, title: "画面録画 \(Self.captureTitle())")
                    selectedID = item.id
                    closeActivityPanels(); showWorkspace(); notify("録画を保存しました")
                }
            } catch { closeActivityPanels(); fail(error); showWorkspace() }
        }
    }

    func startScrolling() {
        guard !isBusy, !recorder.isRecording, !recorder.isFinishing, !scrollingActive else { return }
        scrollingError = nil
        scrollingFrames = []; scrollingActive = true
        hideWorkspace(); restoreAfterCapture(false); showScrollPanel()
    }

    func addScrollFrame() {
        guard scrollingActive, !isBusy else { return }
        isBusy = true
        scrollingError = nil
        hideWorkspace()
        Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                if let url = try await captureService.capture(.area, delay: 0) {
                    guard let image = NSImage(contentsOf: url) else {
                        throw CaptureStorageError(recoveryURL: url, underlyingError: LibraryError.invalidImage)
                    }
                    scrollingFrames.append(image)
                    scrollingFrameURLs.append(url)
                }
            } catch { scrollingError = error.localizedDescription }
            restoreAfterCapture(false)
            isBusy = false; showScrollPanel()
        }
    }

    func finishScrolling() {
        guard !scrollingFrames.isEmpty, !isBusy else { return }
        isBusy = true
        scrollingError = nil
        let frames = scrollingFrames
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) { try ImageServices.stitch(frames) }.value
                let item = try library.add(image: image, title: "スクロールキャプチャ \(Self.captureTitle())")
                removeScrollingTemporaryFiles()
                scrollingActive = false; scrollingFrames = []; closeActivityPanels(); showWorkspace()
                selectedID = item.id; edit(item)
            } catch { scrollingError = error.localizedDescription; showScrollPanel() }
            isBusy = false
        }
    }

    func cancelScrolling() {
        guard !isBusy else { return }
        removeScrollingTemporaryFiles()
        scrollingError = nil
        scrollingActive = false; scrollingFrames = []; closeActivityPanels(); showWorkspace()
    }

    private func removeScrollingTemporaryFiles() {
        scrollingFrameURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        scrollingFrameURLs = []
    }

    func requestPermission() {
        screenPermission = CGRequestScreenCaptureAccess()
        if !screenPermission { openScreenSettings() }
    }
    func openScreenSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    func notify(_ text: String) {
        toast = text
        Task { try? await Task.sleep(nanoseconds: 2_800_000_000); if toast == text { toast = nil } }
    }
    func fail(_ error: Error) { errorMessage = error.localizedDescription }
    static func captureTitle() -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }
}
