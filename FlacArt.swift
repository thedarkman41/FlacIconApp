//
//  FlacArt.swift
//  FlacIconApp
//
//  Created by darkstar on 6/19/26.
//

import Foundation

enum FlacArt {

    /// Path to metaflac. Homebrew installs it here on Apple Silicon and Intel respectively;
    /// we check both since this app may run on either.
    private static let metaflacCandidates = [
        "/opt/homebrew/bin/metaflac",   // Apple Silicon Homebrew
        "/usr/local/bin/metaflac"       // Intel Homebrew
    ]

    private static var metaflacPath: String? = {
        let fm = FileManager.default
        return metaflacCandidates.first { fm.isExecutableFile(atPath: $0) }
    }()

    /// Returns true if metaflac is available on this system. If false, callers
    /// should skip embedded-art handling entirely and fall back to the
    /// folder-JPG-only behavior so the app degrades gracefully.
    static var isAvailable: Bool { metaflacPath != nil }

    /// Attempts to extract the embedded PICTURE block from `flacPath` to a temp
    /// JPEG/PNG file. Returns the temp file path on success, or nil if the FLAC
    /// has no embedded picture (this is the normal/expected case for many files,
    /// not an error).
    static func extractEmbeddedArt(flacPath: String) -> String? {
        guard let metaflac = metaflacPath else { return nil }

        let tempPath = NSTemporaryDirectory()
            .appending("flacart_\(UUID().uuidString).img")

        let result = run(metaflac, args: ["--export-picture-to=\(tempPath)", flacPath])

        let fm = FileManager.default
        guard result.exitCode == 0,
              fm.fileExists(atPath: tempPath),
              let size = try? fm.attributesOfItem(atPath: tempPath)[.size] as? Int,
              size > 0 else {
            // No embedded picture, or export failed — clean up any empty/partial file.
            try? fm.removeItem(atPath: tempPath)
            return nil
        }
        return tempPath
    }

    /// Embeds `imagePath` into `flacPath` as the front-cover PICTURE block.
    /// Returns true on success.
    @discardableResult
    static func embedArt(imagePath: String, intoFlac flacPath: String) -> Bool {
        guard let metaflac = metaflacPath else { return false }

        // --import-picture-from format: [TYPE]|[MIME]|[DESCRIPTION]|[WIDTHxHEIGHTxDEPTH]|FILE
        // Leaving the fields before FILE blank lets metaflac auto-detect MIME type
        // and image dimensions. TYPE 3 = front cover (standard ID3/FLAC convention).
        let spec = "3||Cover||\(imagePath)"
        let result = run(metaflac, args: ["--import-picture-from=\(spec)", flacPath])
        return result.exitCode == 0
    }

    // MARK: - Process helper

    private struct RunResult {
        let exitCode: Int32
        let stderr: String
    }

    private static func run(_ executable: String, args: [String]) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe() // discard stdout, we don't need it

        do {
            try process.run()
        } catch {
            return RunResult(exitCode: -1, stderr: "Failed to launch \(executable): \(error)")
        }

        process.waitUntilExit()

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errString = String(data: errData, encoding: .utf8) ?? ""
        return RunResult(exitCode: process.terminationStatus, stderr: errString)
    }
}
