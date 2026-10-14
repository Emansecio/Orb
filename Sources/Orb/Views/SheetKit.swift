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
    /// `icon` puts a service's tile before the title (the connector sheets).
    func orbSheet<Footer: View>(_ title: String, subtitle: String? = nil, size: SheetSize = .medium,
                                maxHeight: CGFloat = SheetSize.maxHeight, icon: ServiceMark? = nil,
                                @ViewBuilder footer: () -> Footer) -> some View {
        modifier(OrbSheetFrame(title: title, subtitle: subtitle, size: size, maxHeight: maxHeight, icon: icon, footer: footer()))
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
    let maxHeight: CGFloat
    let icon: ServiceMark?
    let footer: Footer

    // On the sheet's first appearance its parts come in one after another (`sheetSection`): the heading, what it holds,
    // the footer. The presentation itself is the system's and is left alone.
    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Spacing.m) {
                if let icon { ServiceTile(mark: icon) }
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
            }
            .padding(.horizontal, Spacing.sheetEdge)
            .padding(.top, Spacing.sheetHeaderTop)
            .padding(.bottom, Spacing.sheetHeaderBottom)
            .sheetSection(0)
            content
                .orbFormBackground()
                .frame(maxHeight: .infinity, alignment: .top)
                .sheetSection(1)
            footer
                .sheetSection(2)
        }
        .frame(minWidth: size.width, idealWidth: size.width, maxWidth: size.width, maxHeight: maxHeight)
        .background(Palette.chrome)
        .registersOpenSheet()
    }
}

extension View {
    /// Tells the model a sheet is open while this view is on screen, so the menu's navigation commands wait (see
    /// `AppModel.hasOpenSheet`). `orbSheet` does it already; a sheet drawn another way adds it itself.
    func registersOpenSheet() -> some View { modifier(OpenSheetRegistration()) }
}

private struct OpenSheetRegistration: ViewModifier {
    // Optional: a sheet drawn outside the app (a snapshot) has no model and nothing to tell.
    @Environment(AppModel.self) private var model: AppModel?
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { model?.sheetDidOpen(token) }
            .onDisappear { model?.sheetDidClose(token) }
    }
}

/// The frame of a sheet's bottom row: the hairline above, the sheet's side padding (the same as the header's and the
/// body's, so the primary button's right edge is the content's right edge) and one vertical padding, with every
/// control centered on the same line. `SheetFooter` is the usual content; a sheet with other buttons (a copy, a link)
/// puts its own in a `SheetFooterBar`, ending with Cancel and the primary action.
struct SheetFooterBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.controlGap) { content() }
            .frame(minHeight: ControlHeight.regular)
            .padding(.horizontal, Spacing.sheetEdge)
            .padding(.vertical, Spacing.footerVertical)
            .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

/// The bottom row of a sheet: an optional destructive action and a validation message on the left, Cancel and the
/// primary action on the right (Return and Esc work as usual; a destructive sheet takes Return away from the primary
/// action with `primaryIsDefault: false`, so a reflex Return does nothing).
struct SheetFooter: View {
    var message: String?
    var destructiveTitle: String?
    var destructive: (() -> Void)?
    var cancelTitle = "Cancelar"
    let cancel: () -> Void
    let primaryTitle: String
    var isPrimaryDisabled = false
    var primaryIsDefault = true
    /// The primary action destroys something (deleting, resetting): the pill is red instead of white.
    var primaryIsDestructive = false
    /// False when the only button closes the sheet anyway (a finished connection): Esc still does it.
    var showsCancel = true
    /// Hover texts for the buttons whose label alone does not say what they do (the plain "Cancelar" and "Salvar" need none).
    var destructiveHelp = ""
    var cancelHelp = ""
    var primaryHelp = ""
    let primary: () -> Void

    /// Return's shortcut for the primary button, or none when the sheet keeps it from being the default.
    static func primaryShortcut(isDefault: Bool) -> KeyboardShortcut? { isDefault ? .defaultAction : nil }

    var body: some View {
        SheetFooterBar {
            if let destructiveTitle, let destructive {
                Button(destructiveTitle, role: .destructive, action: destructive)
                    .buttonStyle(GhostStyle(tint: Palette.danger))
                    .help(destructiveHelp)
                    .hangsOnLeadingEdge()
            }
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                    .transition(.opacity)
            }
            Spacer(minLength: Spacing.m)
            if showsCancel {
                Button(cancelTitle, action: cancel)
                    .buttonStyle(GhostStyle())
                    .keyboardShortcut(.cancelAction)
                    .help(cancelHelp)
            }
            Button(primaryTitle, action: primary)
                .buttonStyle(PrimaryPillStyle(isDestructive: primaryIsDestructive))
                .keyboardShortcut(SheetFooter.primaryShortcut(isDefault: primaryIsDefault))
                .help(primaryHelp)
                .disabled(isPrimaryDisabled)
        }
        .background {
            if !showsCancel {
                Button("", action: cancel).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
        }
        // The validation note comes, goes and changes by fading (§2.13); the buttons are on the other side and stay put.
        .motion(Motion.content, value: message)
    }
}

/// The row of buttons at the foot of a card (an approval, a proposal, a pause): the quiet action at the leading edge
/// (hanging on it, see `hangsOnLeadingEdge`), a hint if any, and the buttons at the trailing edge, the primary
/// action last. Everything sits on one vertical center, the controls are one height, and the gap between buttons is
/// `Spacing.controlGap`. A card that stacks its buttons because they do not fit puts them in its own layout.
struct ActionRow<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.controlGap) {
            leading()
            Spacer(minLength: Spacing.m)
            trailing()
        }
        .frame(minHeight: ControlHeight.regular)
    }
}

/// The note under a form section ("Todos os Orbs leem o nome…"): caption size, muted ink, aligned to the leading edge
/// and across the full width, like the gray lines inside the cards ("Depois de tarefas longas…"). The grouped form
/// would otherwise draw it body-size, near white and trailing-aligned, bigger than what it explains. A colour set on
/// the content itself (the warning in orange) wins over the footnote's.
struct FormFootnote<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .font(.caption)
            .foregroundStyle(Palette.muted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The same inset as the section's heading, which the grouped form indents past the card's edge.
            .padding(.leading, Self.headingInset)
    }

    static var headingInset: CGFloat { 10 }
}

extension View {
    /// The small bordered button the Orb's panel uses everywhere (its quick actions, the folder, the memory, the
    /// routines): one style and one size, so no row has a taller or plainer button than the next.
    func chipButton() -> some View {
        // The size is said out loud: inside a grouped Form the buttons keep the form's body font whatever the control size,
        // and would come out larger than the same chips in the panel's header.
        buttonStyle(.bordered).controlSize(.small).font(.system(size: 12)).labelStyle(FixedIconLabelStyle())
    }

    /// The gray line under a switch or a picker in the Orb's panel ("Rodar comandos e ler e escrever arquivos").
    func capabilityCaption() -> some View {
        font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A multi-line field with a placeholder, drawn like the app's other inputs (TextEditor has no placeholder and
/// paints its own background).
struct PlaceholderTextEditor: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 80

    /// One line of a sentence or so: even the shortest of these fields holds it without scrolling.
    private var fitsWithoutScrolling: Bool { text.count < 90 && !text.contains("\n") }

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            // A short line has nothing to scroll: no bar (nor the always-shown track, which `.hidden` keeps) until the text
            // could outgrow the field.
            .scrollIndicators(fitsWithoutScrolling ? .never : .automatic)
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
