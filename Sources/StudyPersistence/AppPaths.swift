import Foundation
import StudyDomain

/// Locations inside the app's own container. Never the user's Documents folder.
public struct AppPaths: Sendable, Hashable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func standard(fileManager: FileManager = .default) -> AppPaths {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppPaths(root: appSupport.appendingPathComponent("StudyApp", isDirectory: true))
    }

    public var databaseURL: URL { root.appendingPathComponent("study.sqlite") }
    public var documentsDirectory: URL { root.appendingPathComponent("Documents", isDirectory: true) }
    public var promptsDirectory: URL { root.appendingPathComponent("Prompts", isDirectory: true) }
    public var promptFileURL: URL { root.appendingPathComponent("AGENT.md") }
    public var promptVersionsDirectory: URL { promptsDirectory.appendingPathComponent("Versions", isDirectory: true) }
    public var audioTemporaryDirectory: URL { root.appendingPathComponent("TemporaryAudio", isDirectory: true) }

    public func createDirectories(fileManager: FileManager = .default) throws {
        for directory in [root, documentsDirectory, promptsDirectory, promptVersionsDirectory, audioTemporaryDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Deletes the temporary audio directory contents. Audio is never retained by default.
    public func clearTemporaryAudio(fileManager: FileManager = .default) {
        guard let contents = try? fileManager.contentsOfDirectory(at: audioTemporaryDirectory, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }
}

/// Owns copies of imported files inside the app container.
public struct DocumentFileStore: Sendable {
    public var paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    /// Copies `sourceURL` into app storage under a fresh file name and returns it.
    public func storeCopy(of sourceURL: URL, documentId: DocumentID, fileType: DocumentFileType) throws -> String {
        let fileManager = FileManager.default
        try paths.createDirectories(fileManager: fileManager)
        let fileName = "\(documentId.rawValue).\(fileType.fileExtensions.first ?? "dat")"
        let destination = paths.documentsDirectory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return fileName
    }

    public func url(forStoredFileName name: String) -> URL {
        paths.documentsDirectory.appendingPathComponent(name)
    }

    public func delete(storedFileName name: String) {
        try? FileManager.default.removeItem(at: url(forStoredFileName: name))
    }

    public func deleteAll() {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: paths.documentsDirectory, includingPropertiesForKeys: nil) else { return }
        for url in contents { try? fileManager.removeItem(at: url) }
    }
}
