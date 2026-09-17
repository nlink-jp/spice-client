import Foundation
import Testing
@testable import SpiceClient

struct ConnectionFileTests {
    let contents = Data("[virt-viewer]\ntype=spice\nhost=example.invalid\nport=5900\n".utf8)
    func fixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("connection.vv")
        try contents.write(to: file)
        try body(file)
    }
    @Test func onlyConfirmedUnchangedFileCanBeMoved() throws {
        try fixture { url in
            let file = try ConnectionFile.read(url)
            var moved = false
            try file.moveToTrash { staged in
                #expect(!FileManager.default.fileExists(atPath: url.path))
                #expect(try Data(contentsOf: staged) == contents)
                moved = true
                try FileManager.default.removeItem(at: staged)
            }
            #expect(moved)
        }
    }
    @Test func replacementAndContentChangesAreRestoredWithoutTrashing() throws {
        for replace in [false, true] {
            try fixture { url in
                let file = try ConnectionFile.read(url)
                let changed = contents + Data("title=changed\n".utf8)
                if replace { try FileManager.default.removeItem(at: url) }
                try changed.write(to: url)
                #expect(throws: (any Error).self) {
                    try file.moveToTrash { _ in Issue.record("Changed file reached Trash") }
                }
                #expect(try Data(contentsOf: url) == changed)
            }
        }
    }
    @Test func failedTrashRollsBackAndNeverOverwritesRacingReplacement() throws {
        try fixture { url in
            let file = try ConnectionFile.read(url)
            #expect(throws: (any Error).self) { try file.moveToTrash { _ in throw CocoaError(.fileWriteNoPermission) } }
            #expect(try Data(contentsOf: url) == contents)
            do {
                try file.moveToTrash { _ in
                    try Data("new file".utf8).write(to: url)
                    throw CocoaError(.fileWriteNoPermission)
                }
                Issue.record("Expected preserved recovery file")
            } catch let error as FileRecoveryRequired {
                #expect(try Data(contentsOf: error.url) == contents)
                #expect(try Data(contentsOf: url) == Data("new file".utf8))
            }
        }
    }
    @Test func symlinksAndDirectoriesAreNotConnectionFiles() throws {
        try fixture { url in
            let link = url.deletingLastPathComponent().appendingPathComponent("link.vv")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            #expect(throws: (any Error).self) { try ConnectionFile.read(link) }
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try ConnectionFile.read(link) }
        }
    }
}
