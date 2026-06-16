import Cocoa

enum IconSetter {
    @discardableResult
    static func setIcon(imagePath: String, targetPath: String) -> Bool {
        guard let original = NSImage(contentsOfFile: imagePath),
              let icon = makeIcon(from: original, pixels: 512) else {
            return false
        }
        return NSWorkspace.shared.setIcon(icon, forFile: targetPath, options: [])
    }

    // Render the source into a fixed 512x512 PIXEL bitmap, regardless of the
    // source's point size / DPI. This avoids the "Invalid image size" rejection,
    // which is triggered by oversized pixel dimensions.
    private static func makeIcon(from image: NSImage, pixels: Int) -> NSImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                   from: .zero, operation: .copy, fraction: 1.0)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: pixels, height: pixels))
        out.addRepresentation(rep)
        return out
    }
}
