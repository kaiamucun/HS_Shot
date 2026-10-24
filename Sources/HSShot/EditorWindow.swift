import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum EditorWindow {
    private static var controllers: [UUID: EditorWindowController] = [:]

    static func open(image: NSImage, title: String, onSave: @escaping (NSImage) throws -> Void) {
        guard let document = EditorDocument(image: image, preferences: EditorPreferences(defaults: .standard)) else {
            let alert = NSAlert()
            alert.messageText = "画像を開けませんでした"
            alert.informativeText = "読み込める画像は最大 6,400 万ピクセルです。画像形式とサイズを確認してください。"
            alert.runModal()
            return
        }
        let id = UUID()
        let controller = EditorWindowController(document: document, title: title, onSave: onSave)
        controller.onClose = { controllers.removeValue(forKey: id) }
        controllers[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(document: EditorDocument, title: String, onSave: @escaping (NSImage) throws -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(title) — HS Shot"
        window.minSize = NSSize(width: 900, height: 600)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(ShotTheme.background)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: EditorWorkspace(document: document, imageTitle: title, onSave: onSave))
        window.appearance = NSAppearance(named: .aqua)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) {
        let callback = onClose
        onClose = nil
        callback?()
    }
}

@MainActor
private struct EditorWorkspace: View {
    @ObservedObject var document: EditorDocument
    let imageTitle: String
    let onSave: (NSImage) throws -> Void
    @State private var exportJPEG = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(ShotTheme.border).frame(height: 1)
            HStack(spacing: 0) {
                toolRail
                CanvasHost(document: document)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                inspector
            }
            footer
        }
        .background(ShotTheme.background)
        .foregroundStyle(ShotTheme.text)
        .tint(ShotTheme.accent)
        .preferredColorScheme(.light)
        .background {
            Group {
                Button("元に戻す", action: document.undo).keyboardShortcut("z", modifiers: .command).disabled(!document.canUndo)
                Button("やり直す", action: document.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!document.canRedo)
            }.hidden()
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Image(systemName: "viewfinder").font(.system(size: 22, weight: .semibold)).foregroundStyle(ShotTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("画像を仕上げる").font(.system(size: 16, weight: .semibold))
                Text(imageTitle).font(.system(size: 11)).foregroundStyle(ShotTheme.muted).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 4) {
                Button(action: document.undo) { Image(systemName: "arrow.uturn.backward").frame(width: 30, height: 28) }
                    .help("元に戻す ⌘Z").disabled(!document.canUndo)
                Button(action: document.redo) { Image(systemName: "arrow.uturn.forward").frame(width: 30, height: 28) }
                    .help("やり直す ⇧⌘Z").disabled(!document.canRedo)
            }.buttonStyle(.borderless)
            Rectangle().fill(ShotTheme.border).frame(width: 1, height: 24)
            Button(action: copyImage) { Label("コピー", systemImage: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: .command)
            Button(action: exportImage) { Label("書き出す", systemImage: "square.and.arrow.up") }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button(action: saveToLibrary) {
                Label("ライブラリに保存", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ShotTheme.onAccent)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(ShotTheme.accent, in: RoundedRectangle(cornerRadius: 7))
            }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.plain)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
        .background(ShotTheme.panel)
    }

    private var toolRail: some View {
        VStack(spacing: 4) {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    document.tool = tool
                    if tool != .select { document.select(nil) }
                    document.status = tool == .select ? "注釈をクリックして選択 / 文字はダブルクリックで修正 / 矢印・線は両端を調整" : tool == .text ? "画像をクリックして入力。Enter で確定 / Esc で取消" : tool == .number ? "画像をクリックして連番を配置" : "\(tool.title)：画像の上をドラッグ"
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 42, height: 35)
                        .foregroundStyle(document.tool == tool ? ShotTheme.onAccent : ShotTheme.muted)
                        .background(document.tool == tool ? ShotTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .help(tool.title + (tool.keyHint.isEmpty ? "" : " (\(tool.keyHint))"))
                .accessibilityLabel(tool.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .frame(width: 66)
        .background(ShotTheme.sidebar)
    }

    private var inspectorTool: EditorTool { document.selectedAnnotation?.tool ?? document.tool }
    private var inspector: some View {
        ScrollView {
            inspectorContent
        }
        .frame(width: 234)
        .frame(maxHeight: .infinity)
        .background(ShotTheme.panel)
    }
    private var inspectorContent: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 7) {
                Text(document.selectedAnnotationID == nil ? "編集ツール" : "選択した注釈").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(ShotTheme.muted)
                Label(inspectorTool.title, systemImage: inspectorTool.symbol).font(.system(size: 18, weight: .semibold))
            }
            Divider().overlay(ShotTheme.border)
            VStack(alignment: .leading, spacing: 12) {
                inspectorLabel("スタイル")
                if ![EditorTool.redact, .pixelate, .crop].contains(inspectorTool) {
                    ColorPicker("カラー", selection: Binding(get: { Color(nsColor: document.inspectorColor) }, set: { document.setColor(NSColor($0)) }), supportsOpacity: false)
                        .font(.system(size: 12))
                    HStack(spacing: 9) {
                        ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                            Button { document.setColor(color) } label: {
                                Circle().fill(Color(nsColor: color)).frame(width: 21, height: 21)
                                    .overlay(Circle().stroke(ShotTheme.border, lineWidth: 1))
                                    .overlay(Circle().stroke(document.inspectorColor.isEqual(color) ? ShotTheme.accent : .clear, lineWidth: 2).padding(-3))
                            }.buttonStyle(.plain).accessibilityLabel("注釈カラー")
                        }
                    }
                }
                if ![EditorTool.text, .number, .highlight, .redact, .pixelate, .crop].contains(inspectorTool) {
                    HStack {
                        Text("線の太さ").font(.system(size: 12))
                        Spacer()
                        Text("\(Int(document.inspectorLineWidth)) px").font(.system(size: 11, design: .monospaced)).foregroundStyle(ShotTheme.muted)
                    }.padding(.top, 8)
                    Slider(value: Binding(get: { document.inspectorLineWidth }, set: document.setLineWidth), in: 1...20, step: 1)
                }
                if [.text, .number].contains(inspectorTool) || (document.tool == .select && document.selectedAnnotationID == nil) {
                    HStack {
                        Text("文字サイズ").font(.system(size: 12))
                        Spacer()
                        Text("\(Int(document.inspectorFontSize)) px").font(.system(size: 11, design: .monospaced)).foregroundStyle(ShotTheme.muted)
                    }
                    Slider(value: Binding(get: { document.inspectorFontSize }, set: document.setFontSize), in: 12...160, step: 1)
                }
            }
            if document.tool == .select {
                VStack(alignment: .leading, spacing: 10) {
                    Text(document.selectedAnnotation.map(AnnotationCanvas.selectionHelp) ?? "クリックで選択、ドラッグで移動。文字はダブルクリックで修正、矢印・線は両端の丸で調整できます。")
                        .font(.system(size: 11)).foregroundStyle(ShotTheme.muted)
                    if document.selectedAnnotationID != nil {
                        Button(role: .destructive, action: document.removeSelected) {
                            Label("選択した注釈を削除", systemImage: "trash")
                        }.font(.system(size: 11))
                    }
                }
            }
            if document.tool == .text {
                VStack(alignment: .leading, spacing: 9) {
                    inspectorLabel("テキスト")
                    TextField("配置するテキスト", text: $document.text, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...4)
                    Text("画像をクリック → 入力 → Enter で確定").font(.system(size: 10)).foregroundStyle(ShotTheme.muted)
                }
            }
            if inspectorTool == .redact || inspectorTool == .pixelate {
                Text(inspectorTool == .redact ? "秘匿範囲は不透明な黒で塗りつぶします。共有前に出力画像をご確認ください。" : "ピクセル化は装飾用です。機密情報には「塗りつぶし秘匿」を使用してください。")
                    .font(.system(size: 11)).foregroundStyle(ShotTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(ShotTheme.border)
            VStack(alignment: .leading, spacing: 13) {
                inspectorLabel("背景と余白")
                Picker("背景", selection: Binding(get: { document.state.background }, set: { value in document.change { $0.background = value } })) {
                    ForEach(EditorBackground.allCases) { background in Text(background.title).tag(background) }
                }.labelsHidden().frame(maxWidth: .infinity)
                HStack {
                    Text("余白").font(.system(size: 12))
                    Spacer()
                    Picker("余白", selection: Binding(get: { document.state.padding }, set: document.setPadding)) {
                        ForEach(Array(Set([0, 16, 32, 64, 96, 128, document.state.padding])).sorted(), id: \.self) { Text("\($0) px").tag($0) }
                    }.labelsHidden().frame(width: 96)
                }
                if document.state.crop != nil {
                    Button("切り抜きを解除") { document.change { $0.crop = nil } }.font(.system(size: 11))
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                inspectorLabel("書き出し形式")
                Picker("形式", selection: $exportJPEG) {
                    Text("PNG").tag(false)
                    Text("JPEG").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                Text(exportJPEG ? "JPEG・高画質 / 透明部分は白" : "PNG・ロスレス / 透明背景に対応")
                    .font(.system(size: 10)).foregroundStyle(ShotTheme.muted)
                HStack {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                    Text(document.dimensions).fontDesign(.monospaced)
                }.font(.system(size: 11)).foregroundStyle(ShotTheme.muted)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Circle().fill(ShotTheme.accent).frame(width: 5, height: 5)
            Text(document.status).lineLimit(1)
            Spacer()
            Text("\(document.state.annotations.count) 個の注釈")
            Text("・")
            Text("原本は保持されます")
        }
        .font(.system(size: 10))
        .foregroundStyle(ShotTheme.muted)
        .padding(.horizontal, 20)
        .frame(height: 32)
        .background(ShotTheme.panel)
        .overlay(alignment: .top) { Rectangle().fill(ShotTheme.border).frame(height: 1) }
    }
    private func inspectorLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(ShotTheme.muted)
    }
    private var palette: [NSColor] {
        [NSColor(ShotTheme.accent), .systemRed, .systemOrange, .systemBlue, .white, .black]
    }
    private func saveToLibrary() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        do {
            try document.saveToLibrary(using: onSave)
        } catch {
            document.status = "ライブラリへの保存に失敗しました"
            showFailure(error.localizedDescription)
        }
    }
    private func copyImage() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard let image = document.exportedImage(), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { showFailure("画像のコピーに失敗しました。"); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        document.status = "編集した画像をコピーしました"
    }
    private func exportImage() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard let image = document.exportedImage(), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { showFailure("画像の生成に失敗しました。余白や切り抜き範囲を調整してください。"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [exportJPEG ? .jpeg : .png]
        panel.nameFieldStringValue = imageTitle.replacingOccurrences(of: "/", with: "-") + "-edited." + (exportJPEG ? "jpg" : "png")
        panel.title = "編集した画像を書き出す"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var output = cg
        if exportJPEG, let context = EditorRenderer.context(width: cg.width, height: cg.height) {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            if let flattened = context.makeImage() { output = flattened }
        }
        guard let data = NSBitmapImageRep(cgImage: output).representation(using: exportJPEG ? .jpeg : .png, properties: [.compressionFactor: 0.92]) else { showFailure("選択した形式で書き出せませんでした。"); return }
        do {
            try data.write(to: url, options: .atomic)
            document.status = "\(url.lastPathComponent) を書き出しました"
        } catch { showFailure(error.localizedDescription) }
    }
    private func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "操作を完了できませんでした"
        alert.informativeText = message
        alert.runModal()
    }
}

@MainActor
private struct CanvasHost: NSViewRepresentable {
    @ObservedObject var document: EditorDocument
    func makeNSView(context: Context) -> AnnotationCanvas { AnnotationCanvas(document: document) }
    func updateNSView(_ view: AnnotationCanvas, context: Context) { view.needsDisplay = true }
}
