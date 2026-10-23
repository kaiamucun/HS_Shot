import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

enum ShotTheme {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.085)
    static let sidebar = Color(red: 0.075, green: 0.087, blue: 0.105)
    static let panel = Color(red: 0.10, green: 0.115, blue: 0.135)
    static let muted = Color(red: 0.53, green: 0.57, blue: 0.62)
    static let lime = Color(red: 0.79, green: 0.96, blue: 0.43)
    static let border = Color.white.opacity(0.075)
}

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var dropTarget = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 224)
            Rectangle().fill(ShotTheme.border).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(ShotTheme.border).frame(height: 1)
                if model.section == .settings { SettingsView(model: model) }
                else { content }
                footer
            }
        }
        .background(ShotTheme.background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .font(.system(size: 13))
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(ShotTheme.lime)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 44)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.importURLs([url]) }
                }
            }
            return true
        }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 12).stroke(ShotTheme.lime, lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .alert("操作を完了できませんでした", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("閉じる", role: .cancel) { model.errorMessage = nil }
            Button("画面収録の設定") { model.openScreenSettings(); model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(ShotTheme.lime).frame(width: 38, height: 38)
                    Image(systemName: "viewfinder").font(.system(size: 23, weight: .medium)).foregroundStyle(ShotTheme.background)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("HS Shot").font(.system(size: 20, weight: .bold, design: .rounded)).tracking(-0.5)
                    Text("CAPTURE YOUR CLARITY").font(.system(size: 7, weight: .semibold)).tracking(1.4).foregroundStyle(ShotTheme.muted)
                }
            }.padding(.top, 32).padding(.bottom, 32).padding(.horizontal, 22)

            Button { model.capture(.area) } label: {
                HStack { Image(systemName: "plus").font(.system(size: 13, weight: .bold)); Text("新規キャプチャ").fontWeight(.semibold); Spacer(); Text("⌘⇧2").font(.system(size: 10, design: .monospaced)).opacity(0.6) }
                    .foregroundStyle(ShotTheme.background).padding(.horizontal, 13).frame(height: 40)
                    .background(ShotTheme.lime, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).padding(.horizontal, 16).disabled(model.isBusy)

            Text("ライブラリ").font(.system(size: 10, weight: .semibold)).foregroundStyle(ShotTheme.muted).padding(.leading, 25).padding(.top, 30).padding(.bottom, 10)
            ForEach([LibrarySection.all, .images, .videos, .favorites], id: \.self) { section in
                Button { model.section = section; model.selectedID = nil } label: {
                    HStack(spacing: 11) {
                        Image(systemName: section.icon).font(.system(size: 14)).frame(width: 18)
                        Text(section.rawValue).font(.system(size: 12, weight: model.section == section ? .semibold : .regular))
                        Spacer()
                        Text("\(count(section))").font(.system(size: 10, design: .monospaced)).foregroundStyle(ShotTheme.muted)
                    }.foregroundStyle(model.section == section ? ShotTheme.lime : Color.white.opacity(0.62))
                        .padding(.horizontal, 12).frame(height: 39)
                        .background(model.section == section ? ShotTheme.lime.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).padding(.horizontal, 13)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "lock.shield").font(.system(size: 20, weight: .light)).foregroundStyle(ShotTheme.lime.opacity(0.7))
                Text("あなたのMacに。\nあなたのアイデアを。").font(.system(size: 15, weight: .medium)).lineSpacing(4)
                Text("キャプチャはローカルに保存。\n外部への自動送信はありません。")
                    .font(.system(size: 10)).lineSpacing(4).foregroundStyle(ShotTheme.muted)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(ShotTheme.panel.opacity(0.55), in: RoundedRectangle(cornerRadius: 10)).padding(16)
            Divider().overlay(ShotTheme.border).padding(.horizontal, 20)
            Button { model.section = .settings } label: {
                HStack(spacing: 10) { Image(systemName: "slider.horizontal.3"); Text("設定"); Spacer(); Text("1.0").font(.system(size: 10, design: .monospaced)) }
                    .foregroundStyle(model.section == .settings ? ShotTheme.lime : ShotTheme.muted).padding(24)
            }.buttonStyle(.plain)
        }.background(ShotTheme.sidebar)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.section.rawValue).font(.system(size: 19, weight: .semibold)).tracking(-0.4)
                Text(model.section == .settings ? "いつもの撮影を、あなたらしく。" : "ひらめきを、いちばん伝わる1枚に。")
                    .font(.system(size: 11)).foregroundStyle(ShotTheme.muted)
            }
            Spacer()
            if model.section != .settings {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ShotTheme.muted)
                    TextField("キャプチャを検索", text: $model.search).textFieldStyle(.plain).font(.system(size: 11))
                }.padding(10).frame(width: 188).background(ShotTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                Button { model.importFiles() } label: { Label("読み込む", systemImage: "square.and.arrow.down").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.plain).padding(10).background(ShotTheme.panel, in: RoundedRectangle(cornerRadius: 7))
            }
        }.padding(.horizontal, 30).frame(height: 88)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                if model.search.isEmpty && model.section == .all { captureLauncher }
                HStack {
                    Text(model.search.isEmpty ? "最近のキャプチャ" : "検索結果").font(.system(size: 14, weight: .semibold))
                    Text("\(model.filteredItems.count)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(ShotTheme.muted)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(ShotTheme.panel, in: Capsule())
                    Spacer()
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 11)).foregroundStyle(ShotTheme.lime)
                    Text("新しい順").font(.system(size: 10)).foregroundStyle(ShotTheme.muted)
                }
                if model.filteredItems.isEmpty { emptyState }
                else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 17)], spacing: 20) {
                        ForEach(model.filteredItems) { item in
                            CaptureCard(item: item, url: model.library.url(for: item), selected: model.selectedID == item.id)
                                .onTapGesture { model.selectedID = item.id }
                                .onTapGesture(count: 2) { model.edit(item) }
                                .contextMenu { itemMenu(item) }
                                .onDrag { NSItemProvider(contentsOf: model.library.url(for: item)) ?? NSItemProvider() }
                        }
                    }
                }
                if let item = model.selected { selectedActions(item) }
            }.padding(30)
        }
    }

    private var captureLauncher: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                HStack(spacing: 7) { Circle().fill(ShotTheme.lime).frame(width: 5, height: 5); Text("READY WHEN YOU ARE").font(.system(size: 8, weight: .semibold)).tracking(1.8).foregroundStyle(ShotTheme.lime) }
                Spacer()
                Menu {
                    Button("遅延なし") { model.captureDelay = 0 }
                    Button("3秒後に撮影") { model.captureDelay = 3 }
                    Button("5秒後に撮影") { model.captureDelay = 5 }
                    Button("10秒後に撮影") { model.captureDelay = 10 }
                } label: {
                    Label(model.captureDelay == 0 ? "タイマーなし" : "\(Int(model.captureDelay))秒タイマー", systemImage: "timer")
                        .font(.system(size: 10)).foregroundStyle(ShotTheme.muted)
                }.menuStyle(.borderlessButton).fixedSize()
            }
            HStack(alignment: .firstTextBaseline) {
                Text("見たままを、伝わるかたちに。").font(.system(size: 25, weight: .medium)).tracking(-1)
                Spacer()
                Text("撮る。整える。共有する。").font(.system(size: 10)).foregroundStyle(ShotTheme.muted)
            }
            HStack(spacing: 10) {
                CaptureAction(title: "範囲を選択", subtitle: "⌘ ⇧ 2", icon: "viewfinder", accent: true) { model.capture(.area) }
                CaptureAction(title: "ウィンドウ", subtitle: "⌘ ⇧ 7", icon: "macwindow") { model.capture(.window) }
                CaptureAction(title: "画面全体", subtitle: "⌘ ⇧ 6", icon: "display") { model.capture(.fullScreen) }
                CaptureAction(title: "画面を録画", subtitle: "⌘ ⇧ 9", icon: "record.circle") { model.startRecording() }
            }.disabled(model.isBusy || model.recorder.isRecording || model.scrollingActive)
            HStack(spacing: 19) {
                Button { model.capture(.area, forOCR: true) } label: { Label("テキストを認識", systemImage: "text.viewfinder") }
                Button { model.startScrolling() } label: { Label("スクロール結合", systemImage: "rectangle.expand.vertical") }
                Button { model.pasteImage() } label: { Label("画像をペースト", systemImage: "clipboard") }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(ShotTheme.muted)
        }.padding(23)
            .background(LinearGradient(colors: [Color(red: 0.12, green: 0.15, blue: 0.16), ShotTheme.panel.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(ShotTheme.border, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(ShotTheme.lime.opacity(0.035)).frame(width: 138, height: 94).rotationEffect(.degrees(-9))
                RoundedRectangle(cornerRadius: 12).fill(ShotTheme.panel).frame(width: 112, height: 78)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(ShotTheme.lime.opacity(0.25), lineWidth: 1))
                    .rotationEffect(.degrees(6))
                Image(systemName: "viewfinder").font(.system(size: 31, weight: .ultraLight)).foregroundStyle(ShotTheme.lime)
            }.padding(.bottom, 6)
            Text(model.search.isEmpty ? "最初の1枚を、ここから。" : "一致するキャプチャがありません").font(.system(size: 17, weight: .medium))
            Text(model.search.isEmpty ? "撮影した画像や動画がここに並びます。\n画像ファイルのドラッグ＆ドロップでも追加できます。" : "別のキーワードを試してください。")
                .font(.system(size: 11)).lineSpacing(5).foregroundStyle(ShotTheme.muted).multilineTextAlignment(.center)
            if model.search.isEmpty {
                Button { model.capture(.area) } label: {
                    HStack(spacing: 10) { Text("範囲を選んで撮影"); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(ShotTheme.lime)
                        .padding(.horizontal, 17).padding(.vertical, 10).background(ShotTheme.lime.opacity(0.07), in: Capsule())
                }.buttonStyle(.plain).padding(.top, 5)
            }
        }.frame(maxWidth: .infinity).frame(minHeight: 270)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(ShotTheme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(ShotTheme.lime.opacity(0.8)).frame(width: 4, height: 4)
            Text("ローカルストレージ").font(.system(size: 9))
            Text("·  \(model.totalSize)").font(.system(size: 9, design: .monospaced))
            Spacer()
            Text("メニューバーから、いつでも撮影できます").font(.system(size: 9))
            Image(systemName: "command").font(.system(size: 9))
        }.foregroundStyle(ShotTheme.muted).padding(.horizontal, 30).frame(height: 34)
            .background(ShotTheme.sidebar.opacity(0.55)).overlay(alignment: .top) { Rectangle().fill(ShotTheme.border).frame(height: 1) }
    }

    private func selectedActions(_ item: CaptureItem) -> some View {
        HStack(spacing: 16) {
            Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Spacer()
            if item.kind == .image {
                Button { model.edit(item) } label: { Label("編集", systemImage: "pencil.tip.crop.circle") }
                Button { model.recognize(item) } label: { Label("OCR", systemImage: "text.viewfinder") }
                Button { model.pin(item) } label: { Image(systemName: "pin") }.help("最前面にピン留め")
            } else { Button("再生") { model.edit(item) } }
            Button { model.copy(item) } label: { Image(systemName: "doc.on.doc") }.help("コピー")
            Button { model.favorite(item) } label: { Image(systemName: item.isFavorite ? "star.fill" : "star") }.help("お気に入り")
            Button { model.export(item) } label: { Label("書き出す", systemImage: "square.and.arrow.up") }
        }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(ShotTheme.lime)
            .padding(16).background(ShotTheme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func itemMenu(_ item: CaptureItem) -> some View {
        Button(item.kind == .image ? "注釈を追加・編集" : "動画を再生") { model.edit(item) }
        Button("コピー") { model.copy(item) }
        Button("書き出す…") { model.export(item) }
        if item.kind == .image {
            Button("テキストを認識") { model.recognize(item) }
            Button("最前面にピン留め") { model.pin(item) }
        }
        Divider()
        Button(item.isFavorite ? "お気に入りから削除" : "お気に入りに追加") { model.favorite(item) }
        Button("Finderに表示") { model.reveal(item) }
        Divider()
        Button("削除…", role: .destructive) { model.delete(item) }
    }

    private func count(_ section: LibrarySection) -> Int {
        switch section {
        case .all, .settings: return model.library.items.count
        case .images: return model.library.items.filter { $0.kind == .image }.count
        case .videos: return model.library.items.filter { $0.kind == .video }.count
        case .favorites: return model.library.items.filter(\.isFavorite).count
        }
    }
}

private struct CaptureAction: View {
    let title: String
    let subtitle: String
    let icon: String
    var accent = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon).font(.system(size: 22, weight: .light)).padding(.bottom, 16)
                HStack { Text(title).font(.system(size: 12, weight: .semibold)); Spacer() }
                Text(subtitle).font(.system(size: 9, design: .monospaced)).opacity(0.5).padding(.top, 6)
            }.foregroundStyle(accent ? ShotTheme.background : .white.opacity(0.85)).padding(16).frame(maxWidth: .infinity)
                .background(accent ? ShotTheme.lime : Color.white.opacity(hovering ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent ? .clear : ShotTheme.border, lineWidth: 1))
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

private struct CaptureCard: View {
    let item: CaptureItem
    let url: URL
    let selected: Bool
    @State private var thumbnail: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.025))
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().padding(12) }
                else { Image(systemName: item.kind == .video ? "play.rectangle" : "photo").font(.system(size: 30, weight: .light)).foregroundStyle(ShotTheme.muted) }
                if item.isFavorite { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(ShotTheme.lime).padding(10) }
                if item.kind == .video { Image(systemName: "play.circle.fill").font(.system(size: 26)).shadow(radius: 4).padding(10) }
            }.frame(height: 160).clipped()
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? ShotTheme.lime.opacity(0.8) : ShotTheme.border, lineWidth: selected ? 1.5 : 1))
            Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            HStack {
                Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                Spacer()
                Text(item.kind == .image ? "\(item.width) × \(item.height)" : "MP4")
            }.font(.system(size: 9)).foregroundStyle(ShotTheme.muted)
        }.contentShape(Rectangle()).task(id: item.id) {
            thumbnail = await Task.detached(priority: .utility) {
                if item.kind == .image { return NSImage(contentsOf: url) }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = NSSize(width: 640, height: 400)
                guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }.value
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                settingsGroup("画面収録のアクセス", icon: "lock.shield") {
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.screenPermission ? "画面の撮影が許可されています" : "撮影にはmacOSの許可が必要です").font(.system(size: 13, weight: .medium))
                            Text("システム設定 → プライバシーとセキュリティ → 画面収録\nHS Shotを許可した後、アプリを再起動してください。")
                                .font(.system(size: 11)).lineSpacing(4).foregroundStyle(ShotTheme.muted)
                        }
                        Spacer()
                        Button(model.screenPermission ? "設定を開く" : "アクセスを許可") { model.requestPermission() }
                            .tint(ShotTheme.lime)
                    }
                }
                settingsGroup("撮影と録画", icon: "viewfinder") {
                    Toggle("撮影した画像を自動でコピー", isOn: model.$autoCopy)
                    Toggle("撮影後にクイックアクセスを表示", isOn: model.$showQuickAccess)
                    Toggle("画面録画にシステム音声を含める", isOn: model.$recordAudio)
                    Picker("撮影タイマー", selection: model.$captureDelay) {
                        Text("なし").tag(0.0); Text("3秒").tag(3.0); Text("5秒").tag(5.0); Text("10秒").tag(10.0)
                    }.frame(maxWidth: 320)
                }
                settingsGroup("キーボードショートカット", icon: "command") {
                    shortcut("範囲を選択", "⌘ ⇧ 2"); shortcut("画面全体", "⌘ ⇧ 6"); shortcut("ウィンドウ", "⌘ ⇧ 7")
                    shortcut("テキストを認識", "⌘ ⇧ 8"); shortcut("録画を開始・停止", "⌘ ⇧ 9")
                    Text("ショートカットが他のアプリと競合する場合は、メニューバーから操作できます。")
                        .font(.system(size: 10)).foregroundStyle(ShotTheme.muted)
                }
                settingsGroup("保存先", icon: "internaldrive") {
                    Text(model.library.root.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(ShotTheme.muted).textSelection(.enabled)
                    HStack { Text("\(model.library.items.count)件 · \(model.totalSize)").font(.system(size: 11)); Spacer(); Button("Finderで開く") { NSWorkspace.shared.open(model.library.root) } }
                }
                Text("HS Shot 1.0 · macOS native\n画像のOCRを含め、すべてMac上で処理します。")
                    .font(.system(size: 10)).lineSpacing(5).foregroundStyle(ShotTheme.muted)
            }.padding(30).frame(maxWidth: 850, alignment: .leading)
        }
    }
    private func settingsGroup<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(ShotTheme.lime)
            content().font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(ShotTheme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private func shortcut(_ name: String, _ keys: String) -> some View {
        HStack { Text(name).foregroundStyle(.white.opacity(0.8)); Spacer(); Text(keys).font(.system(size: 11, design: .monospaced)).foregroundStyle(ShotTheme.muted) }.frame(maxWidth: 450)
    }
}
