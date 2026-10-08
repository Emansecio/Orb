import SwiftUI

// One look for every sheet and form: the same background, header, footer buttons and sizes, so a sheet opened from
// the inspector, the catalogs or the settings feels like part of the same app.

/// Sheet widths. Heights follow the content up to `maxHeight`; longer content scrolls inside the sheet.
enum SheetSize {
    case small, medium, large

    var width: CGFloat {
        switch self {
        case .small: 460
        case .medium: 540
        case .large: 640
        }
    }

    static let maxHeight: CGFloat = 560
}

extension View {
    /// A sheet with a title, a one-line explanation under it and the app's background; `footer` sits under the
    /// content (usually a `SheetFooter`).
    func orbSheet<Footer: View>(_ title: String, subtitle: String? = nil, size: SheetSize = .medium,
                                @ViewBuilder footer: () -> Footer) -> some View {
        modifier(OrbSheetFrame(title: title, subtitle: subtitle, size: size, footer: footer()))
    }

    func orbSheet(_ title: String, subtitle: String? = nil, size: SheetSize = .medium) -> some View {
        orbSheet(title, subtitle: subtitle, size: size) { EmptyView() }
    }

    /// Forms and lists drawn on the app's background instead of the system's grouped one.
    func orbFormBackground() -> some View {
        scrollContentBackground(.hidden).background(Palette.chrome)
    }
}

private struct OrbSheetFrame<Footer: View>: ViewModifier {
    let title: String
    let subtitle: String?
    let size: SheetSize
    let footer: Footer

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            content
                .orbFormBackground()
                .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(minWidth: size.width, idealWidth: size.width, maxWidth: size.width, maxHeight: SheetSize.maxHeight)
        .background(Palette.chrome)
    }
}

/// The bottom row of a sheet: an optional destructive action and a validation message on the left, Cancel and the
/// primary action on the right (Return and Esc work as usual).
struct SheetFooter: View {
    var message: String?
    var destructiveTitle: String?
    var destructive: (() -> Void)?
    var cancelTitle = "Cancelar"
    let cancel: () -> Void
    let primaryTitle: String
    var isPrimaryDisabled = false
    let primary: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let destructiveTitle, let destructive {
                Button(destructiveTitle, role: .destructive, action: destructive)
                    .buttonStyle(GhostStyle())
                    .foregroundStyle(Palette.danger)
            }
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button(cancelTitle, action: cancel)
                .buttonStyle(GhostStyle())
                .keyboardShortcut(.cancelAction)
            Button(primaryTitle, action: primary)
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(isPrimaryDisabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

/// A multi-line field with a placeholder, drawn like the app's other inputs (TextEditor has no placeholder and
/// paints its own background).
struct PlaceholderTextEditor: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 80

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(Palette.raised, in: .rect(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.faint)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(placeholder)
    }
}
