import Foundation

/// The sheet's two top-level tabs: who the Orb is (the assistant or the form, with the live preview) and how it looks (the
/// editor, at the sheet's whole width). The look is always the person's, in either.
enum NewOrbTab: String, CaseIterable, Identifiable, Sendable {
    case who, look

    var id: String { rawValue }

    var title: String {
        switch self {
        case .who: "Quem ele é"
        case .look: "Aparência"
        }
    }

    var symbol: String {
        switch self {
        case .who: "person.text.rectangle"
        case .look: "paintpalette"
        }
    }
}

/// The two ways the new-Orb sheet creates an Orb: by talking to the assistant, or by filling in the form.
enum OrbCreationMode: String, CaseIterable, Identifiable, Sendable {
    case assistant, form

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assistant: "Criar conversando"
        case .form: "Formulário"
        }
    }

    /// Why the assistant is off.
    static let needsModel = "Conecte um modelo para conversar"

    /// The mode the sheet opens in when the person has not chosen: the assistant when a model is connected, the form when not
    /// (and when the sheet was opened to start from a kept memory or an import, which are the form's).
    static func initial(canConverse: Bool, prefersForm: Bool) -> OrbCreationMode {
        canConverse && !prefersForm ? .assistant : .form
    }
}
