import Foundation

/// orbgen: procedural layers for the Orb app.
///
///     swift run -c release --package-path art/orbgen orbgen all            # same as faces (the body is the plush
///                                                                           # from art/pelucia.py)
///     swift run -c release --package-path art/orbgen orbgen faces [categories…]  # seat the flat Blender layers
///     swift run -c release --package-path art/orbgen orbgen body [ids…]     # the old satin body, overwrites the plush
///     swift run -c release --package-path art/orbgen orbgen preview out.png  # quick contact sheet
///
/// Layers are written to Sources/Orb/Resources/Orbs (override with --out <dir>).
@main
enum OrbGen {
    static let defaultResources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Orb/Resources/Orbs")

    /// Flat feature layers rendered by Blender (`art/orbs.py layers --out art/orbgen/flat`).
    static let flatFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("flat")

    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var resources = defaultResources
        if let flag = arguments.firstIndex(of: "--out"), arguments.indices.contains(flag + 1) {
            resources = URL(fileURLWithPath: arguments[flag + 1])
            arguments.removeSubrange(flag...(flag + 1))
        }
        guard let command = arguments.first else {
            print("uso: orbgen all | faces [categorias…] | body [ids…] | clean [pasta] | preview out.png [tile]")
            exit(2)
        }
        let only = Set(arguments.dropFirst())
        do {
            let start = Date()
            switch command {
            case "all":
                // The body is the plush from Blender (art/pelucia.py): `all` must not paint the satin one over it.
                try Decals.run(flat: flatFolder, resources: resources, only: [])
            case "body": try renderBodies(into: resources, only: only)
            case "clean":
                // Re-encodes PNGs under a folder: transparent pixels lose their hidden color (Blender keeps it),
                // which makes the files several times smaller. Nothing visible changes.
                let folder = URL(fileURLWithPath: arguments.dropFirst().first ?? flatFolder.path)
                let files = FileManager.default.enumerator(atPath: folder.path)?.compactMap { $0 as? String } ?? []
                for file in files where file.hasSuffix(".png") {
                    let url = folder.appendingPathComponent(file)
                    try Canvas.read(url).writePNG(to: url)
                }
                print("limpos", files.filter { $0.hasSuffix(".png") }.count)
            case "faces":
                // The flat Blender renders live next to this package (see art/README.md).
                try Decals.run(flat: flatFolder, resources: resources, only: only)
            case "preview":
                // preview out.png [tile]
                let rest = Array(arguments.dropFirst())
                guard let path = rest.first else { throw ArtError.usage("preview <out.png> [tile]") }
                try Preview.sheet(resources: resources, to: URL(fileURLWithPath: path), tile: rest.dropFirst().first.flatMap { Int($0) } ?? 200)
            default: throw ArtError.usage("comando desconhecido: \(command)")
            }
            print(String(format: "pronto em %.1f s", Date().timeIntervalSince(start)))
        } catch {
            print("erro: \(error)")
            exit(1)
        }
    }

    static func renderBodies(into resources: URL, only: Set<String>) throws {
        for palette in try Palette.load(from: resources) where only.isEmpty || only.contains(palette.id) {
            let shader = BodyShader(palette)
            let canvas = Canvas.render { u, v in shader.shade(u, v) }
            try canvas.writePNG(to: resources.appendingPathComponent("body/\(palette.id).png"))
            print("corpo", palette.id)
        }
    }
}
