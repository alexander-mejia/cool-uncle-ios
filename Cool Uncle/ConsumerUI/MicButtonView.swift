import SwiftUI

/// Large microphone button with countdown timer ring and glow
/// Visual states:
/// - Idle (blue): No glow, no ring
/// - PTT recording (green): Slight scale, no timer ring
/// - Wake recording (red): Glow fades, timer ring counts down
struct MicButtonView: View {
    @ObservedObject var speechService: SpeechService
    @ObservedObject var uiStateService: UIStateService

    var onMicTap: () -> Void
    var onMicPress: (Bool) -> Void

    var body: some View {
        ZStack {
            // Outer glow (fades as timer counts down)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            buttonColor.opacity(glowIntensity * 0.5),
                            buttonColor.opacity(glowIntensity * 0.2),
                            .clear
                        ],
                        center: .center,
                        startRadius: 60,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)
                .animation(.easeOut(duration: 0.3), value: glowIntensity)

            // Countdown timer ring (strokes around the button)
            // Only visible during wake word recording
            Circle()
                .trim(from: 0, to: uiStateService.recordingProgress)
                .stroke(
                    buttonColor.opacity(0.8),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .frame(width: 140, height: 140)
                .rotationEffect(.degrees(-90))  // Start at top (12 o'clock)
                .animation(.linear(duration: 0.1), value: uiStateService.recordingProgress)

            // Main mic button
            Button(action: onMicTap) {
                ZStack {
                    Circle()
                        .fill(buttonColor)
                        .frame(width: 120, height: 120)
                        .scaleEffect(speechService.isRecording ? 1.05 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: speechService.isRecording)

                    // Show mic or stop icon
                    // Note: Removed spinner - button now shows RED STOP during processingRequest state
                    // This allows user to cancel AI processing by tapping the button
                    Image(systemName: buttonIcon)
                        .font(.system(size: 40, weight: .medium))
                        .foregroundColor(.white)
                }
            }
            // IMPORTANT: Do NOT disable button during processing - user needs to be able to tap STOP to cancel
            .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
                // Long press end (not used, but required by API)
            } onPressingChanged: { isPressing in
                // This fires on press down AND release
                onMicPress(isPressing)
            }
        }
        .frame(width: 200, height: 200)
    }

    // MARK: - Visual State Helpers

    private var buttonColor: Color {
        switch speechService.recordingState {
        case .idle: return .blue
        case .recordingPTT: return .green
        case .recordingWake: return .red
        case .processingRequest: return .red  // RED STOP button during AI processing
        }
    }

    private var buttonIcon: String {
        switch speechService.recordingState {
        case .idle, .recordingPTT:
            return "mic.fill"
        case .recordingWake, .processingRequest:
            // RED STOP icon during wake word recording AND AI processing
            // User can tap to cancel in either state
            return "stop.fill"
        }
    }

    private var glowIntensity: Double {
        // Bright when full time remaining, fades to 0 as timer runs out
        // Only shows during wake word recording (when timer is active)
        return uiStateService.recordingProgress
    }
}
