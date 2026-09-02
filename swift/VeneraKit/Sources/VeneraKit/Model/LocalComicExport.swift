import Foundation
import CoreGraphics
import ImageIO
import ZIPFoundation

public enum LocalComicExportFormat: String, Codable, Sendable, CaseIterable {
    case cbz
    case pdf
    case epub
    case veneraComics

    public var fileExtension: String {
        switch self {
        case .cbz: "cbz"
        case .pdf: "pdf"
        case .epub: "epub"
        case .veneraComics: "venera_comics"
        }
    }

    public var displayName: String {
        switch self {
        case .cbz: "CBZ"
        case .pdf: "PDF"
        case .epub: "EPUB"
        case .veneraComics: ".venera_comics"
        }
    }
}

public enum LocalComicExportError: Error, LocalizedError, Sendable, Equatable {
    case emptyComic
    case noImages(String)
    case unsupportedImage(String)
    case cannotCreateOutput
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyComic: "The comic has no exportable content."
        case .noImages(let title): "No readable images found for \(title)."
        case .unsupportedImage(let path): "Unsupported image format: \(path)"
        case .cannotCreateOutput: "Unable to create the export file."
        case .cancelled: "Export cancelled."
        }
    }
}

public extension LocalComicImporter {
    /// Returns images in the same order used by the reader and Flutter exporters.
    static func exportableImageURLs(for comic: LocalComic) -> [URL] {
        var paths: [String] = []
        if !comic.coverPath.isEmpty, FileManager.default.fileExists(atPath: comic.coverPath) {
            paths.append("file://\(comic.coverPath)")
        }
        if comic.hasChapters {
            paths += comic.downloadedChapters.flatMap { chapter in
                LocalManager.shared.getImages(id: comic.id, type: comic.comicType, ep: chapter)
            }
        } else {
            paths += LocalManager.shared.getImages(id: comic.id, type: comic.comicType, ep: 1)
        }
        return paths.compactMap { path in
            if path.hasPrefix("file://") { return URL(fileURLWithPath: String(path.dropFirst(7))) }
            return URL(fileURLWithPath: path)
        }
    }

    static func exportPDF(comic: LocalComic, destinationURL: URL) throws {
        let images = exportableImageURLs(for: comic)
        guard !images.isEmpty else { throw LocalComicExportError.noImages(comic.title) }
        let fm = FileManager.default
        let workingURL = fm.temporaryDirectory.appendingPathComponent("pdf_\(UUID().uuidString).pdf")
        defer { try? fm.removeItem(at: workingURL) }
        guard let context = CGContext(workingURL as CFURL, mediaBox: nil, nil) else {
            throw LocalComicExportError.cannotCreateOutput
        }
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        for imageURL in images {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw LocalComicExportError.unsupportedImage(imageURL.lastPathComponent)
            }
            var mutablePageRect = pageRect
            context.beginPage(mediaBox: &mutablePageRect)
            let imageRect = aspectFit(CGSize(width: image.width, height: image.height), in: pageRect)
            context.draw(image, in: imageRect)
            context.endPage()
        }
        context.closePDF()
        if fm.fileExists(atPath: destinationURL.path) { try fm.removeItem(at: destinationURL) }
        try fm.moveItem(at: workingURL, to: destinationURL)
    }

    static func exportEPUB(comic: LocalComic, destinationURL: URL) throws {
        let images = exportableImageURLs(for: comic)
        guard !images.isEmpty else { throw LocalComicExportError.noImages(comic.title) }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("epub_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("OEBPS/images"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try "application/epub+zip".write(to: staging.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try "<?xml version=\"1.0\" encoding=\"UTF-8\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".write(to: staging.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)

        var manifest: [String] = []
        var spine: [String] = []
        var body = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><meta charset=\"utf-8\"/><title>\(escapeXML(comic.title))</title><style>html,body{margin:0;padding:0;text-align:center;background:#fff}img{max-width:100%;max-height:100vh;object-fit:contain}</style></head><body>"
        for (index, sourceURL) in images.enumerated() {
            try Task.checkCancellation()
            let name = "image-\(index + 1).png"
            let target = staging.appendingPathComponent("OEBPS/images/\(name)")
            try writePNG(from: sourceURL, to: target)
            let id = "image\(index + 1)"
            manifest.append("<item id=\"\(id)\" href=\"images/\(name)\" media-type=\"image/png\"/>")
            let pageID = "page\(index + 1)"
            let pageName = "page-\(index + 1).xhtml"
            let page = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(index + 1)</title></head><body style=\"margin:0;text-align:center\"><img src=\"images/\(name)\" alt=\"Page \(index + 1)\" style=\"max-width:100%;height:auto\"/></body></html>"
            try page.write(to: staging.appendingPathComponent("OEBPS/\(pageName)"), atomically: true, encoding: .utf8)
            manifest.append("<item id=\"\(pageID)\" href=\"\(pageName)\" media-type=\"application/xhtml+xml\"/>")
            spine.append("<itemref idref=\"\(pageID)\"/>")
            body += "<p><img src=\"images/\(name)\" alt=\"Page \(index + 1)\"/></p>"
        }
        body += "</body></html>"
        try body.write(to: staging.appendingPathComponent("OEBPS/index.xhtml"), atomically: true, encoding: .utf8)
        manifest.append("<item id=\"index\" href=\"index.xhtml\" media-type=\"application/xhtml+xml\"/>")
        let identifier = UUID().uuidString
        let opf = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" unique-identifier=\"bookid\" version=\"3.0\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"bookid\">urn:uuid:\(identifier)</dc:identifier><dc:title>\(escapeXML(comic.title))</dc:title><dc:creator>\(escapeXML(comic.subtitle))</dc:creator><dc:language>und</dc:language></metadata><manifest>\(manifest.joined())</manifest><spine>\(spine.joined())</spine></package>"
        try opf.write(to: staging.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)

        let workingURL = fm.temporaryDirectory.appendingPathComponent("epub_\(UUID().uuidString).epub")
        defer { try? fm.removeItem(at: workingURL) }
        guard let archive = Archive(url: workingURL, accessMode: .create, preferredEncoding: .utf8) else { throw LocalComicExportError.cannotCreateOutput }
        // EPUB readers expect mimetype to be the first, uncompressed entry.
        try archive.addEntry(with: "mimetype", fileURL: staging.appendingPathComponent("mimetype"), compressionMethod: .none)
        guard let entries = fm.enumerator(atPath: staging.path) else { throw LocalComicExportError.cannotCreateOutput }
        while let relative = entries.nextObject() as? String {
            try Task.checkCancellation()
            guard relative != "mimetype" else { continue }
            let source = staging.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            try archive.addEntry(with: relative, fileURL: source, compressionMethod: .deflate)
        }
        if fm.fileExists(atPath: destinationURL.path) { try fm.removeItem(at: destinationURL) }
        try fm.moveItem(at: workingURL, to: destinationURL)
    }

    private static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    private static func writePNG(from source: URL, to destination: URL) throws {
        guard let sourceRef = CGImageSourceCreateWithURL(source as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(sourceRef, 0, nil), let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else { throw LocalComicExportError.unsupportedImage(source.lastPathComponent) }
        CGImageDestinationAddImage(destinationRef, image, nil)
        guard CGImageDestinationFinalize(destinationRef) else { throw LocalComicExportError.unsupportedImage(source.lastPathComponent) }
    }

    private static func escapeXML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
}
