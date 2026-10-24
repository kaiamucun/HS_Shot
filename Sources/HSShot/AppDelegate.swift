import AppKit
import SwiftUI
import Carbon
import Combine

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var model: AppModel!
    private var mainWindow: NSWindow!
    private var statusItem: NSStatusItem!
    private var quickPanels: [(panel: NSPanel, preview: QuickAccessPreviewState)] = []
    private var pins: [NSWindow] = []
    private var activityPanel: NSPanel?
    private var captureHiddenWindows: [NSWindow] = []
    private var hotKeys: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) { NSApp.applicationIconImage = icon }
        do {
            let root = ProcessInfo.processInfo.environment["HSSHOT_LIBRARY_PATH"].map { URL(fileURLWithPath: $0) }
            model = AppModel(library: try LibraryStore(root: root))
        } catch {
            let alert = NSAlert(error: error); alert.runModal(); NSApp.terminate(nil); return
        }
        model.showWorkspace = { [weak self] in self?.showMainWindow() }
        model.hideWorkspace = { [weak self] in self?.hideForCapture() }
        model.restoreAfterCapture = { [weak self] includeWorkspace in self?.restoreAfterCapture(includeWorkspace: includeWorkspace) }
        model.showQuickPanel = { [weak self] in self?.showQuickAccess($0) }
        model.previewForEditing = { [weak self] item in
            guard let self else { return QuickAccessPreviewState(item: item) }
            if let preview = self.quickPanels.first(where: { $0.preview.represents(item.id) })?.preview { return preview }
            return self.showQuickAccess(item)
        }
        model.refreshQuickPanels = { [weak self] in self?.refreshQuickPanels() }
        model.showPin = { [weak self] in self?.pin($0) }
        model.showRecordingPanel = { [weak self] in self?.showActivity(recording: true) }
        model.showScrollPanel = { [weak self] in self?.showActivity(recording: false) }
        model.closeActivityPanels = { [weak self] in self?.activityPanel?.close(); self?.activityPanel = nil }
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification).sink { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.captureHiddenWindows.removeAll { $0 === window }
        }.store(in: &subscriptions)
        model.recorder.$lastError.compactMap { $0 }.sink { [weak self] message in
            guard let self else { return }
            self.restoreAfterCapture(includeWorkspace: true)
            self.activityPanel?.close(); self.activityPanel = nil
            self.model.errorMessage = message; self.showMainWindow()
        }.store(in: &subscriptions)

        buildMainMenu()
        buildStatusMenu()
        registerHotKeys()
        mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        mainWindow.title = "HS Shot"
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.titleVisibility = .hidden
        mainWindow.toolbarStyle = .unified
        mainWindow.minSize = NSSize(width: 1020, height: 700)
        mainWindow.backgroundColor = NSColor(ShotTheme.background)
        mainWindow.appearance = NSAppearance(named: .aqua)
        mainWindow.contentView = NSHostingView(rootView: WorkspaceView(model: model).padding(.top, 24).background(ShotTheme.background))
        mainWindow.isReleasedWhenClosed = false
        mainWindow.delegate = self
        mainWindow.center()
        mainWindow.setFrameAutosaveName("HSShotWorkspace")
        showMainWindow()

        // A deterministic fixture is opt-in and always uses an isolated library.
        if let fixture = ProcessInfo.processInfo.environment["HSSHOT_IMPORT_FIXTURE"] {
            model.importURLs([URL(fileURLWithPath: fixture)])
            if let item = model.library.items.first { showQuickAccess(item) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.screenPermission = CGPreflightScreenCaptureAccess()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard model?.isBusy != true else { return false }
        showMainWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.recorder.isRecording || model.recorder.isFinishing {
            let alert = NSAlert()
            alert.messageText = "録画を保存してから終了してください"
            alert.informativeText = "メニューバーまたは録画パネルの停止ボタンで、録画を保存できます。"
            alert.addButton(withTitle: "戻る"); alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }

    func showMainWindow() {
        guard mainWindow != nil else { return }
        NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)
        refreshQuickPanels()
    }
    private func hideForCapture() {
        // Editors and floating pins are independent AppKit windows. Capture every
        // visible app window, keeping its order so they can be restored afterward.
        let ordered = NSApp.orderedWindows.filter(\.isVisible)
        let visible = ordered + NSApp.windows.filter { window in
            window.isVisible && !ordered.contains(where: { $0 === window })
        }
        for window in visible where !captureHiddenWindows.contains(where: { $0 === window }) {
            captureHiddenWindows.append(window)
        }
        NSApp.windows.filter(\.isVisible).forEach { $0.orderOut(nil) }
    }

    private func restoreAfterCapture(includeWorkspace: Bool) {
        let windows = captureHiddenWindows
        captureHiddenWindows = []
        for window in windows.reversed() {
            guard includeWorkspace || window !== mainWindow,
                  NSApp.windows.contains(where: { $0 === window }) else { continue }
            window.orderFrontRegardless()
        }
    }

    private func buildMainMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(); menu.addItem(app)
        let appMenu = NSMenu(); app.submenu = appMenu
        appMenu.addItem(withTitle: "HS Shotについて", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(withTitle: "設定…", action: #selector(settings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "HS Shotを隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "HS Shotを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(); menu.addItem(file); file.submenu = NSMenu(title: "ファイル")
        file.submenu?.addItem(withTitle: "画像・動画を読み込む…", action: #selector(importFile), keyEquivalent: "o")
        file.submenu?.addItem(withTitle: "ライブラリを表示", action: #selector(openLibrary), keyEquivalent: "1")
        let edit = NSMenuItem(); menu.addItem(edit); edit.submenu = NSMenu(title: "編集")
        edit.submenu?.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.submenu?.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "z"); redo?.keyEquivalentModifierMask = [.command, .shift]
        edit.submenu?.addItem(.separator())
        edit.submenu?.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.submenu?.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenuItem(); menu.addItem(window); let windowMenu = NSMenu(title: "ウィンドウ"); window.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }

    private func buildStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "HS Shot")
        let menu = NSMenu()
        menu.addItem(withTitle: "HS Shot", action: #selector(openLibrary), keyEquivalent: "")
        menu.addItem(.separator())
        for (title, action) in [("範囲を選択  ⌘⇧2", #selector(captureArea)), ("ウィンドウ  ⌘⇧7", #selector(captureWindow)), ("画面全体  ⌘⇧6", #selector(captureScreen)), ("テキストを認識  ⌘⇧8", #selector(captureText)), ("スクロール結合…", #selector(scrollCapture)), ("録画を開始・停止  ⌘⇧9", #selector(toggleRecording))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "ライブラリを表示", action: #selector(openLibrary), keyEquivalent: "")
        menu.addItem(withTitle: "設定…", action: #selector(settings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func registerHotKeys() {
        var handler: EventHandlerRef?
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard status == noErr else { return status }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            let id = key.id
            Task { @MainActor in delegate.handleHotKey(id) }
            return noErr
        }, 1, &spec, pointer, &handler)
        hotKeyHandler = handler
        var unavailable: [String] = []
        for (id, key, label) in [(UInt32(1), kVK_ANSI_2, "⌘⇧2"), (2, kVK_ANSI_6, "⌘⇧6"), (3, kVK_ANSI_7, "⌘⇧7"), (4, kVK_ANSI_8, "⌘⇧8"), (5, kVK_ANSI_9, "⌘⇧9")] {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x48535348, id: id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { hotKeys.append(ref) } else { unavailable.append(label) }
        }
        if !unavailable.isEmpty { model.notify("ショートカット競合: \(unavailable.joined(separator: ", "))。メニューバーから操作できます。") }
    }
    private func handleHotKey(_ id: UInt32) {
        switch id {
        case 1: captureArea()
        case 2: captureScreen()
        case 3: captureWindow()
        case 4: captureText()
        case 5: toggleRecording()
        default: break
        }
    }

    private func refreshQuickPanels() {
        for (panel, preview) in quickPanels {
            if preview.isEditing { panel.orderOut(nil) }
            else { panel.orderFrontRegardless() }
        }
    }

    @discardableResult
    private func showQuickAccess(_ item: CaptureItem) -> QuickAccessPreviewState {
        refreshQuickPanels()
        // Keep the newest four previews stacked at the lower-left until explicitly dismissed.
        if quickPanels.count >= 4 { quickPanels.removeFirst().panel.close() }
        let size = QuickAccessGeometry.panelSize(for: CGSize(width: item.width, height: item.height))
        let panel = makePanel(width: size.width, height: size.height)
        panel.isMovableByWindowBackground = true
        let preview = QuickAccessPreviewState(item: item)
        panel.contentView = NSHostingView(rootView: QuickAccessView(model: model, preview: preview, size: size) { [weak self, weak panel] in
            guard let panel else { return }; panel.close(); self?.quickPanels.removeAll { $0.panel === panel }
        })
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let position = NSPoint(x: visible.minX + 20 + CGFloat(quickPanels.count) * 18,
            y: visible.minY + 20 + CGFloat(quickPanels.count) * 24)
        panel.setFrameOrigin(position)
        quickPanels.append((panel, preview))
        panel.orderFrontRegardless()
        return preview
    }

    private func showActivity(recording: Bool) {
        activityPanel?.close()
        let panel = makePanel(width: recording ? 292 : 390,
            height: recording ? 72 : (model.scrollingError == nil ? 184 : 300))
        if recording { panel.contentView = NSHostingView(rootView: RecordingPanelView(model: model)) }
        else { panel.contentView = NSHostingView(rootView: ScrollPanelView(model: model)) }
        let visible = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 30))
        panel.isMovableByWindowBackground = true
        activityPanel = panel; panel.orderFrontRegardless()
    }

    private func makePanel(width: CGFloat, height: CGFloat) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .aqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func pin(_ image: NSImage) {
        let size = image.size
        let width: CGFloat = min(560, max(220, size.width))
        let height = max(160, min(600, width * size.height / max(size.width, 1)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height + 38), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ピン留め · HS Shot"
        window.appearance = NSAppearance(named: .aqua)
        window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: PinnedImageView(image: image, opacityChanged: { [weak window] value in window?.alphaValue = value }))
        window.center(); pins.append(window); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { pins.removeAll { $0 === window } }
    }

    @objc private func captureArea() { model.capture(.area) }
    @objc private func captureWindow() { model.capture(.window) }
    @objc private func captureScreen() { model.capture(.fullScreen) }
    @objc private func captureText() { model.capture(.area, forOCR: true) }
    @objc private func scrollCapture() { model.startScrolling() }
    @objc private func toggleRecording() { if model.recorder.isRecording { model.stopRecording() } else { model.startRecording() } }
    @objc private func openLibrary() { showMainWindow() }
    @objc private func importFile() { model.importFiles() }
    @objc private func settings() { model.section = .settings; showMainWindow() }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "HS Shot", .credits: NSAttributedString(string: "撮る。整える。伝わる。\nmacOS専用 · ローカルで完結")])
    }
}

private struct QuickAccessView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preview: QuickAccessPreviewState
    private var item: CaptureItem { preview.item }
    let size: CGSize
    let close: () -> Void
    @State private var hovering = false
    var body: some View {
        ZStack {
            ShotTheme.canvas
            Button(action: edit) {
                Group {
                    if let image = NSImage(contentsOf: model.library.url(for: item)) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo").foregroundStyle(ShotTheme.muted)
                    }
                }.frame(width: size.width, height: size.height)
                    .blur(radius: hovering ? 6 : 0)
                    .overlay { if hovering { Color.gray.opacity(0.28).allowsHitTesting(false) } }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("キャプチャを編集")
                .help("クリックして注釈エディタを開く")
                .onDrag { NSItemProvider(contentsOf: model.library.url(for: item)) ?? NSItemProvider() }
            if hovering {
                VStack(spacing: 8) {
                    pillButton("コピー") { model.copy(item) }
                    pillButton("保存", action: save)
                }
            }
        }.frame(width: size.width, height: size.height)
            .foregroundStyle(ShotTheme.text)
            .overlay(alignment: .topLeading) {
                if hovering { cornerButton("プレビューを閉じる", "xmark", action: close).padding(6) }
            }
            .overlay(alignment: .topTrailing) {
                if hovering { cornerButton("ピン留め", "pin.fill") { model.pin(item) }.padding(6) }
            }
            .overlay(alignment: .bottomLeading) {
                if hovering { cornerButton("編集", "pencil.tip", action: edit).padding(6) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.9), lineWidth: 1))
            .onHover { hovering = $0 }
            .contextMenu {
                Button("編集", systemImage: "pencil.tip", action: edit)
                Button("コピー", systemImage: "doc.on.doc") { model.copy(item) }
                Button("保存", systemImage: "square.and.arrow.down", action: save)
                Button("ピン留め", systemImage: "pin") { model.pin(item) }
                Divider()
                Button("プレビューを閉じる", systemImage: "xmark", action: close)
            }
            .preferredColorScheme(.light)
    }
    private func cornerButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22).background(ShotTheme.panel.opacity(0.92), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
    }
    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .frame(width: 66, height: 24).background(ShotTheme.panel.opacity(0.92), in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
    }
    private func edit() {
        NSApp.activate(ignoringOtherApps: true)
        model.edit(item)
    }
    private func save() {
        NSApp.activate(ignoringOtherApps: true)
        model.export(item)
    }
}

private struct RecordingPanelView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(.red).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.recorder.isFinishing ? "録画を保存中…" : "画面を録画中").font(.system(size: 11, weight: .semibold))
                Text(String(format: "%02d:%02d", Int(model.recorder.elapsed) / 60, Int(model.recorder.elapsed) % 60)).font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(ShotTheme.muted)
            }
            Spacer()
            Button { model.stopRecording() } label: { Image(systemName: "stop.fill").foregroundStyle(.white).frame(width: 36, height: 36).background(.red, in: RoundedRectangle(cornerRadius: 8)) }
                .buttonStyle(.plain).disabled(model.recorder.isFinishing).help("録画を停止して保存")
        }.padding(17).foregroundStyle(ShotTheme.text).background(ShotTheme.panel, in: RoundedRectangle(cornerRadius: 13)).preferredColorScheme(.light)
    }
}

private struct ScrollPanelView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("スクロール結合", systemImage: "rectangle.expand.vertical").font(.system(size: 13, weight: .semibold)); Spacer(); Text("\(model.scrollingFrames.count)枚").font(.system(size: 11, design: .monospaced)).foregroundStyle(ShotTheme.accent) }
            Text("同じ幅の範囲を撮影し、下へスクロールして追加。\n前の画像が1/3程度重なるように選んでください。")
                .font(.system(size: 10)).lineSpacing(4).foregroundStyle(ShotTheme.muted)
            if let error = model.scrollingError {
                HStack(alignment: .top, spacing: 8) {
                    ScrollView {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red.opacity(0.9))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 94)
                    Button { model.scrollingError = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(ShotTheme.muted).help("エラーを閉じる")
                }
            }
            HStack {
                Button("キャンセル") { model.cancelScrolling() }.buttonStyle(.plain).foregroundStyle(ShotTheme.muted).disabled(model.isBusy)
                Spacer()
                Button("＋ 範囲を撮影") { model.addScrollFrame() }.disabled(model.isBusy)
                Button("結合して編集") { model.finishScrolling() }.tint(ShotTheme.accent).disabled(model.scrollingFrames.isEmpty || model.isBusy)
            }.font(.system(size: 11))
            if model.isBusy { ProgressView().controlSize(.small) }
        }.padding(18).foregroundStyle(ShotTheme.text).background(ShotTheme.panel, in: RoundedRectangle(cornerRadius: 13)).preferredColorScheme(.light)
    }
}

private struct PinnedImageView: View {
    let image: NSImage
    let opacityChanged: (Double) -> Void
    @State private var opacity = 1.0
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack { Image(systemName: "circle.lefthalf.filled"); Slider(value: $opacity, in: 0.2...1).onChange(of: opacity) { _, value in opacityChanged(value) }; Button("コピー") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) } }.font(.system(size: 10)).padding(9)
        }.foregroundStyle(ShotTheme.text).background(ShotTheme.background).preferredColorScheme(.light)
    }
}
