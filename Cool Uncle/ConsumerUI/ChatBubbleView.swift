import SwiftUI

// MARK: - Custom Bubble Shape with Tail

/// Custom bubble shape with angular tail (inspired by Human Interact logo)
/// Sharp square corners with crisp diagonal tail extending from bottom corner
struct BubbleTailShape: Shape {
    var isUserBubble: Bool  // true = tail on right, false = tail on left

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let cornerRadius: CGFloat = 4  // Small radius for crisp square look
        let tailWidth: CGFloat = 12  // Width of tail base
        let tailHeight: CGFloat = 12  // How far tail extends downward

        // Reserve space at bottom for tail
        let bubbleBottom = rect.maxY - tailHeight

        if isUserBubble {
            // User bubble - tail extends from bottom-right corner
            // Start from top-left
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))

            // Top-left corner (small radius)
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )

            // Top edge
            path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))

            // Top-right corner
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + cornerRadius),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )

            // Right edge down to bubble bottom
            path.addLine(to: CGPoint(x: rect.maxX, y: bubbleBottom - cornerRadius))

            // Bottom-right corner
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - cornerRadius, y: bubbleBottom),
                control: CGPoint(x: rect.maxX, y: bubbleBottom)
            )

            // Bottom edge to tail start
            path.addLine(to: CGPoint(x: rect.maxX - tailWidth, y: bubbleBottom))

            // ANGULAR TAIL - extends downward with diagonal cut
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))  // Point extending down
            path.addLine(to: CGPoint(x: rect.maxX, y: bubbleBottom))  // Back to corner

            // Continue bottom edge to left
            path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: bubbleBottom))

            // Bottom-left corner
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: bubbleBottom - cornerRadius),
                control: CGPoint(x: rect.minX, y: bubbleBottom)
            )

            // Left edge back to start
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))

        } else {
            // Assistant bubble - tail extends from bottom-left corner
            // Start from top-right
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY + cornerRadius))

            // Top-right corner
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )

            // Top edge
            path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))

            // Top-left corner
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )

            // Left edge down to bubble bottom
            path.addLine(to: CGPoint(x: rect.minX, y: bubbleBottom - cornerRadius))

            // Bottom-left corner
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + cornerRadius, y: bubbleBottom),
                control: CGPoint(x: rect.minX, y: bubbleBottom)
            )

            // Bottom edge to tail start
            path.addLine(to: CGPoint(x: rect.minX + tailWidth, y: bubbleBottom))

            // ANGULAR TAIL - extends downward with diagonal cut
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))  // Point extending down
            path.addLine(to: CGPoint(x: rect.minX, y: bubbleBottom))  // Back to corner

            // Continue bottom edge to right
            path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: bubbleBottom))

            // Bottom-right corner
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: bubbleBottom - cornerRadius),
                control: CGPoint(x: rect.maxX, y: bubbleBottom)
            )

            // Right edge back to start
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cornerRadius))
        }

        path.closeSubpath()
        return path
    }
}

// MARK: - Persistent Chat Bubble

/// Renders a single chat bubble
/// Supports 3 roles: user (blue, right), assistant (grey, left), action (green, center)
struct ChatBubbleView: View {
    let bubble: ChatBubble
    var onRetry: ((RetryContext) -> Void)? = nil

    // State for action bubble fade animation
    @State private var actionBubbleColor: Color = .green.opacity(0.7)
    @State private var actionBubbleTextColor: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 0) {
                if bubble.role == .user {
                    Spacer(minLength: 60)  // Space on left for user bubbles
                }

                if bubble.role == .action {
                    // Centered action bubble (e.g., "Launched MegaMan 3")
                    // Starts green with white text, fades to grey with dark text for light mode readability
                    Text(bubble.content)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(actionBubbleTextColor)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(actionBubbleColor)
                        .cornerRadius(12)
                        .frame(maxWidth: .infinity)
                        .onAppear {
                            // Wait 2 seconds, then fade to grey background with darker text
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                withAnimation(.easeInOut(duration: 1.0)) {
                                    actionBubbleColor = Color(.systemGray4)  // Darker grey for better contrast
                                    actionBubbleTextColor = Color(.label)  // Adapts to light/dark mode
                                }
                            }
                        }
                } else {
                    // User/Assistant bubble with custom tail shape
                    Text(bubble.content)
                        .font(.body)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .padding(.bottom, 12)  // Extra bottom padding for tail space (matches tailHeight)
                        .foregroundColor(textColor)
                        .strikethrough(bubble.isCancelled, color: .secondary)  // Strikethrough for cancelled
                        .frame(maxWidth: 280)  // Max width constraint (about 75% of iPhone screen)
                        .background(
                            BubbleTailShape(isUserBubble: bubble.role == .user)
                                .fill(bubbleColor)
                        )
                        .opacity(bubble.isCancelled ? 0.6 : 1.0)  // Muted appearance for cancelled
                        .contextMenu {
                            Button(action: {
                                UIPasteboard.general.string = bubble.content
                            }) {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                }

                if bubble.role == .assistant {
                    Spacer(minLength: 60)  // Space on right for assistant bubbles
                }
            }

            // Network error retry button
            if bubble.isNetworkError, let retryContext = bubble.retryContext, let onRetry = onRetry {
                Button(action: {
                    onRetry(retryContext)
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 16))
                        Text("Tap to retry")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.orange)
                    .cornerRadius(8)
                }
                .padding(.leading, 16)  // Align with bubble
            }
        }
        .padding(.horizontal, 16)  // Increased edge padding
        .padding(.vertical, 2)
    }

    private var bubbleColor: Color {
        if bubble.isCancelled {
            // Muted colors for cancelled bubbles
            switch bubble.role {
            case .user: return .blue.opacity(0.4)  // Muted blue for cancelled user messages
            case .assistant: return Color(.systemGray6)
            case .action: return Color(.systemGray6)
            }
        }

        switch bubble.role {
        case .user: return .blue
        case .assistant: return Color(.systemGray5)
        case .action: return .green.opacity(0.7)
        }
    }

    private var textColor: Color {
        if bubble.isCancelled {
            // Muted text for cancelled bubbles
            return .secondary
        }

        return bubble.role == .user ? .white : .primary
    }
}

// MARK: - Transient Status (iMessage-style pulsing)

/// Renders transient status message with pulsing animation
/// This is the "User is typing..." equivalent for AI processing
/// Does NOT persist in chat history
struct TransientStatusView: View {
    let status: String?
    @State private var animationPhase: CGFloat = 0

    var body: some View {
        if let status = status {
            HStack(spacing: 8) {
                // Pulsing ellipsis animation (3 dots)
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(.secondary)
                            .frame(width: 6, height: 6)
                            .opacity(pulseOpacity(for: index))
                    }
                }

                Text(status)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .cornerRadius(16)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .animation(.easeInOut(duration: 0.3), value: status)
            .onAppear {
                // Start pulsing animation
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    animationPhase = 1.5
                }
            }
        }
    }

    /// Calculate opacity for pulsing dot animation
    /// Each dot pulses with a 0.3s phase offset
    private func pulseOpacity(for index: Int) -> Double {
        let phase = (animationPhase + Double(index) * 0.3).truncatingRemainder(dividingBy: 1.5)
        return 0.3 + 0.7 * abs(sin(phase * .pi))
    }
}
