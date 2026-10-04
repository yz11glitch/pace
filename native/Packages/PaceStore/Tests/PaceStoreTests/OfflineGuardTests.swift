import Foundation
import Testing

/// Offline contract "works in airplane mode": no Pace code may touch the
/// network. Every capture, ledger and backup path is local.
@Test("no networking API anywhere in the app or its packages")
func noNetworking() throws {
    let native = Fixtures.root.appendingPathComponent("native")
    let roots = ["PaceApp", "Packages/PaceCore/Sources", "Packages/PaceStore/Sources"].map(native.appendingPathComponent)
    let forbidden = ["URLSession", "URLRequest", "NWConnection", "NWPathMonitor", "import Network", "CFNetwork",
                     "http://", "https://", "WebSocket", "CloudKit", "CKContainer"]
    var scanned = 0
    for root in roots {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for file in files {
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden { #expect(!text.contains(token), "\(file.lastPathComponent) uses \(token)") }
        }
    }
    #expect(scanned > 10)
}
