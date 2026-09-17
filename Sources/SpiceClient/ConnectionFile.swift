import Foundation
import CryptoKit
import Darwin
import ConnectionCore

struct ConnectionFile: Sendable {
    let url: URL
    let plan: ConnectionPlan
    let device: Int32
    let inode: UInt64
    let digest: Data

    static func read(_ url: URL) throws -> Self {
        guard url.isFileURL, url.pathExtension.lowercased() == "vv" else { throw PortalError.invalidResponse }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw PortalError.invalidResponse }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_size <= ConnectionPlan.maximumBytes else { throw PortalError.invalidResponse }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw PortalError.invalidResponse }
            guard data.count + count <= ConnectionPlan.maximumBytes else { throw ConnectionError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        return Self(url: url, plan: try .parse(data), device: st.st_dev, inode: st.st_ino,
                    digest: Data(SHA256.hash(data: data)))
    }

    /// Stage by exclusive rename in the source directory, then validate the
    /// staged identity/content. A path replaced by an editor is restored, never
    /// sent to Trash. The private staging directory also owns rollback state.
    func moveToTrash(using trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        let parent = url.deletingLastPathComponent()
        let directory = parent.appendingPathComponent(".spice-client-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        let staged = directory.appendingPathComponent(url.lastPathComponent)
        guard renameatx_np(AT_FDCWD, url.path, AT_FDCWD, staged.path, UInt32(RENAME_EXCL)) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw PortalError.invalidResponse
        }
        do {
            let current = try Self.read(staged)
            guard current.device == device, current.inode == inode, current.digest == digest else { throw PortalError.invalidResponse }
            try trash(staged)
            try? FileManager.default.removeItem(at: directory)
        } catch {
            if renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, url.path, UInt32(RENAME_EXCL)) == 0 {
                try? FileManager.default.removeItem(at: directory)
            }
            // Never overwrite a new file in a rollback. Preserve the staged
            // item and reveal its location via a typed error if restoration fails.
            if FileManager.default.fileExists(atPath: staged.path) { throw FileRecoveryRequired(url: staged) }
            throw error
        }
    }
}
struct FileRecoveryRequired: Error { let url: URL }
