import SwiftUI
import PeekLicenseKit

/// Modal sheet for entering a Peek3D license key. Presented identically from
/// three places — `TrialGateView`'s "Ho già una licenza", `WelcomeView`'s
/// critical-phase "· Sblocca Peek3D" link, and `SettingsView`'s "Cambia
/// licenza" — all of which just do `.sheet(isPresented:) { LicenseEntrySheet() }`.
/// This view is fully self-contained (reads/writes `licenseState` itself via
/// the environment), so none of the three presenters pass anything in or
/// need to react to anything coming back out — the environment object
/// publishing a new `status` is what each presenter's own body already
/// reacts to.
struct LicenseEntrySheet: View {
    @EnvironmentObject private var licenseState: LicenseState
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var errorKind: ErrorKind?
    @State private var didSucceed = false
    @FocusState private var isFieldFocused: Bool

    /// Mirrors `LicenseVerificationResult`'s failure cases one-to-one, minus
    /// `.valid` (the success path never reaches this enum). Four distinct
    /// cases, not one generic message — a user who paid and reads "invalid
    /// license" emails support; one who reads a specific reason often fixes
    /// it themselves.
    private enum ErrorKind {
        case malformed, signatureInvalid, wrongProduct, futureSchema

        /// A different SF Symbol per case so the distinction isn't carried
        /// by color alone.
        var icon: String {
            switch self {
            case .malformed: return "questionmark.square.dashed"
            case .signatureInvalid: return "xmark.seal"
            case .wrongProduct: return "shippingbox"
            case .futureSchema: return "arrow.up.circle"
            }
        }

        var message: String {
            switch self {
            case .malformed:
                return String(
                    localized: "licenseSheet.error.malformed",
                    defaultValue: "This doesn't look like a valid license key. Make sure you copied the entire string from the email.",
                    comment: "License entry error: the pasted text isn't shaped like a license key at all."
                )
            case .signatureInvalid:
                return String(
                    localized: "licenseSheet.error.signatureInvalid",
                    defaultValue: "The key's signature isn't valid. If you typed it in by hand, try pasting it directly from the original email instead.",
                    comment: "License entry error: well-formed key, but its cryptographic signature doesn't check out."
                )
            case .wrongProduct:
                return String(
                    localized: "licenseSheet.error.wrongProduct",
                    defaultValue: "This key belongs to a different product, not Peek3D.",
                    comment: "License entry error: valid key, but issued for another app."
                )
            case .futureSchema:
                return String(
                    localized: "licenseSheet.error.futureSchema",
                    defaultValue: "This key requires a newer version of Peek3D. Update the app and try again.",
                    comment: "License entry error: valid key from a newer license schema this build doesn't understand yet."
                )
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("licenseSheet.title", comment: "Title of the license-entry sheet")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text("licenseSheet.instruction", comment: "Instruction under the license-entry sheet's title")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }

            // A `TextEditor`, not a single-line `TextField`: real license
            // keys (see PeekLicenseKit's own test vectors) run to several
            // hundred characters, and a multi-line field lets the user
            // actually see what they pasted instead of scrolling a single
            // line sideways to check it. Newlines from an email's own line
            // wrapping are stripped in `sanitizedInput` before verification —
            // that's what "tollerante su spazi e a capo incollati" means
            // here, not that Enter submits the form (it inserts a newline,
            // which is then stripped, same as any other pasted one).
            TextEditor(text: $inputText)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 96)
                .padding(8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(errorKind == nil ? Color.white.opacity(0.15) : Color.red.opacity(0.6))
                )
                .focused($isFieldFocused)
                .disabled(didSucceed)
                .onChange(of: inputText) { _ in errorKind = nil }

            if let errorKind {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: errorKind.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.peekAmber)
                    Text(errorKind.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            if didSucceed {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("licenseSheet.success", comment: "Confirmation shown after a license key verifies successfully")
                        .foregroundStyle(.white)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.green.opacity(0.4)))
            }

            HStack(spacing: 10) {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("licenseSheet.cancel", comment: "Cancel button on the license-entry sheet")
                }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                    .pointerCursor()
                Button {
                    verify()
                } label: {
                    Text("licenseSheet.activate", comment: "Submit button on the license-entry sheet")
                }
                    .buttonStyle(PeekFilledButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(sanitizedInput.isEmpty || didSucceed)
                    .pointerCursor()
            }
        }
        .padding(28)
        .frame(width: 440)
        .background(Color(white: 0.1))
        .preferredColorScheme(.dark)
        .onAppear { isFieldFocused = true }
        .onExitCommand { dismiss() }
    }

    private var sanitizedInput: String {
        inputText
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    private func verify() {
        let cleaned = sanitizedInput
        guard !cleaned.isEmpty else { return }
        switch LicenseVerifier.verify(cleaned) {
        case .valid:
            errorKind = nil
            licenseState.applyLicenseKeyText(cleaned)
            didSucceed = true
            // Closes itself — the parent screen (TrialGateView/WelcomeView/
            // SettingsView) reacts to the now-`.licensed` `licenseState` on
            // its own via its own `@EnvironmentObject`, e.g. TrialGateView
            // swapping straight to `ContentView(url:)` once this sheet is
            // gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
        case .malformed:
            errorKind = .malformed
        case .signatureInvalid:
            errorKind = .signatureInvalid
        case .validWrongProduct:
            errorKind = .wrongProduct
        case .validFutureSchema:
            errorKind = .futureSchema
        }
    }
}
