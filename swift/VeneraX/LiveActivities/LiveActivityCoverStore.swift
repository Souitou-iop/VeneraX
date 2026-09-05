import Foundation
import UIKit

/// The extension never fetches remote images. Only small, source-aware thumbnails
/// produced by the app are shared. A missing signing entitlement degrades to icons.
@MainActor
final class LiveActivityCoverStore {
    private var files: [String: String] = [:]
    private var failures: [String: Date] = [:]
    private var pending: [String: Task<Void, Never>] = [:]

    func filename(raw: String, sourceKey: String?, comicID: String?, onReady: @escaping @MainActor () -> Void) -> String {
        guard !raw.isEmpty else { return "" }
        let key = "\(raw)@\(sourceKey ?? "")@\(comicID ?? "")"
        if let name = files[key], let file = VeneraTaskActivityAttributes.coverFile(name),
           FileManager.default.fileExists(atPath: file.path) { return name }
        if let lastFailure = failures[key], Date().timeIntervalSince(lastFailure) < 60 { return "" }
        guard pending[key] == nil else { return "" }
        let name = UUID().uuidString + ".jpg"
        guard let file = VeneraTaskActivityAttributes.coverFile(name) else { return "" }
        if failures.count > 64 { failures.removeAll() }
        failures[key] = Date()
        pending[key] = Task { [weak self] in
            defer { self?.pending[key] = nil }
            guard let image = await CoverLoader.shared.load(raw, sourceKey: sourceKey, comicID: comicID),
                  !Task.isCancelled else { return }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 128), format: format).image { _ in
                let scale = max(96 / max(image.size.width, 1), 128 / max(image.size.height, 1))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: (96 - size.width) / 2, y: (128 - size.height) / 2, width: size.width, height: size.height))
            }
            guard let data = thumbnail.jpegData(compressionQuality: 0.8), !Task.isCancelled else { return }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                self?.files[key] = name
                self?.failures[key] = nil
                onReady()
            } catch {
                // Do not log source URLs or comic titles.
            }
        }
        return ""
    }

    func prune(keeping names: Set<String>) {
        guard let directory = VeneraTaskActivityAttributes.coverFile(UUID().uuidString + ".jpg")?.deletingLastPathComponent(),
              let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let candidates = children.filter { VeneraTaskActivityAttributes.validCoverName($0.lastPathComponent) }
            .sorted { modificationDate($0) > modificationDate($1) }
        for (index, file) in candidates.enumerated() where !names.contains(file.lastPathComponent) {
            let age = Date().timeIntervalSince(modificationDate(file))
            // Retain recent terminal artwork for the 45-second dismissal window.
            if age > 86_400 || (index >= 32 && age > 60) { try? FileManager.default.removeItem(at: file) }
        }
        files = files.filter { _, name in
            guard let file = VeneraTaskActivityAttributes.coverFile(name) else { return false }
            return FileManager.default.fileExists(atPath: file.path)
        }
    }

    private func modificationDate(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    func clear() {
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        files.removeAll()
        failures.removeAll()
        guard let directory = VeneraTaskActivityAttributes.coverFile(UUID().uuidString + ".jpg")?.deletingLastPathComponent(),
              let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in children where VeneraTaskActivityAttributes.validCoverName(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
