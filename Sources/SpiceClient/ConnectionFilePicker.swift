import AppKit

/// Several clients register different UTIs for .vv. Filter the filename rather
/// than trusting whichever extension-to-UTI mapping Launch Services prefers.
@MainActor
final class ConnectionFilePicker: NSObject, NSOpenSavePanelDelegate {
    func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.delegate = self
        return withExtendedLifetime(self) { panel.runModal() == .OK ? panel.url : nil }
    }
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return true }
        return url.pathExtension.lowercased() == "vv"
    }
}
