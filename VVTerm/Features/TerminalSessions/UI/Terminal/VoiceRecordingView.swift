//
//  VoiceRecordingView.swift
//  VVTerm
//
//  Voice recording UI with waveform visualization
//

import SwiftUI

struct VoiceRecordingView: View {
    @ObservedObject var audioService: AudioService
    let onStop: () -> Void
    let onCancel: () -> Void
    let isProcessing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        voiceChrome {
            VStack(spacing: 10) {
                if isProcessing {
                    processingView
                } else {
                    recordingView
                }
            }
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isProcessing)
    }

    private var recordingView: some View {
        VStack(spacing: 10) {
            if !audioService.partialTranscription.isEmpty || !audioService.transcribedText.isEmpty {
                Text(audioService.transcribedText.isEmpty ? audioService.partialTranscription : audioService.transcribedText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .voiceGlassRect(tint: .accentColor, cornerRadius: 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 10) {
                VoiceActionButton(
                    systemName: "xmark",
                    tint: .secondary,
                    accessibilityLabel: String(localized: "Cancel voice input")
                ) {
                    onCancel()
                }

                HStack(spacing: 10) {
                    PulsingRecordingIndicator()

                    Text(formatDuration(audioService.recordingDuration))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .leading)

                    GeometryReader { geometry in
                        AnimatedWaveformView(
                            audioLevel: audioService.audioLevel,
                            isRecording: audioService.isRecording,
                            width: geometry.size.width,
                            height: 22
                        )
                    }
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)
                }
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .frame(height: 44)
                .frame(maxWidth: .infinity)
                .voiceGlassCapsule(tint: .red)

                VoiceActionButton(
                    systemName: "paperplane.fill",
                    tint: .accentColor,
                    accessibilityLabel: String(localized: "Send voice input")
                ) {
                    guard !isProcessing else { return }
                    onStop()
                }
            }
        }
    }

    private var processingView: some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.accentColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Processing"))
                    .font(.system(size: 13, weight: .semibold))
                Text(String(localized: "Transcribing audio"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            ProcessingMeterView()
                .frame(width: 56, height: 24)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .voiceGlassCapsule(tint: .accentColor)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    @ViewBuilder
    private func voiceChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: 12) {
                content()
            }
        } else {
            fallbackVoiceChrome(content: content)
        }
    }

    private func fallbackVoiceChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let surfaceShape = RoundedRectangle(cornerRadius: 28, style: .continuous)

        return content()
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: surfaceShape)
            .overlay(
                surfaceShape
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 7, height: 7)
            .opacity(isPulsing && !reduceMotion ? 0.45 : 1.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear {
                if !reduceMotion {
                    isPulsing = true
                }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var barCount: Int {
        max(10, Int(width / 3))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: !isRecording || reduceMotion)) { timeline in
            HStack(alignment: .center, spacing: 1) {
                ForEach(0..<min(barCount, cachedHeights.count), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(waveformColor(for: index))
                        .frame(width: 2, height: cachedHeights[index])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: height, alignment: .center)
            .onAppear {
                initializeHeights()
            }
            .onChange(of: barCount) { _ in
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
        guard isRecording, !reduceMotion else { return }

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

    private func waveformColor(for index: Int) -> Color {
        let midpoint = CGFloat(max(barCount - 1, 1)) / 2
        let distance = abs(CGFloat(index) - midpoint) / midpoint
        return Color.red.opacity(0.45 + (1 - distance) * 0.35)
    }
}

private struct ProcessingMeterView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    let wave = reduceMotion ? 0.45 : (sin(phase * 5 + Double(index) * 0.8) + 1) / 2
                    let barHeight = 7 + CGFloat(wave) * 14

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor.opacity(0.35 + wave * 0.35))
                        .frame(width: 4, height: barHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .accessibilityHidden(true)
    }
}

private struct VoiceActionButton: View {
    let systemName: String
    let tint: Color
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .voiceGlassCircle(tint: tint)
        .accessibilityLabel(accessibilityLabel)
    }
}

private extension View {
    @ViewBuilder
    func voiceGlassCircle(tint: Color) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self
                .glassEffect(.regular.tint(tint.opacity(0.18)).interactive(), in: Circle())
        } else {
            fallbackVoiceGlassCircle(tint: tint)
        }
    }

    @ViewBuilder
    func voiceGlassCapsule(tint: Color) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self
                .glassEffect(.regular.tint(tint.opacity(0.12)), in: Capsule())
        } else {
            fallbackVoiceGlassCapsule(tint: tint)
        }
    }

    @ViewBuilder
    func voiceGlassRect(tint: Color, cornerRadius: CGFloat) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self
                .glassEffect(
                    .regular.tint(tint.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            fallbackVoiceGlassRect(tint: tint, cornerRadius: cornerRadius)
        }
    }

    private func fallbackVoiceGlassCircle(tint: Color) -> some View {
        self
            .background(.ultraThinMaterial, in: Circle())
            .overlay(
                Circle()
                    .stroke(tint.opacity(0.22), lineWidth: 1)
            )
    }

    private func fallbackVoiceGlassCapsule(tint: Color) -> some View {
        self
            .background(.thinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            )
    }

    private func fallbackVoiceGlassRect(tint: Color, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return self
            .background(.thinMaterial, in: shape)
            .overlay(
                shape
                    .stroke(tint.opacity(0.16), lineWidth: 1)
            )
    }
}
