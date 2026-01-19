//
//  VoiceRecordingView.swift
//  VVTerm
//
//  Voice recording UI with waveform visualization
//

import SwiftUI

struct VoiceRecordingView: View {
    @ObservedObject var audioService: AudioService
    let onSend: (String) -> Void
    let onCancel: () -> Void
    @Binding var isProcessing: Bool

    var body: some View {
        VStack(spacing: 6) {
            if isProcessing {
                processingView
            } else {
                recordingView
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isProcessing)
    }

    private var recordingView: some View {
        VStack(spacing: 6) {
            // Transcription preview
            if !audioService.partialTranscription.isEmpty || !audioService.transcribedText.isEmpty {
                Text(audioService.transcribedText.isEmpty ? audioService.partialTranscription : audioService.transcribedText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Main recording pill
            HStack(spacing: 0) {
                // Cancel Button
                Button {
                    isProcessing = false
                    audioService.cancelRecording()
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)

                // Recording indicator + Timer
                HStack(spacing: 6) {
                    PulsingRecordingIndicator()

                    Text(formatDuration(audioService.recordingDuration))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.trailing, 8)

                // Responsive waveform
                GeometryReader { geometry in
                    AnimatedWaveformView(
                        audioLevel: audioService.audioLevel,
                        isRecording: audioService.isRecording,
                        width: geometry.size.width,
                        height: 24
                    )
                }
                .frame(height: 24)
                .frame(maxWidth: .infinity)

                // Send Button
                Button {
                    guard !isProcessing else { return }
                    isProcessing = true
                    Task {
                        let text = await audioService.stopRecording()
                        let output = text.isEmpty ? audioService.partialTranscription : text
                        await MainActor.run {
                            isProcessing = false
                            onSend(output)
                        }
                    }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
            .frame(height: 40)
        }
    }

    private var processingView: some View {
        HStack(spacing: 12) {
            SiriOrbView(size: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Processing..."))
                    .font(.system(size: 13, weight: .semibold))
                Text(String(localized: "Transcribing audio"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Pulsing Recording Indicator

struct PulsingRecordingIndicator: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 6, height: 6)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear {
                isPulsing = true
            }
    }
}

// MARK: - Animated Waveform View

struct AnimatedWaveformView: View {
    let audioLevel: Float
    let isRecording: Bool
    let width: CGFloat
    let height: CGFloat

    @State private var cachedHeights: [CGFloat] = []
    @State private var targetHeights: [CGFloat] = []

    private var barCount: Int {
        max(10, Int(width / 3))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: !isRecording)) { timeline in
            HStack(alignment: .center, spacing: 1) {
                ForEach(0..<min(barCount, cachedHeights.count), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.red)
                        .frame(width: 2, height: cachedHeights[index])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: height, alignment: .center)
            .onAppear {
                initializeHeights()
            }
            .onChange(of: timeline.date) { _ in
                updateWaveform()
            }
        }
    }

    private func initializeHeights() {
        cachedHeights = Array(repeating: 8, count: barCount)
        targetHeights = Array(repeating: 8, count: barCount)
    }

    private func updateWaveform() {
        guard isRecording else { return }

        // Generate new target heights with randomness for organic look
        for index in 0..<barCount {
            let t = Date().timeIntervalSince1970
            let freq1 = sin(t * 3 + Double(index) * 0.3) * 0.3
            let freq2 = sin(t * 7 + Double(index) * 0.1) * 0.2
            let freq3 = sin(t * 11 + Double(index) * 0.5) * 0.15
            let noise = Double.random(in: -0.15...0.15)

            let combined = (freq1 + freq2 + freq3 + noise + 1.0) / 2.0
            let baseHeight = 6 + (combined * (Double(height) - 6))
            let audioMultiplier = max(0.6, Double(audioLevel))

            targetHeights[index] = max(6, baseHeight * audioMultiplier)
        }

        // Smooth interpolation
        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
            for index in 0..<barCount {
                cachedHeights[index] = targetHeights[index]
            }
        }
    }
}

// MARK: - Siri Orb

private struct SiriOrbView: View {
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.033)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = Angle(degrees: t * 40)
            let pulse = 0.92 + 0.08 * sin(t * 2.2)
            let glow = 0.5 + 0.3 * sin(t * 3.1 + 1.2)

            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                Color.cyan,
                                Color.blue,
                                Color.purple,
                                Color.pink,
                                Color.cyan
                            ]),
                            center: .center,
                            angle: angle
                        )
                    )
                    .frame(width: size, height: size)
                    .scaleEffect(pulse)

                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    .frame(width: size, height: size)

                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.35),
                                Color.clear
                            ]),
                            center: .topLeading,
                            startRadius: 2,
                            endRadius: size
                        )
                    )
                    .frame(width: size, height: size)
                    .blur(radius: 6)
                    .opacity(glow)
            }
            .shadow(color: Color.white.opacity(0.12), radius: 10, x: 0, y: 6)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
