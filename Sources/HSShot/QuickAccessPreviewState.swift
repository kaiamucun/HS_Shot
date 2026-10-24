import AppKit
import Combine

/// A visible preview follows edits made from any image it has represented.
/// The panel owns this state, so closing the panel also ends the relationship.
@MainActor final class QuickAccessPreviewState: ObservableObject {
    let sessionID = UUID()
    let originalItem: CaptureItem
    @Published private(set) var item: CaptureItem
    private(set) var document: EditorDocument?
    private(set) var sourceTitle: String
    var isEditing = false
    private var representedIDs: Set<UUID>

    init(item: CaptureItem) {
        originalItem = item
        self.item = item
        sourceTitle = item.title
        representedIDs = [item.id]
    }

    func represents(_ id: UUID) -> Bool { representedIDs.contains(id) }

    /// A history item represents its own saved revision, not a later preview revision.
    func canResume(_ item: CaptureItem) -> Bool { self.item.id == item.id }

    func prepareDocument(using library: LibraryStore, preferences: EditorPreferences? = nil) throws -> EditorDocument {
        if let document { return document }
        let restored: EditorDocument
        if let project = try library.editableProject(for: item) {
            restored = try project.restore(preferences: preferences)
            sourceTitle = project.sourceTitle
        } else {
            guard let image = NSImage(contentsOf: library.url(for: item)),
                  let fresh = EditorDocument(image: image, preferences: preferences) else {
                throw LibraryError.invalidImage
            }
            restored = fresh
        }
        document = restored
        return restored
    }

    // Keep the source pixels and editable annotations separate from the saved PNG.
    // The preview owns this session; closing an editor only releases its window.
    func prepareDocument(image: NSImage, preferences: EditorPreferences? = nil) -> EditorDocument? {
        if let document { return document }
        document = EditorDocument(image: image, preferences: preferences)
        return document
    }

    func replace(sourceID: UUID, with replacement: CaptureItem) {
        guard representedIDs.contains(sourceID) else { return }
        representedIDs.insert(replacement.id)
        item = replacement
    }
}
