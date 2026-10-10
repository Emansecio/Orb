import CryptoKit
import Foundation
@testable import Orb

/// Removes a test's folder in the temporary directory for good. What the test started can still write there after it
/// ended (an `AppModel` saves its state 0.4 s after a change, whenever the busy main actor gets to it; a memory bank
/// writes its index), and that write would make the folder again and leave it behind on every run. So the folders in
/// it are sealed first, as a reset seals the data folder before it wipes it (`Store.sealWrites`), and what is not
/// written through a `Store` is removed once more a few seconds later.
func removeTestFolder(_ url: URL, sealing stores: URL...) {
    WriteSeals.seal(url)
    for store in stores { WriteSeals.seal(store) }
    let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey])
    while let file = files?.nextObject() as? URL {
        if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { WriteSeals.seal(file) }
    }
    try? FileManager.default.removeItem(at: url)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { try? FileManager.default.removeItem(at: url) }
}

/// A fake server's script as a file named after its content in the temporary directory: the tests and the runs that need
/// the same script share one file, so none piles up there (a folder per test was left behind on every run).
func testScript(_ text: String) throws -> URL {
    let name = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    let url = FileManager.default.temporaryDirectory.appending(path: "OrbTests-\(name).py")
    if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
    return url
}
