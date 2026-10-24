import AppKit
import Combine

/// A visible preview follows edits made from any image it has represented.
/// The panel owns this state, so closing the panel also ends the relationship.
@MainActor final class QuickAccessPreviewState: ObservableObject {
    let sessionID = UUID()
    let originalItem: CaptureItem
    @Published private(set) var item: CaptureItem
    private(set) var document: EditorDocument?
    var isEditing = false
    private var representedIDs: Set<UUID>

    init(item: CaptureItem) {
        originalItem = item
        self.item = item
        representedIDs = [item.id]
    }

    func represents(_ id: UUID) -> Bool { representedIDs.contains(id) }

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
