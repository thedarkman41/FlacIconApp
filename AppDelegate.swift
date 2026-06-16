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

        for folder in folders {
            runProcessing(on: folder)
        }
    }

    @objc func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true        // now allows multiple
        panel.prompt = "Apply Icons"
        if panel.runModal() == .OK {
            for url in panel.urls {
                runProcessing(on: url.path)
            }
        }
    }

    func runProcessing(on path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = FlacIconProcessor.process(baseDir: path) { _ in }
            DispatchQueue.main.async {
                self.showSummary(result, path: path)
            }
        }
    }

    func showSummary(_ result: ProcessResult, path: String) {
        let alert = NSAlert()
        alert.messageText = "Finished applying icons"
        var info = "Folder: \(path)\n\n✅ Processed: \(result.processed)\n❌ Failed: \(result.failed)"
        if !result.foldersWithoutArt.isEmpty {
            info += "\n⚠️  Folders with no artwork: \(result.foldersWithoutArt.count)"
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
