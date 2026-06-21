import Foundation

struct ProcessResult {
    var processed: Int = 0
    var failed: Int = 0
    var embeddedFromFolder: Int = 0   // count of FLACs that got folder art written into their metadata
    var foldersWithoutArt: [String] = []
    var log: [String] = []
}

enum FlacIconProcessor {

    private static let maxConcurrent = 3

    /// Walks `baseDir` and for every .flac file:
    ///   1. If the FLAC already has embedded cover art, extract it and use that as the icon.
    ///   2. Otherwise, fall back to the first .jpg/.jpeg found in that same folder (prior behavior).
    ///      If found this way, also embed that JPG into the FLAC's metadata so future runs
    ///      (and other players) see it as embedded art too.
    ///   3. If neither exists, report the folder as art-less (prior behavior).
    ///
    /// Up to `maxConcurrent` (3) FLAC files are processed in parallel via a
    /// semaphore-gated DispatchQueue. Files finish out of order; `progress`
    /// fires as each one completes, but the final `result.log` is sorted back
    /// into alphabetical-by-filename order for a stable, readable artifact.
    static func process(baseDir: String, progress: ((String) -> Void)? = nil) -> ProcessResult {
        let fm = FileManager.default

        if !FlacArt.isAvailable {
            let msg = "⚠️  metaflac not found (brew install flac) — skipping embedded-art checks, using folder JPGs only"
            progress?(msg)
        }

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: baseDir),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else {
            var result = ProcessResult()
            result.log.append("Could not open directory: \(baseDir)")
            return result
        }

        // Collect the FLAC file list up front so we can fan work out across
        // a bounded set of concurrent workers. Folder-jpg lookups still get
        // cached, but the cache must be protected since multiple files in the
        // same folder may now be processed concurrently.
        var flacFiles = [URL]()
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if name.hasPrefix(".") { continue }
            guard fileURL.pathExtension.lowercased() == "flac" else { continue }
            flacFiles.append(fileURL)
        }

        // Shared mutable state, all access funneled through `stateQueue` (serial)
        // to keep this safe across the concurrent workers below.
        let stateQueue = DispatchQueue(label: "com.flaciconapp.state")
        var processed = 0
        var failed = 0
        var embeddedFromFolder = 0
        var foldersWithoutArt = [String]()
        var reportedDirs = Set<String>()
        var folderArtCache = [String: String?]()
        // (filename, logLine) pairs — sorted by filename at the end so the
        // final log reads in a stable, predictable order despite concurrent completion.
        var entries = [(name: String, line: String)]()

        let semaphore = DispatchSemaphore(value: maxConcurrent)
        let workQueue = DispatchQueue(label: "com.flaciconapp.work", attributes: .concurrent)
        let group = DispatchGroup()

        // NSGraphicsContext.current / saveGraphicsState / restoreGraphicsState are
        // NOT safe to call from multiple threads at once — AppKit's graphics state
        // stack is effectively global, so concurrent makeIcon() calls can stomp on
        // each other (one thread's context becomes "current" mid-draw on another
        // thread, corrupting whichever icon happens to be rendering at that moment).
        // This is what caused "every third file" corruption when iconQueue didn't exist
        // and IconSetter.setIcon was called directly from the concurrent workQueue.
        // metaflac extraction/embedding (pure subprocess I/O) stays parallel on
        // workQueue; only the actual icon render+set is funneled through this
        // serial queue.
        let iconQueue = DispatchQueue(label: "com.flaciconapp.icon")

        for fileURL in flacFiles {
            semaphore.wait()
            group.enter()
            workQueue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }

                let name = fileURL.lastPathComponent
                let flacPath = fileURL.path
                let currentDir = fileURL.deletingLastPathComponent().path

                // Step 1: check for embedded art first.
                var extractedTempPath: String? = nil
                if FlacArt.isAvailable {
                    extractedTempPath = FlacArt.extractEmbeddedArt(flacPath: flacPath)
                }
                var iconSourcePath = extractedTempPath

                // Step 2: no embedded art — fall back to folder jpg.
                // Folder-art lookup + cache access is funneled through stateQueue
                // since multiple FLACs in the same folder may race here.
                var usedFolderArt = false
                if iconSourcePath == nil {
                    let artPath: String? = stateQueue.sync {
                        if let cached = folderArtCache[currentDir] {
                            return cached
                        }
                        let found = firstJPG(in: currentDir, fm: fm)
                        folderArtCache[currentDir] = found
                        return found
                    }

                    if let localJPG = artPath, fileURL.path != localJPG {
                        iconSourcePath = localJPG
                        usedFolderArt = true
                    }
                }

                guard let source = iconSourcePath else {
                    stateQueue.sync {
                        if reportedDirs.insert(currentDir).inserted {
                            let msg = "⚠️  No JPEG exists for path: \(currentDir)"
                            foldersWithoutArt.append(currentDir)
                            entries.append((name: currentDir, line: msg))
                            progress?(msg)
                        }
                    }
                    if let temp = extractedTempPath { try? fm.removeItem(atPath: temp) }
                    return
                }

                // Step 3: if we used folder art (no embedded art existed), write it
                // back into the FLAC's metadata so the file becomes self-contained.
                if usedFolderArt, FlacArt.isAvailable {
                    if FlacArt.embedArt(imagePath: source, intoFlac: flacPath) {
                        stateQueue.sync { embeddedFromFolder += 1 }
                        progress?("📀 Embedded folder art into: \(name)")
                    } else {
                        progress?("⚠️  Could not embed art into: \(name) (icon will still be set)")
                    }
                }

                // Step 4: apply icon from whichever source we ended up with.
                // Routed through iconQueue (serial) — see comment above on why
                // this specific call can't run concurrently across workers.
                let iconSet = iconQueue.sync {
                    IconSetter.setIcon(imagePath: source, targetPath: flacPath)
                }
                if iconSet {
                    let msg = "✅ \(name)"
                    stateQueue.sync {
                        processed += 1
                        entries.append((name: name, line: msg))
                    }
                    progress?(msg)
                } else {
                    let msg = "❌ Failed to set icon for: \(name)"
                    stateQueue.sync {
                        failed += 1
                        entries.append((name: name, line: msg))
                    }
                    progress?(msg)
                }

                if let temp = extractedTempPath {
                    try? fm.removeItem(atPath: temp)
                }
            }
        }

        group.wait()

        var result = ProcessResult()
        result.processed = processed
        result.failed = failed
        result.embeddedFromFolder = embeddedFromFolder
        result.foldersWithoutArt = foldersWithoutArt
        result.log = entries
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { $0.line }
        return result
    }

    /// Returns the path to the first .jpg/.jpeg in `dir`, or nil if none.
    private static func firstJPG(in dir: String, fm: FileManager) -> String? {
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
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
