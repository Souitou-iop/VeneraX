import XCTest
@testable import VeneraKit

/// Explicit opt-in: personal archives stay outside the repository and CI.
final class RealBackupInteropTests: XCTestCase {
    func testLocalImportAndExport() throws {
        guard let input = ProcessInfo.processInfo.environment["VENERA_INTEROP_INPUT"],
              let output = ProcessInfo.processInfo.environment["VENERA_INTEROP_OUTPUT"] else {
            throw XCTSkip("Set external input/output paths to run private backup verification")
        }
        let root = URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppPaths.overrideDataPath = root.path
        AppPaths.overrideCachePath = root.appendingPathComponent("cache").path
        defer {
            AppPaths.overrideDataPath = nil
            AppPaths.overrideCachePath = nil
            try? FileManager.default.removeItem(at: root)
        }
        AppData.shared.settings["webdav"] = .array([])
        AppData.shared.settings["proxy"] = .string("")
        ImageFavoriteManager.shared.ensureSchema() // Mirrors managers initialized before UI import.
        try DataSync.shared.importAppData(Data(contentsOf: URL(fileURLWithPath: input)))
        let db = DatabaseGateway.shared.openManagedRecovering(root.appendingPathComponent("history.db").path)
        let history = try db.selectValue("SELECT COUNT(*) FROM history;")?.intValue ?? 0
        let originals = try db.selectValue("SELECT COUNT(*) FROM image_favorites;")?.intValue ?? 0
        print("INTEROP history=\(history) originalImageGroups=\(originals) swiftImages=\(ImageFavoriteManager.shared.getAll().count)")
        XCTAssertGreaterThan(history, 0)
        XCTAssertTrue(AppData.shared.settings["webdav"] == .array([]), "Import must preserve local WebDAV configuration")
        let exported = try DataSync.shared.exportAppData(sync: false)
        try exported.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
