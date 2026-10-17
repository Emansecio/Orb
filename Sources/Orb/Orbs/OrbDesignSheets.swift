#if DEBUG || ORB_DEV_TOOLS
import SwiftUI
import AppKit

/// Design-review sheets, rendered offscreen with the static Orb renderer (composited exactly like the app):
/// `Orb --render-orbs out.png <sheet>`. Without a sheet name, `--render-orbs` writes the Orbs × activities sheet.
@MainActor
enum OrbDesignSheet {
    static let names = ["cabelos", "cabelo-padrao", "cabelo-acessorio", "acessorios", "olhos", "bocas", "detalhes", "cores", "tamanhos", "quadros", "reacoes", "polimento", "icone"]

    /// Writes the sheet `name` (one of `names`); false for an unknown name.
    @discardableResult
    static func render(_ name: String, to url: URL) -> Bool {
        switch name {
        case "cabelos": hair(to: url)
        case "cabelo-padrao": defaultHair(to: url)
        case "cabelo-acessorio": hairWithAccessories(to: url)
        case "acessorios": accessories(to: url)
        case "olhos": category(.eyes, to: url)
        case "bocas": category(.mouth, to: url)
        case "detalhes": details(to: url)
        case "cores": colors(to: url)
        case "tamanhos": sizes(to: url)
        case "quadros": frames(to: url)
        case "reacoes": reactions(to: url)
        case "polimento": polish(to: url)
        case "icone": appIcon(to: url)
        default: return false
        }
        return true
    }

    // MARK: Sheets

    /// Every hair style × palettes and custom hair colors, plus a hair + hat combination column.
    private static func hair(to url: URL) {
        let base = OrbConfig(color: "indigo", eyes: "pilulas", mouth: "sorriso")
        let columns: [(String, (inout OrbConfig) -> Void)] = [
            ("Índigo", { $0.color = "indigo" }),
            ("Rosa", { $0.color = "rosa" }),
            ("Menta", { $0.color = "menta" }),
            ("Sol", { $0.color = "sol" }),
            ("Pérola", { $0.color = "perola" }),
            ("Noite", { $0.color = "noite" }),
            ("Castanho", { $0.color = "pessego"; $0.hairColor = 0x5A3B22 }),
            ("Loiro", { $0.color = "ceu"; $0.hairColor = 0xE8B95A }),
            ("Preto", { $0.color = "lavanda"; $0.hairColor = 0x1C1A2B }),
        ]
        let rows = OrbCatalog.shared.options(.hair).map { option in
            (option.label, columns.map { column -> OrbConfig in
                var config = base
                config.hair = option.id
                column.1(&config)
                return config
            })
        }
        write(grid(columns: columns.map(\.0), rows: rows, size: 84), to: url)
    }

    /// Every palette with its default hair color, on a few styles.
    private static func defaultHair(to url: URL) {
        let palettes = OrbCatalog.shared.palettes
        let rows = ["franja", "cachos", "rabo-de-cavalo"].map { hair in
            (OrbCatalog.shared.label(.hair, hair), palettes.map { OrbConfig(color: $0.id, eyes: "pilulas", mouth: "sorriso", hair: hair) })
        }
        write(grid(columns: palettes.map(\.label), rows: rows, size: 64), to: url)
    }

    /// How each hair style wears the head accessories (hats sit on the hair, ears and bows over it).
    private static func hairWithAccessories(to url: URL) {
        let worn = ["cartola", "bone", "gorro", "chapeu-festa", "coroa", "fones", "orelhas-gato", "laco", "aureola", "chifres"]
        let rows = OrbCatalog.shared.options(.hair).filter { $0.id != "nenhum" }.map { option in
            (option.label, worn.map { OrbConfig(color: "ceu", eyes: "pilulas", mouth: "sorriso", hair: option.id, accessories: [$0]) })
        }
        write(grid(columns: worn.map { OrbCatalog.shared.label(.accessories, $0) }, rows: rows, size: 64), to: url)
    }

    private static func accessories(to url: URL) {
        let palettes = ["indigo", "rosa", "menta", "sol", "perola", "grafite"]
        let rows = OrbCatalog.shared.options(.accessories).map { option in
            (option.label, palettes.map { palette in
                OrbConfig(color: palette, eyes: "pilulas", mouth: "sorriso", accessories: [option.id])
            })
        }
        let labels = palettes.map { OrbCatalog.shared.palette($0).label }
        write(grid(columns: labels, rows: rows, size: 84), to: url)
    }

    /// One category's options on a dark palette and a light one.
    private static func category(_ category: OrbCategory, to url: URL) {
        let palettes = ["indigo", "coral", "menta", "perola", "noite"]
        let rows = OrbCatalog.shared.options(category).map { option in
            (option.label, palettes.map { palette -> OrbConfig in
                var config = OrbConfig(color: palette, eyes: "pilulas", mouth: "sorriso")
                config.set(category, option.id)
                return config
            })
        }
        write(grid(columns: palettes.map { OrbCatalog.shared.palette($0).label }, rows: rows, size: 84), to: url)
    }

    /// Brows, cheeks and mustaches.
    private static func details(to url: URL) {
        var rows: [(String, [OrbConfig])] = []
        let palettes = ["indigo", "rosa", "sol", "perola"]
        for category in [OrbCategory.brows, .cheeks, .mustache] {
            for option in OrbCatalog.shared.options(category) where !["nenhuma", "nenhum"].contains(option.id) {
                rows.append(("\(category.label): \(option.label)", palettes.map { palette in
                    var config = OrbConfig(color: palette, eyes: "pilulas", mouth: "sorriso")
                    config.set(category, option.id)
                    return config
                }))
            }
        }
        write(grid(columns: palettes.map { OrbCatalog.shared.palette($0).label }, rows: rows, size: 84), to: url)
    }

    private static func colors(to url: URL) {
        let palettes = OrbCatalog.shared.palettes
        let chunks = stride(from: 0, to: palettes.count, by: 6).map { Array(palettes[$0..<min($0 + 6, palettes.count)]) }
        let rows = chunks.enumerated().map { index, chunk in
            ("\(index + 1)", chunk.map { OrbConfig(color: $0.id, eyes: "pilulas", mouth: "sorriso", cheeks: "blush") })
        }
        write(grid(columns: chunks[0].map(\.label), rows: rows, size: 96), to: url)
    }

    /// Readability at every size the app uses (18 pt up), on the dark canvas and on a light background.
    private static func sizes(to url: URL) {
        let orbs = sampleOrbs
        // 18 pt: the menu-bar Pergunta rápida's status; 30: sidebar; 60: panel; 96: empty chat; 132: large.
        let sizes: [CGFloat] = [18, 30, 60, 96, 132]
        let sheet = VStack(alignment: .leading, spacing: 18) {
            ForEach([false, true], id: \.self) { light in
                HStack(alignment: .bottom, spacing: 26) {
                    ForEach(Array(orbs.enumerated()), id: \.offset) { _, orb in
                        HStack(alignment: .bottom, spacing: 14) {
                            ForEach(sizes, id: \.self) { size in
                                OrbView(config: orb, size: size, animated: false)
                                    .frame(width: size * 1.25, height: size * 1.6, alignment: .bottom)
                            }
                        }
                    }
                }
                .padding(24)
                .background(light ? Color(hex: 0xF4F4F6) : Palette.canvas)
            }
        }
        .background(Palette.canvas)
        write(sheet, to: url)
    }

    /// Two seconds of each activity, 12 frames per row, from the same motion functions the live orb uses.
    private static func frames(to url: URL) {
        let orb = OrbConfig(color: "rosa", eyes: "ovais", mouth: "sorriso", cheeks: "blush", hair: "coque")
        let activities: [OrbActivity] = [.idle, .speaking, .thinking, .typing, .waiting, .happy, .error, .sleepy]
        let times = (0..<12).map { Double($0) / 6 }
        let sheet = VStack(alignment: .leading, spacing: 8) {
            ForEach(activities) { activity in
                poseRow(label: activity.label, orb: orb, activity: activity, poses: OrbPosePreview.poses(activity: activity, at: times))
            }
        }
        .padding(24)
        .background(Palette.canvas)
        write(sheet, to: url)
    }

    /// The Orb reacting to the interface: idle, watching you type (`attentive`) and the selection glance, frame by
    /// frame (every 50 ms for the glance).
    private static func reactions(to url: URL) {
        let orb = OrbConfig(color: "rosa", eyes: "ovais", mouth: "sorriso", cheeks: "blush", hair: "coque")
        let times = (0..<13).map { Double($0) / 6 }
        let glanceTimes = (0..<13).map { Double($0) * 0.05 }
        let idle = OrbPosePreview.poses(activity: .idle, at: times.map { $0 + 3 })
        let glance = zip(OrbPosePreview.poses(activity: .idle, at: glanceTimes.map { $0 + 3 }), glanceTimes).map { pose, time in
            var pose = pose
            pose.blink = 0
            OrbGlance.apply(to: &pose, elapsed: time)
            return pose
        }
        let rows: [(String, OrbActivity, [OrbPose])] = [
            ("Parado", .idle, idle),
            ("Atento", .attentive, OrbPosePreview.poses(activity: .attentive, at: times.map { $0 + 3 })),
            ("Selecionado", .idle, glance),
        ]
        let sheet = VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.0) { label, activity, poses in
                poseRow(label: label, orb: orb, activity: activity, poses: poses)
            }
        }
        .padding(24)
        .background(Palette.canvas)
        write(sheet, to: url)
    }

    /// The reactions of the polishing round, frame by frame: the three sizes of joy, "precisa de você" over a minute
    /// (its first 3 s, then the hops every 7 s, then after a minute), the error and its "no", and the three jumps.
    private static func polish(to url: URL) {
        let orb = OrbConfig(color: "rosa", eyes: "ovais", mouth: "sorriso", cheeks: "blush", hair: "coque")
        func at(_ step: Double, count: Int = 13) -> [Double] { (0..<count).map { Double($0) * step } }
        func jump(_ kind: OrbJump) -> [OrbPose] {
            let times = at(kind.duration / 12)
            return zip(OrbPosePreview.poses(activity: .idle, at: times.map { $0 + 3 }), times).map { pose, time in
                var pose = pose
                let offset = kind.offset(at: time, jump: 1)
                pose.lift += offset.lift
                pose.squash += offset.squash
                return pose
            }
        }
        let landing = OrbJump.landing
        let landingTimes = at(0.01, count: 13)
        let landed: [OrbPose] = zip(OrbPosePreview.poses(activity: .idle, at: landingTimes.map { $0 + 3 }), landingTimes).map { pose, time in
            var pose = pose
            pose.squash += landing.offset(at: time, jump: 1).squash
            return pose
        }
        let rows: [(String, OrbActivity, [OrbPose])] = [
            ("Feliz leve", .happy, OrbPosePreview.poses(activity: .happy, at: at(1.6 / 12), celebration: .light)),
            ("Feliz normal", .happy, OrbPosePreview.poses(activity: .happy, at: at(2.2 / 12), celebration: .normal)),
            ("Feliz grande", .happy, OrbPosePreview.poses(activity: .happy, at: at(3.0 / 12), celebration: .big)),
            ("Precisa 0-3 s", .waiting, OrbPosePreview.poses(activity: .waiting, at: at(0.25))),
            ("Precisa 3-10 s", .waiting, OrbPosePreview.poses(activity: .waiting, at: at(0.6).map { $0 + 3 })),
            ("Precisa 60 s", .waiting, OrbPosePreview.poses(activity: .waiting, at: at(0.6).map { $0 + 66 })),
            ("Erro 0-2,4 s", .error, OrbPosePreview.poses(activity: .error, at: at(0.2))),
            ("Envio", .idle, jump(.ack)),
            ("Clique", .idle, jump(.play)),
            ("Aterrissagem", .idle, landed),
        ]
        let sheet = VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.0) { label, activity, poses in
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 96, alignment: .leading)
                    ForEach(Array(poses.enumerated()), id: \.offset) { _, pose in
                        OrbFrame(config: orb, activity: activity, size: 64, pose: pose)
                            .frame(width: 84, height: 108)
                    }
                }
            }
        }
        .padding(24)
        .background(Palette.canvas)
        write(sheet, to: url)
    }

    /// The app icon at every size it ships in (`AppIcon`), drawn pixel for pixel on a light and a dark wallpaper:
    /// each size at its real size (the two big ones shrunk), and the small ones again magnified without smoothing (128 ×2, the rest ×4). Written at 1× (no 2× pass),
    /// so what is seen is what the Dock and Finder get.
    private static func appIcon(to url: URL) {
        let pixels = iconSizes
        let icons = pixels.map { ($0, AppIcon.image(pixels: $0)) }
        let band = iconBand
        let layout = iconLayout(pixels: pixels)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(band.width), height: Int(band.height) * 2, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        for (index, wallpaper) in [(0.93, 0.93, 0.93), (0.118, 0.118, 0.118)].enumerated() {
            let y0 = CGFloat(1 - index) * band.height
            ctx.setFillColor(CGColor(srgbRed: wallpaper.0, green: wallpaper.1, blue: wallpaper.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y0, width: band.width, height: band.height))
            // Row 1 (top): every size, 1024 and 512 shrunk to fit; the rest at their real size (256 included).
            for (px, icon) in icons {
                guard let rect = layout.row1[px] else { continue }
                ctx.interpolationQuality = px >= 512 ? .high : .none
                ctx.draw(icon, in: rect.offsetBy(dx: 0, dy: y0))
            }
            // Row 2: the small sizes magnified without smoothing.
            ctx.interpolationQuality = .none
            for (px, icon) in icons {
                guard let rect = layout.row2[px] else { continue }
                ctx.draw(icon, in: rect.offsetBy(dx: 0, dy: y0))
            }
        }
        guard let image = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    static let iconSizes = [1024, 512, 256, 128, 64, 32, 16]
    /// One wallpaper band of the icon sheet: tall enough for the 256 px icon of row 1 to clear the magnified 64 px of row 2.
    static let iconBand = CGSize(width: 1040, height: 560)

    /// Where each size is drawn inside one band (origin at the band's bottom left): row 1 at real size (1024 and 512 shrunk),
    /// row 2 the small ones magnified (128 x2, the rest x4). The rows never overlap.
    static func iconLayout(pixels: [Int]) -> (row1: [Int: CGRect], row2: [Int: CGRect]) {
        var row1: [Int: CGRect] = [:], row2: [Int: CGRect] = [:]
        var x: CGFloat = 20
        for px in pixels {
            let shown: CGFloat = px >= 512 ? 180 : CGFloat(px)
            row1[px] = CGRect(x: x, y: iconBand.height - 20 - shown, width: shown, height: shown)
            x += shown + 24
        }
        x = 20
        for px in pixels where px <= 128 {
            let shown = CGFloat(px) * (px == 128 ? 2 : 4)
            row2[px] = CGRect(x: x, y: 20, width: shown, height: shown)
            x += shown + 24
        }
        return (row1, row2)
    }

    // MARK: Helpers

    /// One labeled row of frames: the Orb at each of `poses`.
    private static func poseRow(label: String, orb: OrbConfig, activity: OrbActivity, poses: [OrbPose]) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 96, alignment: .leading)
            ForEach(Array(poses.enumerated()), id: \.offset) { _, pose in
                OrbFrame(config: orb, activity: activity, size: 64, pose: pose)
                    .frame(width: 84, height: 108)
            }
        }
    }

    static let sampleOrbs = OrbBench.looks

    private static func grid(columns: [String], rows: [(String, [OrbConfig])], size: CGFloat) -> some View {
        let cell = CGSize(width: size * 1.35, height: size * 1.75)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 120, height: 20)
                ForEach(columns, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: cell.width)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    Text(row.0)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 120, alignment: .leading)
                    ForEach(Array(row.1.enumerated()), id: \.offset) { _, config in
                        OrbView(config: config, size: size, animated: false)
                            .frame(width: cell.width, height: cell.height)
                    }
                }
            }
        }
        .padding(24)
        .background(Palette.canvas)
    }

    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Poses of an activity over time for review sheets: the activity's body motion and gaze, a blink and the
/// hair's follow-through spring, simulated at 60 fps like the live orb (no pointer, no randomness).
enum OrbPosePreview {
    static func poses(activity: OrbActivity, at times: [Double], celebration: OrbCelebration = .big) -> [OrbPose] {
        var loose = SpringPoint(), head = SpringPoint(), swing = Spring()
        var result: [OrbPose] = []
        var time = 0.0
        let dt = 1.0 / 60
        for target in times {
            var pose = OrbPose()
            repeat {
                let motion = activity.motion(at: time, elapsed: time, celebration: celebration)
                pose = OrbPose()
                pose.lift = motion.lift
                pose.squash = motion.squash
                pose.tilt = motion.tilt
                pose.shake = motion.shake
                pose.glow = motion.glow
                head.step(toward: activity.gaze(at: time).look, dt: dt, response: OrbSprings.head.response,
                          damping: OrbSprings.head.damping)
                pose.look = head.value
                pose.hairLag = OrbSprings.hairLag(&loose, anchor: OrbSprings.hairAnchor(look: pose.look, lift: pose.lift), dt: dt)
                pose.hairSwing = OrbSprings.hairSwing(&swing, tilt: pose.tilt, dt: dt)
                pose.blink = Blinker.closure(time - 1.5) * Blinker.factor(eyes: activity.eyes ?? "")
                time += dt
            } while time < target
            result.append(pose)
        }
        return result
    }
}
#endif
