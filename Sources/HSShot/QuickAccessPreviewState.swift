import Foundation
import Combine

/// A visible preview follows edits made from any image it has represented.
/// The panel owns this state, so closing the panel also ends the relationship.
@MainActor final class QuickAccessPreviewState: ObservableObject {
    @Published private(set) var item: CaptureItem
    private var representedIDs: Set<UUID>

    init(item: CaptureItem) {
        self.item = item
        representedIDs = [item.id]
    }

    func replace(sourceID: UUID, with replacement: CaptureItem) {
        guard representedIDs.contains(sourceID) else { return }
        representedIDs.insert(replacement.id)
        item = replacement
    }
}
