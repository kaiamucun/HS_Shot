# HS Shot 設計

## ユーザーの要件
CleanShotと同じ用途のアプリを作る。macOSのみ対応。

追加の優先要件: 左下に画像がフローティングで残ること、スクリーンショットを簡単に編集できること。クラウド機能は不要。プレビューは自動で消さず、クリックでエディタを開く。複数枚の直近プレビューを保持し、閉じる操作を付ける。

## 実装側の判断
SwiftUIとAppKitを使い、macOS 14以降で動作するネイティブのHS Shot.appを作る。UIは日本語。クリーンな濃紺のワークスペースとライム色のアクセントを使う。外部の依存ライブラリは追加しない。

## 体験
起動すると左に撮影・ライブラリ・設定、中央に最近のキャプチャ。上部の撮影ボタン、メニューバー、グローバルショートカットから撮影できる。撮影中は本アプリを隠し、撮影後には小さなクイックアクセスからコピー、編集、保存、ピン留め。キャンセル時には空ファイルを保存しない。初回の画面収録権限が必要なことを明示し、設定を開く操作を提供する。

画像は独立したエディタで矢印、線、矩形、楕円、ペン、ハイライト、テキスト、連番、ピクセル化、塗りつぶしによる秘匿、切り抜きを行える。Undo/Redo、色と線幅、コピー、PNG/JPEG書き出し。背景と余白を追加できる。画像と動画の履歴はApplication Supportに保持し、再起動しても残る。ユーザーの原本は編集で上書きせず、保存時には新規成果物を作る。

全画面、選択範囲、ウィンドウ、遅延撮影、OCR（日英）、最前面ピン留め、画面録画、縦スクロール画像の結合を実装する。スクロールはユーザーがページを動かして追加フレームを採取する手動方式で、重複位置を画像から推定して結合する。録画はScreenCaptureKitを使用しMP4とする。音声は実装可能なOS APIに合わせる。録画中・停止処理中を区別し、未完了ファイルを成功扱いしない。

## 範囲の境界
CleanShot専用クラウド、課金、Web共有基盤は接続しない。カメラ合成、Studio動画編集、自動ズーム、CleanShot独自ファイル互換は初版の対象外。これらはUIで利用できるように見せない。実装・実機確認の範囲をREADMEと最終報告で区別する。

## 構成と接続契約
- `AppModel.swift`: `@MainActor final class AppModel: ObservableObject`、履歴、選択、設定、画面操作。
- `CaptureServices.swift`: `enum CaptureMode: String, CaseIterable { case area, window, fullScreen }`; `@MainActor final class CaptureService`、`func capture(_ mode: CaptureMode, delay: Double = 0) async throws -> URL?`。キャンセルはnil。保存先は一時ファイル。
- `RecordingService.swift`: `@MainActor final class RecordingService: ObservableObject`、`@Published var isRecording: Bool`、`@Published var isFinishing: Bool`、`@Published var elapsed: TimeInterval`、`func start(includeAudio: Bool) async throws`、`func stop() async throws -> URL?`。画面選択はカーソルのあるディスプレイ。
- `ImageServices.swift`: `enum ImageServices`、`static func recognizeText(in image: NSImage) async throws -> String`、`static func stitch(_ images: [NSImage]) throws -> NSImage`。ImageServicesのテストを同梱。
- `EditorWindow.swift`: `@MainActor enum EditorWindow { static func open(image: NSImage, title: String, onSave: @escaping (NSImage) throws -> Void) }`。自己完結した編集ウィンドウ。保存失敗は呼び出し元から伝達し、エディタ内で表示する。
- `LibraryStore.swift`: `struct CaptureItem: Identifiable, Codable, Hashable`、`enum MediaKind: String, Codable { case image, video }`、`LibraryStore`による永続化。
- `WorkspaceView.swift`: メイン画面と設定。RootがAppModelから各サービスを接続。
- `AppDelegate.swift`: メニュー、ショートカット、クイックパネル、ピン留め。
- `Package.swift`, `scripts/build-app.sh`, `Resources/Info.plist`: SwiftPMによるビルドと.appバンドル作成。Xcodeプロジェクト生成ツールは不要。

## 検証
履歴の保存・復元・ファイル欠損、画像の結合・寸法・OCR、編集のピクセル出力、アプリ起動を検証する。画面権限を伴う撮影・録画は許可状態を確認して実機検証し、許可されない場合は未検証と記録。デモ画像は実際の撮影履歴に混ぜない。UI確認用の独立したfixtureを生成可能にする。
