import AppKit
import QuickLookThumbnailing
import Synchronization
import UniformTypeIdentifiers

// MARK: - Icon outlines

/// Renders the icon Finder shows for a desktop item and measures its top edge.
/// Called from the serial Accessibility queue; state is behind a lock so the
/// Quick Look callback (which runs elsewhere) can report errors safely.
enum IconShapes {
    private static let cache = Mutex<[String: [CGFloat?]]>([:])
    private static let lastError = Mutex("")

    static var finderShowsPreviews: Bool {
        let v = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any]
        return (v?["IconViewSettings"] as? [String: Any])?["showIconPreview"] as? Bool ?? true
    }

    static func describe() -> String {
        "last thumbnail error: \(lastError.withLock { $0 })\nreadable desktop: \(FileManager.default.isReadableFile(atPath: NSHomeDirectory() + "/Desktop"))\n" + cache.withLock { $0 }.map { k, v in
            "\((k as NSString).lastPathComponent): " + v.map { $0.map { String(Int($0)) } ?? "-" }.joined(separator: " ")
        }.sorted().joined(separator: "\n")
    }

    static func profile(url: URL?, name: String, size: CGSize, preview: Bool) -> [CGFloat?] {
        let key = "\(url?.path ?? name)|\(size.width)x\(size.height)|\(preview)"
        if let p = cache.withLock({ $0[key] }) { return p }
        let p = image(url: url, name: name, size: size, preview: preview).map { outline(of: $0, box: size) }
            ?? Array(repeating: 0, count: max(1, Int(size.width / bucketW)))
        cache.withLock { $0[key] = p }
        return p
    }

    private static func image(url: URL?, name: String, size: CGSize, preview: Bool) -> CGImage? {
        // Content preview (what Finder shows with "Show icon preview"), e.g. for screenshots.
        // Quick Look picks the best of thumbnail / plain icon for each file.
        if let url, preview {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .all)
            let done = DispatchSemaphore(value: 0)
            let result = Mutex<CGImage?>(nil)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, err in
                if let err { lastError.withLock { $0 = "\(url.path): \(err)" } }
                result.withLock { $0 = rep?.cgImage }
                done.signal()
            }
            if done.wait(timeout: .now() + 3) == .success, let image = result.withLock({ $0 }) { return image }
        }
        // Plain file icon; without a file, the icon for its type.
        let icon: NSImage
        if let url {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            let ext = (name as NSString).pathExtension
            icon = NSWorkspace.shared.icon(for: ext.isEmpty ? .folder : (UTType(filenameExtension: ext) ?? .data))
        }
        var rect = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2)
        return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Per column (bucketW wide): points from the top of the box to the first mostly
    /// opaque pixel, with the image aspect-fit and centred like Finder draws it.
    private static func outline(of image: CGImage, box: CGSize) -> [CGFloat?] {
        let scale: CGFloat = 2
        let W = max(1, Int(box.width * scale)), H = max(1, Int(box.height * scale))
        let n = max(1, Int(box.width / bucketW))
        var px = [UInt8](repeating: 0, count: W * H * 4)
        return px.withUnsafeMutableBytes { buf -> [CGFloat?] in
            guard let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8,
                                      bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return Array(repeating: 0, count: n) }
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let s = min(CGFloat(W) / iw, CGFloat(H) / ih)
            ctx.draw(image, in: CGRect(x: (CGFloat(W) - iw * s) / 2, y: (CGFloat(H) - ih * s) / 2,
                                       width: iw * s, height: ih * s))
            // Bitmap memory starts at the top row.
            return (0..<n).map { i in
                let x0 = Int(CGFloat(i) * bucketW * scale), x1 = min(W, Int(CGFloat(i + 1) * bucketW * scale))
                for y in 0..<H {
                    for x in x0..<x1 where buf[(y * W + x) * 4 + 3] > 140 { return CGFloat(y) / scale }
                }
                return nil
            }
        }
    }
}
