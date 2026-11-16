import Foundation

/// On-disk layout for Teams inside `ORB_DATA_DIR`, isolated from personal Orbs and manual Groups.
enum TeamFiles {
    /// Root folder under `Store.directory`: `times/<teamID>/`.
    static let rootFolder = "times"
    /// Shared Mission thread (`times/<teamID>/thread.json`).
    static let threadFile = "thread.json"
    /// Live board memory directory (`times/<teamID>/quadro/`).
    static let boardFolder = "quadro"
    /// Per-member execution logs (`times/<teamID>/membros/<memberID>.json`).
    static let membersFolder = "membros"
    /// Dedicated workspace when the Team has no git repository (`times/<teamID>/espaco/`).
    static let workspaceFolder = "espaco"
    /// Structured command and edit trail in autonomous mode (`times/<teamID>/audit.jsonl`).
    static let auditFile = "audit.jsonl"
}
