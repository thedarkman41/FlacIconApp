import Foundation

struct ProcessResult {
    var processed: Int = 0
    var failed: Int = 0
    var foldersWithoutArt: [String] = []
    var log: [String] = []
}

enum FlacIconProcessor {

    /// Walks `baseDir`, and for every .flac file applies the first .jpg/.jpeg
    /// found in that same folder as the file's custom icon.
    /// Mirrors icon_change.pl: skips hidden files, warns once per art-less folder.
    static func process(baseDir: String, progress: ((String) -> Void)? = nil) -> ProcessResult {
        var result = ProcessResult()
        let fm = FileManager.default
        var reportedDirs = Set<String>()
        // Cache of folder -> first jpg path (so we don't re-scan a folder per FLAC)
        var folderArtCache = [String: String?]()

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: baseDir),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],   // include subdirectories; we filter hidden ourselves
            errorHandler: nil
        ) else {
            result.log.append("Could not open directory: \(baseDir)")
            return result
        }

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent

            // Skip hidden files (.DS_Store etc.), matching the Perl /^\./ check
            if name.hasPrefix(".") { continue }

            // Only process .flac files
            guard fileURL.pathExtension.lowercased() == "flac" else { continue }

            let currentDir = fileURL.deletingLastPathComponent().path

            // Find (and cache) the first jpg/jpeg in this folder
            let artPath: String?
            if let cached = folderArtCache[currentDir] {
                artPath = cached
            } else {
                artPath = firstJPG(in: currentDir, fm: fm)
                folderArtCache[currentDir] = artPath
            }

            guard let localJPG = artPath else {
                if reportedDirs.insert(currentDir).inserted {
                    let msg = "⚠️  No JPEG exists for path: \(currentDir)"
                    result.foldersWithoutArt.append(currentDir)
                    result.log.append(msg)
                    progress?(msg)
                }
                continue
            }

            // Skip if the target happens to be the art file itself
            if fileURL.path == localJPG { continue }

            if IconSetter.setIcon(imagePath: localJPG, targetPath: fileURL.path) {
                result.processed += 1
                let msg = "✅ \(name)"
                result.log.append(msg)
                progress?(msg)
            } else {
                result.failed += 1
                let msg = "❌ Failed to set icon for: \(name)"
                result.log.append(msg)
                progress?(msg)
            }
        }

        return result
    }

    /// Returns the path to the first .jpg/.jpeg in `dir`, or nil if none.
    private static func firstJPG(in dir: String, fm: FileManager) -> String? {
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        // Sort for deterministic "first" selection (Perl's readdir order is arbitrary)
        for entry in entries.sorted() {
            let ext = (entry as NSString).pathExtension.lowercased()
            if ext == "jpg" || ext == "jpeg" {
                let full = (dir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                    return full
                }
            }
        }
        return nil
    }
}
