import SwiftUI
import AppKit
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
    // A plain `@State` bool, not `@FocusState`, because focus is driven by
    // `TabTraversingTextEditor`'s own NSTextViewDelegate hooks (see below)
    // rather than SwiftUI's native focus binding — the custom
    // NSViewRepresentable wraps an NSScrollView, and `.focused()` targets
    // the represented view itself, not the NSTextView nested inside it.
    @State private var isFieldFocused = false

    /// Mirrors `LicenseVerificationResult`'s failure cases one-to-one, minus
    /// `.valid` (the success path never reaches this enum). Four distinct
    /// cases, not one generic message — a user who paid and reads "invalid
    /// license" emails support; one who reads a specific reason often fixes
    /// it themselves.
    // `Equatable` (compiler-synthesized, no associated values to compare)
    // is what lets `.onChange(of: errorKind)` below tell "a new error just
    // appeared" apart from "the same error is still showing" — needed to
    // post exactly one VoiceOver announcement per distinct failure, not one
    // per unrelated view update.
    private enum ErrorKind: Equatable {
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

            // A custom NSTextView-backed editor, not SwiftUI's `TextEditor`:
            // real license keys (see PeekLicenseKit's own test vectors) run
            // to several hundred characters, and a multi-line field lets the
            // user actually see what they pasted instead of scrolling a
            // single line sideways to check it. Newlines from an email's own
            // line wrapping are stripped in `sanitizedInput` before
            // verification — that's what "tollerante su spazi e a capo
            // incollati" means here, not that Enter submits the form (it
            // inserts a newline, which is then stripped, same as any other
            // pasted one).
            //
            // `TabTraversingTextEditor` instead of plain `TextEditor`: a bare
            // SwiftUI `TextEditor` is backed by a non-field `NSTextView`,
            // which swallows Tab and Shift-Tab as literal tab-character
            // insertion instead of moving focus — a dead end for anyone
            // navigating this sheet by keyboard alone, sighted or not, since
            // there is no way out of the field except a mouse click (Esc
            // still works via `.onExitCommand` below, but that closes the
            // whole sheet, not just the field). See the type's own doc
            // comment at the bottom of this file for the fix.
            TabTraversingTextEditor(
                text: $inputText,
                isFocused: $isFieldFocused,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular)
            )
                .frame(height: 96)
                .padding(8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(errorKind == nil ? Color.white.opacity(0.15) : Color.peekError.opacity(0.6))
                )
                .disabled(didSucceed)
                .onChange(of: inputText) { _ in errorKind = nil }

            if let errorKind {
                // One combined element, not icon+text as two separate stops:
                // the icon is purely a visual distinguisher between the four
                // error kinds (point 4 of this feature's brief — never rely
                // on color alone), and `errorKind.message` alone already
                // carries the full, distinct meaning VoiceOver needs to
                // speak. `postAccessibilityAnnouncement(_:)` below is
                // what actually gets this spoken without requiring the user
                // to have this row focused already — a screen-reader user
                // who just pressed "Attiva" and moved on gets the specific
                // reason read to them, not silence (brief point 1).
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: errorKind.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.peekError)
                        .accessibilityHidden(true)
                    Text(errorKind.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.peekError.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.peekError.opacity(0.4)))
                .accessibilityElement(children: .combine)
            }

            if didSucceed {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("licenseSheet.success", comment: "Confirmation shown after a license key verifies successfully")
                        .foregroundStyle(.white)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.green.opacity(0.4)))
                .accessibilityElement(children: .combine)
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
        // Each of the four error messages is deliberately distinct text
        // (see `ErrorKind.message`'s own doc comment) — that work is wasted
        // if it only ever appears visually. Posting an explicit announcement
        // here, rather than relying on the banner's mere presence in the
        // view tree, is what makes VoiceOver actually speak it regardless of
        // where the accessibility cursor currently is.
        .onChange(of: errorKind) { newValue in
            guard let newValue else { return }
            postAccessibilityAnnouncement(newValue.message)
        }
        .onChange(of: didSucceed) { newValue in
            guard newValue else { return }
            // Reuses `licenseSheet.success`'s own resolved text rather than
            // a second, hand-typed copy — one key, one string, so the
            // announcement can never drift from what's shown on screen.
            postAccessibilityAnnouncement(
                String(localized: "licenseSheet.success", defaultValue: "License activated. Enjoy!", comment: "Confirmation shown after a license key verifies successfully")
            )
        }
    }

    /// Makes VoiceOver actually speak `message` regardless of where the
    /// accessibility cursor currently is, instead of relying on the
    /// error/success banner's mere presence in the view tree.
    ///
    /// Deliberately `NSAccessibility.post(element:notification:userInfo:)`
    /// with `.announcementRequested`, not SwiftUI's
    /// `AccessibilityNotification.Announcement` — the latter is macOS 14+
    /// only, and this project's deployment target is macOS 13 (see
    /// CLAUDE.md). `NSAccessibility.post` does the same job and has existed
    /// since long before either OS version, so it's the one implementation
    /// that actually works on every system this app ships to, rather than a
    /// macOS-14-only path plus a silent no-op fallback on 13.
    private func postAccessibilityAnnouncement(_ message: String) {
        guard let target = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: target,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
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

/// A plain multi-line text editor whose Tab and Shift-Tab keys traverse to
/// the next/previous control instead of inserting a literal tab character.
///
/// SwiftUI's `TextEditor` is backed by a standalone `NSTextView` with
/// `isFieldEditor == false`; AppKit only special-cases Tab-as-focus-move for
/// field editors (the text view an `NSTextField` borrows while active), so a
/// bare `NSTextView` — and therefore `TextEditor` — inserts `\t` on Tab and
/// does nothing useful on Shift-Tab. In a modal sheet whose only other
/// controls are Cancel/Attiva, that traps any keyboard-only user (sighted
/// and using Tab directly, or blind and using VoiceOver's own field
/// navigation, which still defers to the key-view loop for a plain
/// `NSTextView`) inside the field with no way out except a mouse click —
/// exactly the "vicolo cieco" this feature's brief calls out. Overriding
/// `insertTab(_:)`/`insertBacktab(_:)` to call `selectNextKeyView`/
/// `selectPreviousKeyView` is the same behavior `isFieldEditor = true` gets
/// for free, opted into explicitly since this editor is intentionally
/// multi-line and stays a standalone view.
private struct TabTraversingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var font: NSFont

    final class TraversingTextView: NSTextView {
        override func insertTab(_ sender: Any?) {
            window?.selectNextKeyView(self)
        }
        override func insertBacktab(_ sender: Any?) {
            window?.selectPreviousKeyView(self)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = TraversingTextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        // The default AX label for a bare NSTextView is generic ("text
        // view") or empty — this is what VoiceOver actually announces on
        // first landing on the field, standing in for the visible
        // title+instruction pair above it that a screen-reader user hasn't
        // necessarily just read.
        textView.setAccessibilityLabel(
            String(localized: "licenseSheet.fieldAccessibilityLabel", defaultValue: "License key", comment: "VoiceOver label for the license-entry sheet's multi-line paste field.")
        )
        context.coordinator.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        // Mirrors what `.disabled(didSucceed)` did for the old `TextEditor`
        // — `.disabled()` sets the `isEnabled` environment value, which a
        // plain NSViewRepresentable doesn't apply to its wrapped AppKit view
        // automatically, unlike a native SwiftUI control.
        textView.isEditable = context.environment.isEnabled
        textView.isSelectable = context.environment.isEnabled
        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TabTraversingTextEditor
        weak var textView: NSTextView?
        init(_ parent: TabTraversingTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }
        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }
    }
}
