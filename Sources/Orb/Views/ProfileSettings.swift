import SwiftUI
import AppKit

// Ajustes → Geral → "Você": who the user is (name, what to call them, a few lines about them, a photo). The Orbs read the
// text in every conversation (`UserProfile.promptSection`); the photo stays on the Mac.

struct ProfileSettings: View {
    @Environment(AppModel.self) private var model
    @State private var isImporting = false
    @State private var isDropTarget = false
    @State private var photoError: String?

    var body: some View {
        Section {
            HStack(spacing: 14) {
                Button { isImporting = true } label: {
                    ProfileAvatar(photoPath: model.profilePhotoPath, initial: model.profile.initial, size: 64)
                        .overlay { Circle().strokeBorder(Palette.accent, lineWidth: 2).opacity(isDropTarget ? 1 : 0) }
                        .animation(Motion.press, value: isDropTarget)
                }
                .buttonStyle(.plain)
                .help(Tip.profilePhotoAvatar)
                .accessibilityLabel("Foto do perfil")
                .accessibilityHint("Escolhe uma imagem")
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: \.isFileURL) else { return false }
                    setPhoto(url)
                    return true
                } isTargeted: { isDropTarget = $0 }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Button(model.profile.photo.isEmpty ? "Escolher foto…" : "Trocar foto…") { isImporting = true }
                            .help(Tip.profilePhotoChoose)
                            .chipButton()
                        if !model.profile.photo.isEmpty {
                            Button("Remover foto") { model.removeProfilePhoto(); photoError = nil }
                                .buttonStyle(GhostStyle())
                                .controlSize(.small)
                                .help(Tip.profilePhotoRemove)
                        }
                    }
                    Text("Ou arraste uma imagem para o círculo.")
                        .font(.caption)
                        .foregroundStyle(Palette.faint)
                }
                Spacer(minLength: 0)
            }
            if let photoError {
                Label(photoError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.danger)
            }
            field("Nome", prompt: "Como você se chama", \.name, limit: UserProfile.nameLimit)
            field("Como te chamar", prompt: model.profile.name.split(separator: " ").first.map(String.init) ?? "Opcional",
                  \.nickname, limit: UserProfile.nicknameLimit)
            VStack(alignment: .leading, spacing: 6) {
                Text("Sobre você")
                LimitedTextField(title: "Sobre você", prompt: "Ex.: trabalho com design, prefiro respostas curtas e moro em Recife.",
                                 limit: UserProfile.aboutLimit, axis: .vertical, value: binding(\.about))
                    .lineLimit(3...6)
                if let counter = Self.aboutCounter(count: model.profile.about.count) {
                    Text(counter.text)
                        .font(.caption)
                        .foregroundStyle(counter.atLimit ? Palette.warn : Palette.faint)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        } header: {
            Text("Você")
        } footer: { FormFootnote {
            Text("Todos os Orbs leem o nome, como te chamar e o texto “Sobre você” em cada conversa, e isso vai ao provedor do modelo junto com a mensagem. A foto fica só neste Mac.")
        } }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { setPhoto(url) }
        }
    }

    /// The "n/limit" counter under "Sobre você": it shows from 80% of the limit on, in the warning color at the limit.
    /// The count is taken once by the caller (it walks the string).
    static func aboutCounter(count: Int) -> (text: String, atLimit: Bool)? {
        guard count >= UserProfile.aboutLimit * 4 / 5 else { return nil }
        return ("\(count)/\(UserProfile.aboutLimit)", count >= UserProfile.aboutLimit)
    }

    private func field(_ title: String, prompt: String, _ keyPath: WritableKeyPath<UserProfile, String>, limit: Int) -> some View {
        LabeledContent(title) {
            LimitedTextField(title: title, prompt: prompt, limit: limit, axis: .horizontal, value: binding(keyPath))
                .multilineTextAlignment(.trailing)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<UserProfile, String>) -> Binding<String> {
        Binding(get: { model.profile[keyPath: keyPath] }, set: { model.profile[keyPath: keyPath] = $0 })
    }

    private func setPhoto(_ url: URL) {
        Task { photoError = await model.setProfilePhoto(fileAt: url) }
    }
}

/// A text field that cuts what goes past its limit. The cut is made on the field's own copy: cutting only in a binding's
/// setter leaves the field showing the extra text when the stored value does not change.
private struct LimitedTextField: View {
    let title: String
    let prompt: String
    let limit: Int
    let axis: Axis
    let value: Binding<String>
    @State private var text: String

    init(title: String, prompt: String, limit: Int, axis: Axis, value: Binding<String>) {
        self.title = title
        self.prompt = prompt
        self.limit = limit
        self.axis = axis
        self.value = value
        _text = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt), axis: axis)
            .labelsHidden()
            .textFieldStyle(.plain)
            .onChange(of: text) {
                let cut = String(text.prefix(limit))
                if cut != text { text = cut }
                // Cutting sets `text` again and fires this once more with the same value: store only a change, since
                // every store reaches `model.profile` (its didSet, a state write and the invalidation of its readers).
                if value.wrappedValue != cut { value.wrappedValue = cut }
            }
    }
}

/// The user's round picture: the photo, else the first letter of their name, else a silhouette that invites filling
/// the profile in. Used in Ajustes (64 pt) and at the foot of the sidebar (28 pt).
struct ProfileAvatar: View {
    let photoPath: String?
    let initial: String?
    let size: CGFloat
    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(photoPath: String?, initial: String?, size: CGFloat) {
        self.photoPath = photoPath
        self.initial = initial
        self.size = size
        _image = State(initialValue: photoPath.flatMap { Thumbnails.cached(path: $0, side: size) })
    }

    var body: some View {
        ZStack {
            Palette.raised
            if let initial {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.46))
                    .foregroundStyle(Palette.muted)
            }
            if let image {
                // A new photo arrives over the old one by fading (opacity alone, so it also holds under Reduce Motion).
                Image(nsImage: image).resizable().scaledToFill()
                    .id(photoPath)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay { Circle().strokeBorder(Palette.line) }
        .accessibilityHidden(true)
        .task(id: photoPath) {
            guard let photoPath else { return set(nil) }
            if let image, image === Thumbnails.cached(path: photoPath, side: size) { return }
            set(await Thumbnails.image(at: photoPath, side: size))
        }
    }

    private func set(_ new: NSImage?) {
        withAnimation(reduceMotion ? nil : Motion.content) { image = new }
    }
}

// MARK: - Snapshots

#if DEBUG || ORB_DEV_TOOLS
/// What `--snapshot settings-profile | sidebar-profile` shows: a made-up profile with a photo drawn on the spot, in the
/// snapshot's own data folder (never the user's).
@MainActor
enum ProfileSnapshots {
    static func fill(_ model: AppModel) {
        let photos = ProfilePhoto(dataFolder: model.store.directory)
        let fileName = "foto-exemplo.png"
        try? FileManager.default.createDirectory(at: photos.directory, withIntermediateDirectories: true)
        try? portrait().write(to: photos.url(for: fileName))
        model.profile = UserProfile(name: "Marina Costa", nickname: "Mari",
                                    about: "Trabalho com design de produto e prefiro respostas curtas e diretas. Moro em Recife e escrevo em português.",
                                    photo: fileName)
    }

    /// A head and shoulders on a warm gradient, 256 px square.
    private static func portrait() -> Data {
        let side = 256
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return Data() }
        let colors = [CGColor(red: 0.98, green: 0.62, blue: 0.40, alpha: 1), CGColor(red: 0.55, green: 0.32, blue: 0.85, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.88))
        context.fillEllipse(in: CGRect(x: 88, y: 118, width: 80, height: 88))
        context.fillEllipse(in: CGRect(x: 48, y: -70, width: 160, height: 170))
        guard let image = context.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }
}
#endif
