import SwiftUI

/// Bottom-center transport pill for glTF animations. Only ever mounted when
/// `controller.hasAnimations` is true (see `ContentView`), so it never renders
/// a dead control for static models. All playback logic lives on the
/// controller; this view only reflects state and forwards intent.
///
/// The bar is a *progress indicator*, not a scrubber: GLTFKit2's players expose
/// no reliable arbitrary-seek, so drag-to-seek is deliberately omitted (see the
/// evidence in `ViewerController`'s Animation section). Play / pause / select
/// are fully functional.
struct TimelineControlsView: View {
    @ObservedObject var controller: ViewerController

    private let activeGreen = Color(red: 0.72, green: 0.9, blue: 0.28)

    var body: some View {
        HStack(spacing: 12) {
            playPauseButton

            Text(timecode(controller.animationTime))
                .frame(width: 38, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)

            progressBar

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

    // MARK: - Progress

    /// Synchronized playback progress. Non-interactive by design (see type doc).
    private var progressBar: some View {
        GeometryReader { geo in
            let fraction = controller.animationDuration > 0
                ? min(max(controller.animationTime / controller.animationDuration, 0), 1)
                : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule()
                    .fill(activeGreen)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
        .frame(minWidth: 150)
        // The two timecodes beside the bar are hidden; VoiceOver reads them here.
        .accessibilityElement()
        .accessibilityRepresentation {
            ProgressView(value: controller.animationTime, total: max(controller.animationDuration, 0.001)) {
                Text("a11y.timeline")
            }
        }
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
