import DubberCore
import SwiftUI

enum SpeakerPalette {
    static let colors: [Color] = [.gray, .blue, .pink, .green, .orange, .purple, .teal, .red, .yellow, .indigo, .mint, .brown]

    static func color(for speaker: SpeakerID?) -> Color {
        guard let speaker else { return .secondary }
        return colors[speaker.rawValue % colors.count]
    }
}

struct ContentView: View {
    @EnvironmentObject private var controller: DubbingController
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            if let notice = controller.notice {
                Banner(text: notice, systemImage: "info.circle", tint: .blue) { controller.notice = nil }
            }
            if case .failed(let message) = controller.phase {
                Banner(text: message, systemImage: "exclamationmark.triangle.fill", tint: .red, onClose: nil)
            }
            HSplitView {
                SpeakersPanel()
                    .frame(minWidth: 280, idealWidth: 330, maxWidth: 420)
                TranscriptPanel()
                    .frame(minWidth: 420)
            }
            Divider()
            MixControls()
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @EnvironmentObject private var controller: DubbingController

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Netflix Dubber").font(.title2.weight(.semibold))
                Text("Live Japanese → English dubbing").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.phase == .running {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                        ProgressView(value: Double(min(1, controller.inputLevel * 2)))
                            .frame(width: 120)
                    }
                    Text(String(format: "Dub delay ≈ %.1fs", controller.currentLag))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            statusLabel
            Button(action: toggle) {
                Label(controller.phase.isActive ? "Stop" : "Start dubbing",
                      systemImage: controller.phase.isActive ? "stop.fill" : "play.fill")
                    .frame(minWidth: 120)
            }
            .keyboardShortcut("d", modifiers: [.command])
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(controller.phase.isActive ? .red : .accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch controller.phase {
        case .idle:
            Text("Ready").foregroundStyle(.secondary)
        case .preparing(let step):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(step).lineLimit(1).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 320, alignment: .trailing)
        case .running:
            Label("Dubbing", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
        case .failed:
            Label("Stopped", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    private func toggle() {
        controller.phase.isActive ? controller.stop() : controller.start()
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color
    let onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(tint.opacity(0.1))
    }
}

// MARK: - Speakers

private struct SpeakersPanel: View {
    @EnvironmentObject private var controller: DubbingController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Voices").font(.headline)
                Spacer()
                Text("\(controller.speakers.count) detected").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            if controller.speakers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.wave.2").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Each new voice in the show gets its own English voice automatically.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(controller.speakers) { profile in
                    SpeakerRow(profile: profile)
                }
                .listStyle(.inset)
            }
            if !controller.speakerModelName.isEmpty {
                Divider()
                Text(controller.speakerModelName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }
}

private struct SpeakerRow: View {
    @EnvironmentObject private var controller: DubbingController
    let profile: VoiceProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(SpeakerPalette.color(for: profile.speaker)).frame(width: 12, height: 12)
                Text(profile.displayName).font(.body.weight(.medium))
                Text(profile.register.label + " pitch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    controller.preview(profile)
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
                .buttonStyle(.borderless)
                .help("Preview this voice")
                .disabled(controller.phase != .running)
                Toggle("Dub", isOn: Binding(
                    get: { !profile.isMuted },
                    set: { controller.setMuted(!$0, for: profile.speaker) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("Turn dubbing on/off for this voice")
            }
            Menu {
                ForEach(controller.voiceCatalog) { voice in
                    Button(voice.name) { controller.setVoice(voice, for: profile.speaker) }
                }
            } label: {
                Text("Voice: \(profile.voice.name)").lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Transcript

private struct TranscriptPanel: View {
    @EnvironmentObject private var controller: DubbingController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live transcript").font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            if controller.lines.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "captions.bubble").font(.largeTitle).foregroundStyle(.secondary)
                    Text("1. Open Netflix in Safari or Chrome and choose a show with Japanese audio.\n2. Press Start dubbing, then play the episode.\n3. Adjust the original-audio level below to taste.")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(controller.lines) { line in
                        LineRow(line: line, speakerName: speakerName(for: line.speaker)).id(line.id)
                    }
                    .listStyle(.inset)
                    .onChange(of: controller.lines.last?.id) { _, newValue in
                        if let newValue { withAnimation { proxy.scrollTo(newValue, anchor: .bottom) } }
                    }
                }
            }
        }
    }

    private func speakerName(for speaker: SpeakerID?) -> String {
        guard let speaker else { return "…" }
        return controller.speakers.first { $0.speaker == speaker }?.displayName ?? speaker.description
    }
}

private struct LineRow: View {
    let line: DubLine
    let speakerName: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(SpeakerPalette.color(for: line.speaker))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(speakerName).font(.caption.weight(.semibold))
                    Text(line.status.label).font(.caption).foregroundStyle(statusColor)
                    Spacer()
                    if let latency = line.processingLatency {
                        Text(String(format: "%.1fs", latency))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("Time from the end of the Japanese line to the dub being ready")
                    }
                }
                if let japanese = line.japanese {
                    Text(japanese).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let english = line.english {
                    Text(english).font(.body).textSelection(.enabled)
                }
                if let delivery = line.delivery, !delivery.isEmpty {
                    Text(delivery).font(.caption2).italic().foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch line.status {
        case .played: return .green
        case .playing: return .accentColor
        case .failed: return .red
        case .skipped: return .orange
        default: return .secondary
        }
    }
}

// MARK: - Mix controls

private struct MixControls: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            LabeledSlider(
                title: "Original audio while dubbing",
                value: $settings.originalLevelWhileDubbing,
                display: "\(Int(settings.originalLevelWhileDubbing * 100))%"
            )
            LabeledSlider(
                title: "Dub volume",
                value: $settings.dubVolume,
                display: "\(Int(settings.dubVolume * 100))%"
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("New-voice sensitivity").font(.caption)
                Slider(value: $settings.speakerSensitivity, in: 0...1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("Merge").font(.caption2)
                } maximumValueLabel: {
                    Text("Split").font(.caption2)
                }
            }
            Toggle("Lower original as soon as Japanese starts", isOn: $settings.duckDuringOriginalSpeech)
                .font(.caption)
                .toggleStyle(.checkbox)
        }
        .padding(12)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(display).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...1)
        }
        .frame(minWidth: 160)
    }
}
