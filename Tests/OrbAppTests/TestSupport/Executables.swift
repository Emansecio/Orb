import Foundation

extension URL {
    /// `chmod 755`: lets a script written by a test be run as a program.
    func makeExecutable() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}

/// Writes a script (or any text) to `url` and makes it executable.
func writeExecutable(_ text: String, to url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
    try url.makeExecutable()
}
