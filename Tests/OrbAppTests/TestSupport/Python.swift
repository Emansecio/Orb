import Foundation

/// Whether the system Python is there, for the suites that run a small MCP server written in Python
/// (`@Suite(.enabled(if: hasPython))`).
let hasPython = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
