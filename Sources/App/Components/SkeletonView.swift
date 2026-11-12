import SwiftUI

/// Skeleton loading view with shimmer effect
struct SkeletonView: View {
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat
    
    @State private var shimmerOffset: CGFloat = -1.0
    
    init(width: CGFloat? = nil, height: CGFloat = 12, cornerRadius: CGFloat = 4) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }
    
    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    Color.white.opacity(0.3),
                                    Color.clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * 0.4)
                        .offset(x: shimmerOffset * geometry.size.width)
                        .mask(RoundedRectangle(cornerRadius: cornerRadius))
                )
                .onAppear {
                    withAnimation(
                        .linear(duration: 1.5)
                        .repeatForever(autoreverses: false)
                    ) {
                        shimmerOffset = 2.0
                    }
                }
        }
        .frame(width: width, height: height)
    }
}

/// Skeleton loading state for transcript card
struct TranscriptCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingM) {
            // Header
            HStack(spacing: 12) {
                SkeletonView(width: 200, height: 18, cornerRadius: 6)
                Spacer()
                SkeletonView(width: 70, height: 24, cornerRadius: 12)
            }
            
            // Date and language
            SkeletonView(width: 150, height: 12, cornerRadius: 4)
            
            // Transcript preview
            VStack(alignment: .leading, spacing: 6) {
                SkeletonView(height: 14, cornerRadius: 4)
                SkeletonView(width: 300, height: 14, cornerRadius: 4)
                SkeletonView(width: 250, height: 14, cornerRadius: 4)
            }
            
            // Buttons
            HStack(spacing: 8) {
                SkeletonView(width: 100, height: 28, cornerRadius: 6)
                Spacer()
            }
        }
        .premiumCardStyle()
    }
}
