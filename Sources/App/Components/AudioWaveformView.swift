// Purpose: AudioWaveformView, a recording's waveform with speech highlighting, click to seek and
//          cropping.
// Dependencies: Sources/App/Audio/AudioProcessor.swift (WaveformData)
// Used by: Sources/App/Components/SessionPlaybackStrip.swift (compact, in the recording cards)
// Notes: `compact` (2026-10-05, card redesign) draws a 28 pt strip without its own frame, hover
//        tooltip row or "Crop Audio" link, and colours the played part in the accent colour.
//        `cropMode`, when given, lets the owner start cropping (the card's "…" menu) instead of
//        the inline link; Apply and Cancel then sit next to the selection.

import SwiftUI

/// Audio waveform visualization with speech detection, cropping, and playback controls
struct AudioWaveformView: View {
    let waveformData: AudioProcessor.WaveformData
    let recordingDate: Date
    let onCrop: (TimeInterval, TimeInterval) -> Void
    
    // Playback state (optional - if provided, shows playback progress)
    var currentPlaybackTime: TimeInterval?
    var isPlaying: Bool = false
    var onSeek: ((TimeInterval) -> Void)?
    /// Flat strip for the recording cards: no frame, no tooltip row, no inline crop link.
    var compact = false
    /// When set, cropping is started from outside (the card's menu) and ends through this binding.
    var cropMode: Binding<Bool>? = nil

    @State private var cropStart: Double = 0.0  // 0.0 to 1.0
    @State private var cropEnd: Double = 1.0    // 0.0 to 1.0
    @State private var hoveredPosition: CGFloat?
    @State private var waveformWidth: CGFloat = 0  // Track geometry for tooltips
    @State private var isDraggingStart = false
    @State private var isDraggingEnd = false
    @State private var localCropping = false

    private var showingCropControls: Bool {
        get { cropMode?.wrappedValue ?? localCropping }
        nonmutating set {
            if let cropMode { cropMode.wrappedValue = newValue } else { localCropping = newValue }
        }
    }

    // Compact on purpose (was 120): the card is mostly text, the waveform is for orientation.
    private var waveformHeight: CGFloat { compact ? 28 : 56 }
    private let handleWidth: CGFloat = 12
    
    private var playbackProgress: Double {
        guard let currentTime = currentPlaybackTime else { return 0 }
        return min(1.0, max(0, currentTime / waveformData.duration))
    }
    
    /// Pre-computed per-bar speech flags — avoids O(bars * segments) on every render.
    private var speechFlags: [Bool] {
        let count = waveformData.samples.count
        guard count > 0 else { return [] }
        let duration = waveformData.duration
        return (0..<count).map { index in
            let time = (Double(index) / Double(count)) * duration
            return waveformData.speechSegments.contains { time >= $0.startTime && time <= $0.endTime }
        }
    }

    var body: some View {
        let flags = speechFlags
        let progress = playbackProgress
        let sampleCount = waveformData.samples.count

        VStack(alignment: .leading, spacing: 8) {
            // Waveform visualization
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    if !compact {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    }

                    // Waveform bars
                    HStack(spacing: 1) {
                        ForEach(Array(waveformData.samples.enumerated()), id: \.offset) { index, amplitude in
                            let position = Double(index) / Double(sampleCount)
                            WaveformBar(
                                amplitude: amplitude,
                                isSpeech: index < flags.count ? flags[index] : false,
                                isInCropRegion: position >= cropStart && position <= cropEnd,
                                isPlayed: position <= progress,
                                isPlaying: isPlaying,
                                showingCropControls: showingCropControls,
                                maxHeight: waveformHeight - 8,
                                compact: compact
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                    
                    // Crop overlay (dimmed regions)
                    if showingCropControls {
                        HStack(spacing: 0) {
                            // Left dimmed region
                            Rectangle()
                                .fill(Color.black.opacity(0.5))
                                .frame(width: geometry.size.width * cropStart)
                            
                            // Active region
                            Spacer()
                            
                            // Right dimmed region
                            Rectangle()
                                .fill(Color.black.opacity(0.5))
                                .frame(width: geometry.size.width * (1.0 - cropEnd))
                        }
                    }
                    
                    // Crop handles
                    if showingCropControls {
                        // Start handle
                        CropHandle(isStart: true)
                            .offset(x: geometry.size.width * cropStart - handleWidth / 2)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        isDraggingStart = true
                                        let newPosition = max(0, min(cropEnd - 0.02, value.location.x / geometry.size.width))
                                        cropStart = newPosition
                                    }
                                    .onEnded { _ in
                                        isDraggingStart = false
                                    }
                            )
                        
                        // End handle
                        CropHandle(isStart: false)
                            .offset(x: geometry.size.width * cropEnd - handleWidth / 2)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        isDraggingEnd = true
                                        let newPosition = max(cropStart + 0.02, min(1.0, value.location.x / geometry.size.width))
                                        cropEnd = newPosition
                                    }
                                    .onEnded { _ in
                                        isDraggingEnd = false
                                    }
                            )
                    }
                    
                    // Hover indicator (vertical line)
                    if let hoveredX = hoveredPosition, !showingCropControls {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.5))
                            .frame(width: 2)
                            .offset(x: hoveredX - 1)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if !showingCropControls && !isDraggingStart && !isDraggingEnd {
                            hoveredPosition = location.x
                        }
                    case .ended:
                        hoveredPosition = nil
                    }
                }
                .gesture(
                    TapGesture()
                        .onEnded { _ in
                            // Click to seek - use the hovered position for accuracy
                            if let onSeek = onSeek, !showingCropControls, let hoveredX = hoveredPosition {
                                let position = hoveredX / geometry.size.width
                                let seekTime = position * waveformData.duration
                                onSeek(seekTime)
                            }
                        }
                )
            }
            .frame(height: waveformHeight)
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        waveformWidth = geo.size.width
                    }
                    .onChange(of: geo.size) { _, newSize in
                        waveformWidth = newSize.width
                    }
                }
            )
            
            // Timestamp tooltip
            if !compact, let hoveredX = hoveredPosition, waveformWidth > 0 {
                timestampTooltip(position: hoveredX, containerWidth: waveformWidth)
            }
            
            // Crop info and apply button
            if showingCropControls {
                HStack {
                    Text("Selection: \(formatTime(cropStart * waveformData.duration)) - \(formatTime(cropEnd * waveformData.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()

                    if cropMode != nil {
                        Button("Cancel") { cancelCrop() }
                            .controlSize(.small)
                    }

                    Button("Apply Crop") {
                        let startTime = cropStart * waveformData.duration
                        let endTime = cropEnd * waveformData.duration
                        onCrop(startTime, endTime)
                        showingCropControls = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(cropStart >= cropEnd - 0.01)
                }
                .padding(.top, 4)
            }
            
            // Crop Audio button (placed below waveform); owners with a crop menu entry skip it.
            if cropMode != nil {
                EmptyView()
            } else if !showingCropControls {
                HStack {
                    Spacer()
                    Button("Crop Audio") {
                        withAnimation(.spring(response: 0.3)) {
                            showingCropControls = true
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
                .padding(.top, 4)
            } else {
                HStack {
                    Spacer()
                    Button("Cancel Crop") {
                        withAnimation(.spring(response: 0.3)) {
                            showingCropControls = false
                            // Reset crop positions
                            cropStart = 0.0
                            cropEnd = 1.0
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
                .padding(.top, 4)
            }
        }
        .padding(compact ? 0 : 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(compact ? 0 : 0.5))
        )
        .help(compact && !showingCropControls ? "Click to jump to that point" : "")
    }

    private func cancelCrop() {
        withAnimation(.spring(response: 0.3)) {
            showingCropControls = false
            cropStart = 0.0
            cropEnd = 1.0
        }
    }

    private func isInCropRegion(position: Double) -> Bool {
        position >= cropStart && position <= cropEnd
    }
    
    @ViewBuilder
    private func timestampTooltip(position: CGFloat, containerWidth: CGFloat) -> some View {
        let normalizedPosition = position / containerWidth
        let time = normalizedPosition * waveformData.duration
        let timestamp = recordingDate.addingTimeInterval(time)
        
        VStack(spacing: 2) {
            Text(formatTimestamp(timestamp))
                .font(.caption2)
            Text("Position: \(formatTime(time))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(radius: 4)
        )
        .offset(x: min(max(position - 40, 0), containerWidth - 80), y: 0)
    }
    
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let milliseconds = Int((seconds.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, secs, milliseconds)
    }
}

// MARK: - Subviews

private struct WaveformBar: View {
    let amplitude: Float
    let isSpeech: Bool
    let isInCropRegion: Bool
    let isPlayed: Bool
    let isPlaying: Bool
    let showingCropControls: Bool
    var maxHeight: CGFloat = 48
    var compact = false

    var body: some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 1)
                .fill(barColor)
                .frame(height: boostedHeight)
            Spacer()
        }
    }
    
    /// Apply power curve scaling for better visibility + minimum height
    private var boostedHeight: CGFloat {
        // Apply square root to compress dynamic range (makes quiet parts more visible)
        let boosted = sqrt(CGFloat(amplitude))
        // Scale to the waveform's height (minus a little air), minimum of 2 pt for visibility
        return max(2, boosted * maxHeight)
    }
    
    private var barColor: Color {
        if showingCropControls && !isInCropRegion {
            return Color.gray.opacity(0.3)
        }

        // Compact strip: played part in the accent colour, speech secondary, silence faint.
        if compact {
            if isPlayed { return Color.accentColor }
            return isSpeech ? Color.secondary.opacity(0.7) : Color.secondary.opacity(0.25)
        }
        
        // Playback visualization - played portions show in green
        if isPlayed && isPlaying {
            return Color.green.opacity(1.0)  // Full intensity green during active playback
        } else if isPlayed {
            return Color.green.opacity(0.7)  // More visible green when paused
        }
        
        // Speech detection - high opacity blue for visibility
        if isSpeech {
            return Color.accentColor.opacity(0.9)
        }
        
        // Silence - low opacity gray
        return Color.gray.opacity(0.4)
    }
}

private struct CropHandle: View {
    let isStart: Bool
    @State private var isHovering = false
    
    var body: some View {
        VStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.accentColor : Color.white)
                .frame(width: 12, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                )
                .shadow(radius: 4)
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .cursor(.resizeLeftRight)
    }
}

// MARK: - NSCursor Extension

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onContinuousHover { phase in
            switch phase {
            case .active:
                cursor.push()
            case .ended:
                NSCursor.pop()
            }
        }
    }
}
