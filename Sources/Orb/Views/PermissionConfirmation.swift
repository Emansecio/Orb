import SwiftUI

// "Sem pedir permissão" removes every safety prompt, so switching to it always goes through a confirmation.

extension Binding where Value == PermissionMode {
    /// Sends a switch *to* bypass to `request` (which shows the confirmation) instead of applying it.
    func confirmingBypass(_ request: @escaping @MainActor @Sendable () -> Void) -> Binding<PermissionMode> {
        Binding(get: { wrappedValue }, set: { mode in
            if mode == .bypass && wrappedValue != .bypass {
                MainActor.assumeIsolated { request() }
            } else {
                wrappedValue = mode
            }
        })
    }
}

extension View {
    func bypassConfirmation(isPresented: Binding<Bool>, apply: @escaping () -> Void) -> some View {
        confirmationDialog("Rodar sem pedir permissão?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Ativar sem pedir permissão", role: .destructive, action: apply)
        } message: {
            Text(PermissionMode.bypass.summary)
        }
    }
}
