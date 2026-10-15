import SwiftUI

/// Bottom-center transport pill for glTF animations. Only ever mounted when
/// `controller.hasAnimations` is true (see `ContentView`), so it never renders
/// a dead control for static models. All playback logic lives on the
/// controller; this view only reflects state and forwards intent.
///
/// The bar is a *scrubber*: drag (or click) anywhere on it to jump to that
/// instant; the model follows live. Keyboard: focus the bar and use the arrow
/// keys; VoiceOver: it is an adjustable element (swipe up/down) that announces
/// the position in seconds. How a seek is realised is documented in
/// `ViewerController`'s Animation section.
struct TimelineControlsView: View {
    @ObservedObject var controller: ViewerController
    /// Observed separately so the 60 Hz ticks re-render only this view.
    @ObservedObject private var playhead: Playhead

    init(controller: ViewerController) {
        self.controller = controller
        self.playhead = controller.playhead
    }

    private let activeGreen = Color(red: 0.72, green: 0.9, blue: 0.28)
    /// True while the pointer is dragging the bar (mirrors `controller.isScrubbing`,
    /// kept local because the controller does not publish it).
    @State private var isDragging = false
    /// Keyboard focus on the bar. The system focus ring is a hard rectangle that
    /// fights the HUD pill (macOS 14+ lets us turn it off), so focus is drawn on
    /// the thumb instead.
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            playPauseButton

            Text(timecode(playhead.time))
                .frame(width: 38, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)

            scrubber

            Text(durationLabel)
                .frame(width: 44, alignment: .leading)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityHidden(true)

            if controller.animations.count > 1 {
                animationMenu
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .hudPanel(cornerRadius: 14)
        .arrowCursor()
    }

    // MARK: - Play / pause

    private var playPauseButton: some View {
        Button {
            controller.togglePlayback()
        } label: {
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .foregroundStyle(controller.isPlaying ? .black : .white.opacity(0.9))
                .background(
                    controller.isPlaying ? activeGreen : .white.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(controller.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(Text(controller.isPlaying ? "Pause" : "Play"))
    }

    // MARK: - Scrubber

    /// Fraction of the clip the playhead has covered, 0...1.
    private var fraction: Double {
        controller.animationDuration > 0
            ? min(max(playhead.time / controller.animationDuration, 0), 1)
            : 0
    }

    /// Keyboard / VoiceOver step: 5% of the clip, never below a frame at 30 fps.
    private var keyStep: TimeInterval { max(controller.animationDuration / 20, 1.0 / 30.0) }

    private var scrubber: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14)).frame(height: 4)
                Capsule().fill(activeGreen).frame(width: width * fraction, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: isDragging ? 13 : 9, height: isDragging ? 13 : 9)
                    .shadow(color: .black.opacity(0.35), radius: 1.5)
                    .overlay {
                        if isFocused { Circle().stroke(activeGreen, lineWidth: 2).padding(-3) }
                    }
                    // Last: `offset` moves the drawing only, so anything chained
                    // after it would sit at the un-offset layout position.
                    .offset(x: width * fraction - (isDragging ? 6.5 : 4.5))
            }
            .frame(maxHeight: .infinity)
            // The whole 18pt-tall strip is the hit target, not just the 4pt line.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            isFocused = true // so ← → work right after a click
                            controller.setScrubbing(true)
                        }
                        controller.seek(to: controller.animationDuration * min(max(value.location.x / width, 0), 1))
                    }
                    .onEnded { value in
                        controller.seek(to: controller.animationDuration * min(max(value.location.x / width, 0), 1))
                        controller.setScrubbing(false)
                        isDragging = false
                    }
            )
        }
        .frame(height: 18)
        .frame(minWidth: 150)
        .pointerCursor()
        // Keyboard: focus the bar (Full Keyboard Access / Tab), then ← → step.
        .focusable()
        .focused($isFocused)
        .hideSystemFocusRing()
        .onMoveCommand { direction in
            switch direction {
            case .left: controller.seek(to: playhead.time - keyStep)
            case .right: controller.seek(to: playhead.time + keyStep)
            default: break
            }
        }
        // VoiceOver: the two timecodes beside the bar are hidden; this single
        // real slider (swipe up/down to adjust) carries the label and the
        // position in words. The drag and arrow-key handling above stay on the
        // visual bar; only the accessibility tree is swapped.
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { playhead.time }, set: { controller.seek(to: $0) }),
                in: 0...max(controller.animationDuration, 0.001),
                step: keyStep
            ) {
                Text("a11y.timeline")
            }
            .accessibilityValue(Text(accessibilityPosition))
        }
    }

    /// "1.2 seconds of 3.4 seconds", localized, for VoiceOver.
    private var accessibilityPosition: String {
        func seconds(_ value: TimeInterval) -> String {
            Measurement(value: value, unit: UnitDuration.seconds)
                .formatted(.measurement(width: .wide, numberFormatStyle: .number.precision(.fractionLength(1))))
        }
        return String(localized: "a11y.timeline.position \(seconds(playhead.time)) \(seconds(controller.animationDuration))")
    }

    // MARK: - Animation selector

    private var animationMenu: some View {
        Menu {
            ForEach(controller.animations.indices, id: \.self) { index in
                Button {
                    controller.selectAnimation(index: index)
                } label: {
                    if index == controller.currentAnimationIndex {
                        Label(controller.animationName(at: index), systemImage: "checkmark")
                    } else {
                        Text(controller.animationName(at: index))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(controller.animationName(at: controller.currentAnimationIndex))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.85))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: 120)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
        .help("Choose animation")
        .accessibilityLabel(Text("Choose animation"))
        .accessibilityValue(Text(controller.animationName(at: controller.currentAnimationIndex)))
    }

    // MARK: - Formatting

    /// Adaptive readout: `m:ss` for clips a minute or longer, otherwise
    /// one-decimal seconds — most glTF sample clips (e.g. Fox) run under 3s,
    /// where `m:ss` would read a useless "0:00".
    private func timecode(_ t: TimeInterval) -> String {
        let value = max(t, 0)
        if controller.animationDuration >= 60 {
            let whole = Int(value.rounded())
            return String(format: "%d:%02d", whole / 60, whole % 60)
        }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    private var durationLabel: String {
        guard controller.animationDuration < 60 else { return timecode(controller.animationDuration) }
        // Localized seconds unit ("3,4 s", "3.4秒") instead of a hard-coded "s".
        return Measurement(value: controller.animationDuration, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(1))))
    }
}

private extension View {
    /// The system focus ring on a custom control (macOS 14+; earlier systems
    /// keep it, which is the correct fallback for a keyboard focus indicator).
    @ViewBuilder func hideSystemFocusRing() -> some View {
        if #available(macOS 14.0, *) { focusEffectDisabled() } else { self }
    }
}
