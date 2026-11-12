import SwiftUI

struct FilterChip: View {
    let label: String
    var color: Color = DesignSystem.Colors.accent
    let onRemove: () -> Void
    
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1.0 : 0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            ZStack {
                Capsule()
                    .fill(color.opacity(0.15))
                
                if isHovering {
                    Capsule()
                        .fill(color.opacity(0.05))
                }
            }
        )
        .foregroundStyle(color)
        .overlay(
            Capsule()
                .stroke(color.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: color.opacity(0.1), radius: 2, x: 0, y: 1)
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .animation(DesignSystem.Animation.quick, value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
