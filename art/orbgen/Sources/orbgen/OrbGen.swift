import Foundation

/// orbgen: procedural layers for the Orb app.
///
///     swift run -c release --package-path art/orbgen orbgen all            # faces + body + hair + manifest
///     swift run -c release --package-path art/orbgen orbgen faces [categories…]  # seat the flat Blender layers
///     swift run -c release --package-path art/orbgen orbgen body [ids…]
///     swift run -c release --package-path art/orbgen orbgen hair [ids…]       # also updates options.json
///     swift run -c release --package-path art/orbgen orbgen manifest          # hair ids/labels + default hair colors
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
            print("uso: orbgen all | body [ids…] | hair [ids…] | manifest | preview out.png [tile] [ids…] | zoom out.png paleta[:hex] ids…")
            exit(2)
        }
        let only = Set(arguments.dropFirst())
        do {
            let start = Date()
            switch command {
            case "all":
                try Decals.run(flat: flatFolder, resources: resources, only: [])
                try renderBodies(into: resources, only: [])
                try renderHair(into: resources, only: [])
                try Manifest.update(resources: resources)
            case "body": try renderBodies(into: resources, only: only)
            case "hair":
                try renderHair(into: resources, only: only)
                try Manifest.update(resources: resources)
            case "manifest": try Manifest.update(resources: resources)
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
                // preview out.png [tile] [hair ids…]
                let rest = Array(arguments.dropFirst())
                guard let path = rest.first else { throw ArtError.usage("preview <out.png> [tile] [ids…]") }
                let tile = rest.dropFirst().first.flatMap { Int($0) }
                let ids = Array(rest.dropFirst(tile == nil ? 1 : 2))
                try Preview.sheet(resources: resources, to: URL(fileURLWithPath: path), hairs: ids, tile: tile ?? 200)
            case "zoom":
                // zoom out.png palette[:hex] hair… — big tiles of one palette, for close inspection.
                let rest = Array(arguments.dropFirst())
                guard rest.count >= 3 else { throw ArtError.usage("zoom <out.png> <palette[:hex]> <hair ids…>") }
                let parts = rest[1].split(separator: ":")
                let tint = parts.count > 1 ? UInt32(parts[1], radix: 16) : nil
                try Preview.sheet(resources: resources, to: URL(fileURLWithPath: rest[0]), hairs: Array(rest.dropFirst(2)),
                                  tile: 420, columns: [(String(parts[0]), tint)])
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

    static func renderHair(into resources: URL, only: Set<String>) throws {
        let folder = resources.appendingPathComponent("hair")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for style in HairStyle.all where only.isEmpty || only.contains(style.id) {
            let start = Date()
            let layers = HairRenderer(style: style).render()
            try layers.base.writePNG(to: folder.appendingPathComponent("\(style.id).png"))
            try layers.shine.writePNG(to: folder.appendingPathComponent("\(style.id)-brilho.png"))
            if let hatted = style.underHat?() {
                let layers = HairRenderer(style: hatted).render()
                try layers.base.writePNG(to: folder.appendingPathComponent("\(style.id)-chapeu.png"))
                try layers.shine.writePNG(to: folder.appendingPathComponent("\(style.id)-chapeu-brilho.png"))
            }
            print(String(format: "cabelo %@ (%.1f s)", style.id, Date().timeIntervalSince(start)))
        }
    }
}
