import SwiftUI

// The Orb's panel draws its own sections instead of a grouped `Form`: the system's grouped card is a flat fill with a
// hairline that takes no background, border or shadow of its own, so the panel's cards read as flat boxes. These keep
// the `Section { } header: { } footer: { }` shape the tabs were written in, on the app's one card (`CardSurface`).

/// The scrolling page of one tab: its sections one under another, the rows laid out as a form's are (a switch or a
/// picker at the trailing edge of its row).
struct PanelPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PanelMetrics.sectionGap) {
                content()
            }
            .padding(.horizontal, PanelMetrics.pageInset)
            .padding(.top, PanelMetrics.pageTop)
            .padding(.bottom, PanelMetrics.pageBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .toggleStyle(PanelSwitchStyle())
        .labeledContentStyle(PanelLabeledStyle())
        .pickerStyle(.menu)
    }
}

enum PanelMetrics {
    static let pageInset: CGFloat = 14
    static let pageTop: CGFloat = 14
    static let pageBottom: CGFloat = 24
    /// Between one section's footer and the next one's title.
    static let sectionGap: CGFloat = 22
    static let rowInset: CGFloat = 12
    static let rowVertical: CGFloat = 9
    static let rowMinHeight: CGFloat = 38
    /// The title and the note sit a little in from the card's edge, on the rows' text.
    static let captionInset: CGFloat = 4
}

/// A titled card of rows with an optional note under it. The rows are told apart by an inset hairline.
struct PanelSection<Content: View, Header: View, Footer: View>: View {
    private let content: Content
    private let header: Header
    private let footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, PanelMetrics.captionInset)
                .padding(.bottom, 7)
            PanelCard { content }
            // `FormFootnote` brings its own inset (made for the grouped form's): this takes it back to the title's.
            footer
                .padding(.leading, PanelMetrics.captionInset - FormFootnote<EmptyView>.headingInset)
                .padding(.trailing, PanelMetrics.captionInset)
                .padding(.top, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PanelSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension PanelSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension PanelSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

/// The card itself: each row padded as a form row, a hairline between rows (not above the first).
struct PanelCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        rows
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
    }

    @ViewBuilder private var rows: some View {
        if #available(macOS 15, *) {
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content()) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.element.id) { index, row in
                        PanelRow(isFirst: index == 0) { row }
                    }
                }
            }
        } else {
            // macOS 14 cannot list a builder's rows one by one: the rows are spaced instead of ruled.
            VStack(alignment: .leading, spacing: Spacing.xs) {
                content()
            }
            .padding(.horizontal, PanelMetrics.rowInset)
            .padding(.vertical, PanelMetrics.rowVertical)
        }
    }
}

private struct PanelRow<Content: View>: View {
    let isFirst: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, minHeight: PanelMetrics.rowMinHeight - 2 * PanelMetrics.rowVertical, alignment: .leading)
            .padding(.horizontal, PanelMetrics.rowInset)
            .padding(.vertical, PanelMetrics.rowVertical)
            .overlay(alignment: .top) {
                if !isFirst {
                    Rectangle()
                        .fill(PanelSurface.rule)
                        .frame(height: 1)
                        .padding(.horizontal, PanelMetrics.rowInset)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// The panel's card is the app's one card (`CardSurface`), with the rules between its rows.
enum PanelSurface {
    static let rule = Color.white.opacity(0.06)
}

/// A form row's switch: the label at the start, the switch at the end (outside a `Form` the system puts them side by
/// side).
struct PanelSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.s) {
            configuration.label
            Spacer(minLength: Spacing.s)
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// A form row's label and value: the value at the trailing edge.
struct PanelLabeledStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.s) {
            configuration.label
            Spacer(minLength: Spacing.s)
            configuration.content
        }
    }
}
