import AppKit
import AVFoundation
import Combine

enum MediaKind: String, Codable { case image, video }

struct CaptureItem: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    let filename: String
    let kind: MediaKind
    let createdAt: Date
    let width: Int
    let height: Int
    let byteCount: Int64
    var isFavorite: Bool
    var editableProjectVersion: Int? = nil
    var isDraft: Bool? = nil
}

enum LibraryError: LocalizedError {
    case invalidImage, missingFile, unsupportedFile, invalidDraft
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "画像を読み込めませんでした。"
        case .missingFile: return "元のファイルが見つかりません。"
        case .unsupportedFile: return "PNG・JPEGなどの画像、MP4・MOVの動画に対応しています。"
        case .invalidDraft: return "下書きが見つからないか、すでに完了しています。履歴から開き直してください。"
        }
    }
}

final class LibraryStore: ObservableObject {
    @Published private(set) var items: [CaptureItem] = []
    let root: URL
    private var indexURL: URL { root.appendingPathComponent("library.json") }

    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HS Shot", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                let decoded = try JSONDecoder().decode([CaptureItem].self, from: Data(contentsOf: indexURL))
                items = decoded.filter {
                    $0.filename == URL(fileURLWithPath: $0.filename).lastPathComponent &&
                    FileManager.default.fileExists(atPath: self.root.appendingPathComponent($0.filename).path)
                }.sorted { $0.createdAt > $1.createdAt }
            } catch {
                let backup = self.root.appendingPathComponent("library-corrupt-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: indexURL, to: backup)
                items = []
            }
        }
    }

    func url(for item: CaptureItem) -> URL { root.appendingPathComponent(item.filename) }

    func editableProjectURL(for item: CaptureItem) -> URL {
        let stem = URL(fileURLWithPath: item.filename).deletingPathExtension().lastPathComponent
        return root.appendingPathComponent("\(stem).hsedit.json")
    }

    /// A missing marker means a legacy flat image. Marked but broken projects must never
    /// silently reopen the flattened PNG and lose their original editable annotations.
    func editableProject(for item: CaptureItem) throws -> EditorProject? {
        guard let version = item.editableProjectVersion else { return nil }
        guard version == EditorProject.currentSchemaVersion else {
            if version > EditorProject.currentSchemaVersion { throw EditorProjectError.unsupportedVersion(version) }
            throw EditorProjectError.invalidData
        }
        guard item.kind == .image, ownedMediaURL(for: item) != nil else { throw EditorProjectError.invalidData }
        let projectURL = editableProjectURL(for: item)
        guard FileManager.default.fileExists(atPath: projectURL.path) else { throw EditorProjectError.missingData }
        do {
            let attributes = try projectURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let byteCount = attributes.fileSize, byteCount <= EditorProject.maximumFileBytes else {
                throw EditorProjectError.invalidData
            }
            let data = try Data(contentsOf: projectURL)
            // Read the version before decoding the schema, so newer layouts receive the right message.
            struct Header: Decodable { let schemaVersion: Int }
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.schemaVersion == EditorProject.currentSchemaVersion else {
                if header.schemaVersion > EditorProject.currentSchemaVersion {
                    throw EditorProjectError.unsupportedVersion(header.schemaVersion)
                }
                throw EditorProjectError.invalidData
            }
            let project = try JSONDecoder().decode(EditorProject.self, from: data)
            try project.validate()
            return project
        } catch let error as EditorProjectError { throw error }
          catch { throw EditorProjectError.invalidData }
    }

    @discardableResult func add(image: NSImage, title: String) throws -> CaptureItem {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw LibraryError.invalidImage
        }
        return try persist(data: data, ext: "png", kind: .image, title: title, width: cg.width, height: cg.height)
    }

    @discardableResult func add(image: NSImage, project: EditorProject, title: String) throws -> CaptureItem {
        try project.validate()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw LibraryError.invalidImage
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let projectData = try encoder.encode(project)
        guard projectData.count <= EditorProject.maximumFileBytes else { throw EditorProjectError.invalidData }
        return try persist(data: data, ext: "png", kind: .image, title: title, width: cg.width, height: cg.height,
                           projectData: projectData)
    }

    /// Each write uses a new file pair. The index switches to it only after both files
    /// are complete, so a failed save cannot damage the last recoverable draft.
    @discardableResult
    func saveDraft(image: NSImage, project: EditorProject, title: String,
                   replacing draftID: UUID? = nil) throws -> CaptureItem {
        let previous: CaptureItem?
        if let draftID {
            guard let item = items.first(where: { $0.id == draftID }), item.isDraft == true,
                  item.kind == .image, item.editableProjectVersion == EditorProject.currentSchemaVersion,
                  ownedMediaURL(for: item) != nil else { throw LibraryError.invalidDraft }
            previous = item
        } else { previous = nil }
        try project.validate()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let imageData = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw LibraryError.invalidImage
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let projectData = try encoder.encode(project)
        guard projectData.count <= EditorProject.maximumFileBytes else { throw EditorProjectError.invalidData }

        let generation = UUID()
        let item = CaptureItem(id: previous?.id ?? UUID(), title: title,
            filename: "\(generation.uuidString).png", kind: .image,
            createdAt: previous?.createdAt ?? Date(), width: cg.width, height: cg.height,
            byteCount: Int64(imageData.count) + Int64(projectData.count), isFavorite: previous?.isFavorite ?? false,
            editableProjectVersion: EditorProject.currentSchemaVersion, isDraft: true)
        let imageURL = url(for: item)
        let projectURL = editableProjectURL(for: item)
        do {
            try imageData.write(to: imageURL, options: .atomic)
            try projectData.write(to: projectURL, options: .atomic)
            var next = items
            if let previous, let index = next.firstIndex(where: { $0.id == previous.id }) {
                next[index] = item
            } else { next.insert(item, at: 0) }
            try commit(next)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: projectURL)
            throw error
        }
        // The published generation is already durable; orphan cleanup must never turn
        // a successful save into an error or remove another history entry's files.
        if let previous { try? removeUnreferencedOwnedFiles(for: previous) }
        return item
    }

    @discardableResult
    func finalizeDraft(_ id: UUID, title: String) throws -> CaptureItem {
        var next = items
        guard let index = next.firstIndex(where: { $0.id == id }), next[index].isDraft == true,
              next[index].kind == .image, next[index].editableProjectVersion == EditorProject.currentSchemaVersion,
              ownedMediaURL(for: next[index]) != nil else { throw LibraryError.invalidDraft }
        next[index].isDraft = nil
        next[index].title = title
        try commit(next)
        return next[index]
    }

    @discardableResult func add(file: URL, title: String? = nil) throws -> CaptureItem {
        guard FileManager.default.fileExists(atPath: file.path) else { throw LibraryError.missingFile }
        let name = title ?? file.deletingPathExtension().lastPathComponent
        if ["mp4", "mov", "m4v"].contains(file.pathExtension.lowercased()) {
            let id = UUID()
            let filename = "\(id.uuidString).\(file.pathExtension.lowercased())"
            let destination = root.appendingPathComponent(filename)
            try FileManager.default.copyItem(at: file, to: destination)
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let item = CaptureItem(id: id, title: name, filename: filename, kind: .video,
                createdAt: Date(), width: 0, height: 0, byteCount: Int64(bytes), isFavorite: false)
            do { try commit([item] + items) } catch { try? FileManager.default.removeItem(at: destination); throw error }
            return item
        }
        guard let image = NSImage(contentsOf: file) else { throw LibraryError.unsupportedFile }
        return try add(image: image, title: name)
    }

    private func persist(data: Data, ext: String, kind: MediaKind, title: String, width: Int, height: Int,
                         projectData: Data? = nil) throws -> CaptureItem {
        let id = UUID()
        let filename = "\(id.uuidString).\(ext)"
        let destination = root.appendingPathComponent(filename)
        let item = CaptureItem(id: id, title: title, filename: filename, kind: kind, createdAt: Date(),
            width: width, height: height, byteCount: Int64(data.count) + Int64(projectData?.count ?? 0), isFavorite: false,
            editableProjectVersion: projectData == nil ? nil : EditorProject.currentSchemaVersion)
        let projectURL = editableProjectURL(for: item)
        do {
            try data.write(to: destination, options: .atomic)
            if let projectData { try projectData.write(to: projectURL, options: .atomic) }
            // Publish the new item only once both complete files exist.
            try commit([item] + items)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if projectData != nil { try? FileManager.default.removeItem(at: projectURL) }
            throw error
        }
        return item
    }

    func toggleFavorite(_ id: UUID) throws {
        var updated = items
        guard let i = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[i].isFavorite.toggle()
        try commit(updated)
    }

    func rename(_ id: UUID, title: String) throws {
        var updated = items
        guard let i = updated.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updated[i].title = trimmed
        try commit(updated)
    }

    func delete(_ id: UUID) throws {
        guard let item = items.first(where: { $0.id == id }) else { return }
        // Commit metadata first; a failed file removal leaves only an orphan, never a broken history entry.
        try commit(items.filter { $0.id != id })
        try removeUnreferencedOwnedFiles(for: item)
    }

    private func ownedMediaURL(for item: CaptureItem) -> URL? {
        let name = URL(fileURLWithPath: item.filename)
        guard name.lastPathComponent == item.filename,
              UUID(uuidString: name.deletingPathExtension().lastPathComponent) != nil,
              (item.kind == .image ? ["png"] : ["mp4", "mov", "m4v"]).contains(name.pathExtension) else { return nil }
        return root.appendingPathComponent(item.filename)
    }

    private func removeUnreferencedOwnedFiles(for item: CaptureItem) throws {
        guard let imageURL = ownedMediaURL(for: item),
              !items.contains(where: { $0.filename == item.filename }) else { return }
        if FileManager.default.fileExists(atPath: imageURL.path) {
            try FileManager.default.removeItem(at: imageURL)
        }
        if item.editableProjectVersion != nil,
           FileManager.default.fileExists(atPath: editableProjectURL(for: item).path) {
            try FileManager.default.removeItem(at: editableProjectURL(for: item))
        }
    }

    private func commit(_ next: [CaptureItem]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: indexURL, options: .atomic)
        items = next
    }
}
