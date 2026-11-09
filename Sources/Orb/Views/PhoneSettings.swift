import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// Ajustes → Celular: turns the phone access on, shows the QR code a phone pairs with and the phones connected now.
struct PhoneSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PhoneAccess.enabledKey) private var isOn = false
    @AppStorage(PhoneAccess.keepAwakeKey) private var keepsAwake = true
    @State private var isConfirmingRenew = false

    var body: some View {
        let phone = model.phone
        Form {
            Section {
                Toggle(isOn: Binding(get: { isOn }, set: { phone.setEnabled($0) })) {
                    toggleLabel("Acessar os Orbs pelo celular",
                                "Converse com os Orbs, acompanhe as respostas e responda aos pedidos pelo app Orb no Android, de qualquer lugar.")
                }
                if isOn {
                    Toggle(isOn: Binding(get: { keepsAwake }, set: { keepsAwake = $0; phone.syncAwake() })) {
                        toggleLabel("Não deixar o Mac dormir",
                                    "Com o Mac dormindo, o celular não chega aos Orbs. A tela ainda apaga normalmente.")
                    }
                }
            } header: {
                Text("Celular")
            } footer: { FormFootnote {
                Text("A conexão passa pelo Tailscale, uma rede privada e criptografada entre os seus aparelhos. Nenhuma porta fica aberta para a internet.")
            } }
            if isOn { pairing(phone) }
            if isOn, phone.status == .listening {
                Section("Conectados agora") {
                    if phone.devices.isEmpty {
                        Text("Nenhum celular conectado.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(phone.devices) { device in
                            LabeledContent(device.name) {
                                Text(device.since, format: .relative(presentation: .named))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .orbFormBackground()
        .onAppear { phone.refreshAddress() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in phone.refreshAddress() }
    }

    @ViewBuilder private func pairing(_ phone: PhoneAccess) -> some View {
        Section("Parear um celular") {
            switch phone.status {
            case .off, .starting:
                ProgressView().controlSize(.small)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warn)
                Button("Tentar de novo") { phone.setEnabled(true) }
                if phone.canRenewAfterFailure {
                    Button("Gerar novo código…") { isConfirmingRenew = true }
                        .help("Troca o código: os celulares pareados com o atual precisam ler o novo")
                        .confirmationDialog("Gerar um novo código?", isPresented: $isConfirmingRenew, titleVisibility: .visible) {
                            Button("Gerar e desconectar os celulares") { phone.renewToken() }
                            Button("Cancelar", role: .cancel) {}
                        } message: {
                            Text("Os celulares pareados agora saem e precisam ler o novo código.")
                        }
                }
            case .listening:
                if let link = phone.pairingLink, let image = QRCode.image(link) {
                    HStack(alignment: .top, spacing: Spacing.l) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 168, height: 168)
                            .padding(Spacing.s)
                            .background(.white, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("Código QR para parear o celular")
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            Text("1. Instale o Tailscale no celular e entre com a mesma conta deste Mac.")
                            Text("2. Abra o app Orb no celular e toque em Ler QR code.")
                            Text("3. Aponte para este código.")
                            Text("Endereço: \(phone.address ?? "")")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, Spacing.s)
                    Button("Gerar novo código…") { isConfirmingRenew = true }
                        .help("Troca o código: os celulares pareados com o atual precisam ler o novo")
                        .confirmationDialog("Gerar um novo código?", isPresented: $isConfirmingRenew, titleVisibility: .visible) {
                            Button("Gerar e desconectar os celulares") { phone.renewToken() }
                            Button("Cancelar", role: .cancel) {}
                        } message: {
                            Text("Os celulares pareados agora saem e precisam ler o novo código.")
                        }
                } else {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Label("O Tailscale não está ligado neste Mac.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.warn)
                        Text("Instale o Tailscale, entre com a sua conta e ligue-o. O código aparece aqui em seguida.")
                            .foregroundStyle(.secondary)
                        Link("Baixar o Tailscale", destination: URL(string: "https://tailscale.com/download/mac")!)
                    }
                }
            }
        }
    }
}

/// A QR code as a crisp image (one point per module; `interpolation(.none)` keeps it sharp when scaled).
enum QRCode {
    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
