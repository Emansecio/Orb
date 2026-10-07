import Foundation

/// Spots shell commands that can destroy data or the system, so "Automático" still asks before running them
/// (and "Sempre permitir" never covers them). Deliberately conservative: a few well-known patterns, no parsing.
enum DangerousCommand {
    private static let rules: [(pattern: String, reason: String)] = [
        (#"\brm\s+(-[a-zA-Z]*[rRf][a-zA-Z]*\s+)+"#, "apaga arquivos de forma recursiva ou forçada"),
        (#"\bsudo\b"#, "roda como administrador"),
        (#"\bgit\s+push\b.*(\s--force\b|\s-f\b|\s--force-with-lease\b)"#, "sobrescreve o histórico remoto do git"),
        (#"\bgit\s+reset\s+--hard\b"#, "descarta mudanças do git"),
        (#"\bgit\s+clean\s+-[a-zA-Z]*f"#, "apaga arquivos não versionados"),
        (#"\b(mkfs(\.\w+)?|diskutil\s+(erase\w*|partitionDisk|zeroDisk)|newfs\w*)\b"#, "formata ou apaga um disco"),
        (#"\bdd\s+.*\bof=/dev/"#, "grava direto num disco"),
        (#">\s*/dev/(r?disk|sd)\w*"#, "grava direto num disco"),
        (#"\b(chmod|chown)\s+-[a-zA-Z]*R[a-zA-Z]*\s+\S*\s*(/|~)(\s|$)"#, "muda permissões de tudo a partir da raiz ou da pasta pessoal"),
        (#"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z|fi)?sh\b"#, "baixa e executa um script da internet"),
        (#"\b(shutdown|reboot|halt)\b"#, "desliga ou reinicia o Mac"),
        (#"\b(killall|pkill)\b"#, "encerra processos em massa"),
        (#"\blaunchctl\s+(unload|bootout|remove)\b"#, "desativa serviços do sistema"),
        (#"\bcsrutil\b|\bspctl\s+--master-disable\b"#, "mexe na proteção do sistema"),
        (#":\(\)\s*\{\s*:\|:&\s*\};:"#, "trava o sistema (fork bomb)"),
    ]

    /// Why the command is dangerous, or nil if none of the patterns match.
    static func reason(for command: String) -> String? {
        for rule in rules where command.range(of: rule.pattern, options: .regularExpression) != nil {
            return rule.reason
        }
        return nil
    }
}
