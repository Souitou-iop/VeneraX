import Foundation

public struct FileTypeInfo: Sendable {
    public let mime: String
    public let ext: String

    public init(mime: String, ext: String) {
        self.mime = mime
        self.ext = ext
    }
}

public enum FileTypeDetector {
    public static func detect(data: Data) -> FileTypeInfo {
        guard data.count >= 12 else {
            return FileTypeInfo(mime: "application/octet-stream", ext: ".bin")
        }
        let bytes = [UInt8](data.prefix(16))

        // JPEG: FF D8 FF
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return FileTypeInfo(mime: "image/jpeg", ext: ".jpg")
        }
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return FileTypeInfo(mime: "image/png", ext: ".png")
        }
        // GIF: GIF87a / GIF89a (47 49 46 38)
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
            return FileTypeInfo(mime: "image/gif", ext: ".gif")
        }
        // WebP: RIFF .... WEBP
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
           bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 {
            return FileTypeInfo(mime: "image/webp", ext: ".webp")
        }
        // BMP: 42 4D
        if bytes[0] == 0x42 && bytes[1] == 0x4D {
            return FileTypeInfo(mime: "image/bmp", ext: ".bmp")
        }
        // ZIP: 50 4B 03 04 or 50 4B 05 06
        if bytes[0] == 0x50 && bytes[1] == 0x4B {
            return FileTypeInfo(mime: "application/zip", ext: ".zip")
        }
        // 7z: 37 7A BC AF 27 1C
        if bytes[0] == 0x37 && bytes[1] == 0x7A && bytes[2] == 0xBC && bytes[3] == 0xAF {
            return FileTypeInfo(mime: "application/x-7z-compressed", ext: ".7z")
        }
        // AVIF / HEIC / MP4 (ftyp)
        if bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            if brand.hasPrefix("avif") || brand.hasPrefix("avis") {
                return FileTypeInfo(mime: "image/avif", ext: ".avif")
            }
            if brand.hasPrefix("heic") || brand.hasPrefix("heix") {
                return FileTypeInfo(mime: "image/heic", ext: ".heic")
            }
        }
        return FileTypeInfo(mime: "application/octet-stream", ext: ".bin")
    }
}
