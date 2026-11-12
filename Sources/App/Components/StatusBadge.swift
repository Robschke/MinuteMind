import SwiftUI

struct StatusBadge: View {
    let status: RecordingSession.Status
    var animated: Bool = false
    var progress: Double? = nil  // 0.0 to 1.0 for transcription progress

    @State private var pulse = 1.0

    var body: some View {
        HStack(spacing: 5) {
            if isLive {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulse)
                    .shadow(color: statusColor.opacity(0.4), radius: 2)
            }

            Text(statusText.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background capsule
                    Capsule()
                        .fill(statusColor.opacity(0.15))
                    
                    // Gradient progress fill (orange to green) - only when we have progress data
                    if let progress = progress, status == .transcribing {
                        let progressWidth = geometry.size.width * progress
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        DesignSystem.Colors.warning.opacity(0.35),
                                        DesignSystem.Colors.success.opacity(0.35)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: progressWidth)
                            .animation(.easeInOut(duration: 0.3), value: progress)
                    }
                    // Show indeterminate progress background for transcribing state without progress data
                    else if status == .transcribing && progress == nil {
                        Capsule()
                            .fill(statusColor.opacity(0.15))
                    }
                    
                    // Border
                    Capsule()
                        .stroke(statusColor.opacity(0.3), lineWidth: 0.5)
                }
            }
        )
        .foregroundStyle(progressColor)
        .shadow(color: statusColor.opacity(0.1), radius: 2, x: 0, y: 1)
        .help(statusTooltip)
        .onAppear {
            if isLive || animated {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulse = 1.4
                }
            }
        }
    }

    private var isLive: Bool {
        status == .recording || status == .liveTranscribing || status == .transcribing
    }

    private var statusText: String {
        switch status {
        case .idle: return "Idle"
        case .recording: return "Recording"
        case .recorded: return "Recorded"
        case .transcribing: return "Processing"
        case .liveTranscribing: return "Live"
        case .completed: return "Ready"
        case .failed: return "Error"
        }
    }
    
    private var statusTooltip: String {
        switch status {
        case .idle: return "Session is idle"
        case .recording: return "Currently recording audio"
        case .recorded: return "Recording complete, ready to transcribe"
        case .transcribing: return "Transcription in progress"
        case .liveTranscribing: return "Live transcription active"
        case .completed: return "Transcription complete"
        case .failed: return "An error occurred"
        }
    }

    private var statusColor: Color {
        switch status {
        case .idle: return DesignSystem.Colors.textSecondary
        case .recording: return DesignSystem.Colors.error
        case .recorded: return DesignSystem.Colors.info
        case .transcribing: return DesignSystem.Colors.warning
        case .liveTranscribing: return DesignSystem.Colors.warning
        case .completed: return DesignSystem.Colors.success
        case .failed: return DesignSystem.Colors.error
        }
    }
    
    // Color transitions from orange to green based on progress
    private var progressColor: Color {
        guard let progress = progress, status == .transcribing else {
            return statusColor
        }
        
        // Interpolate between orange (warning) and green (success)
        let orange = DesignSystem.Colors.warning
        let green = DesignSystem.Colors.success
        
        // Use progress to blend colors
        return Color(
            red: interpolate(from: orange, to: green, progress: progress, component: \.red),
            green: interpolate(from: orange, to: green, progress: progress, component: \.green),
            blue: interpolate(from: orange, to: green, progress: progress, component: \.blue)
        )
    }
    
    // Helper to interpolate color components
    private func interpolate(from: Color, to: Color, progress: Double, component: KeyPath<Color.Resolved, Float>) -> Double {
        let fromResolved = from.resolve(in: EnvironmentValues())
        let toResolved = to.resolve(in: EnvironmentValues())
        let fromValue = fromResolved[keyPath: component]
        let toValue = toResolved[keyPath: component]
        return Double(fromValue + Float(progress) * (toValue - fromValue))
    }
}
