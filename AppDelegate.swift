import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
        NSLog("=== FlacIconApp launched ===")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🎵"
            NSLog("status item button created")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Apply to Selected Finder Folder(s)",
                                action: #selector(applyToFinderSelection), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Choose Folder…",
                                action: #selector(chooseFolder), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // Ask Finder for the currently selected items, keep the folders, process each.
    @objc func applyToFinderSelection() {
        let script = """
        tell application "Finder"
            set sel to selection
            set out to ""
            repeat with anItem in sel
                set out to out & (POSIX path of (anItem as alias)) & linefeed
            end repeat
            return out
        end tell
        """

        var error: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return }
        let result = apple.executeAndReturnError(&error)

        if let error = error {
            NSLog("Finder selection error: \(error)")
            notify(title: "Couldn't read Finder selection",
                   text: "Make sure a Finder window is frontmost with folders selected.")
            return
        }

        let paths = (result.stringValue ?? "")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Keep only folders
        var folders = [String]()
        for p in paths {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                folders.append(p)
            }
        }

        if folders.isEmpty {
                    notify(title: "No folders selected",
                           text: "Select one or more folders in Finder, then try again.")
                    return
                }

                // Pass the array instead of looping here
                runProcessing(on: folders)
    }

    @objc func chooseFolder() {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true        // now allows multiple[cite: 1]
            panel.prompt = "Apply Icons"
            if panel.runModal() == .OK {
                // Map the URLs to paths and pass the array
                let paths = panel.urls.map { $0.path }
                runProcessing(on: paths)
            }
        }

    func runProcessing(on paths: [String]) {
            DispatchQueue.global(qos: .userInitiated).async {
                // Track total results across all folders
                var totalProcessed = 0
                var totalFailed = 0
                var totalFoldersWithoutArt = 0
                var totalEmbeddedFromFolder = 0

                for path in paths {
                    // Process sequentially
                    let result = FlacIconProcessor.process(baseDir: path) { _ in }
                    
                    // Add this folder's results to the grand totals
                    totalProcessed += result.processed
                    totalFailed += result.failed
                    totalFoldersWithoutArt += result.foldersWithoutArt.count
                    totalEmbeddedFromFolder += result.embeddedFromFolder
                }

                // Once the loop is entirely finished, show the summary on the main thread
                DispatchQueue.main.async {
                    self.showSummary(foldersCount: paths.count,
                                     processed: totalProcessed,
                                     failed: totalFailed,
                                     noArt: totalFoldersWithoutArt,
                                     embeddedFromFolder: totalEmbeddedFromFolder)
                }
            }
        }

    func showSummary(foldersCount: Int, processed: Int, failed: Int, noArt: Int, embeddedFromFolder: Int) {
            let alert = NSAlert()
            alert.messageText = "Finished applying icons"
            
            var info = "Folders Scanned: \(foldersCount)\n\n✅ Total Processed: \(processed)\n❌ Total Failed: \(failed)"
            
            if embeddedFromFolder > 0 {
                info += "\n📀 Folder art embedded into FLAC metadata: \(embeddedFromFolder)"
            }
            if noArt > 0 {
                info += "\n⚠️  Folders with no artwork: \(noArt)"
            }
            
            alert.informativeText = info
            alert.runModal()
        }

    func notify(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
