import DubberCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            APIKeysTab().tabItem { Label("API Keys", systemImage: "key") }
            PipelineTab().tabItem { Label("Dubbing", systemImage: "waveform") }
            PrivacyTab().tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .padding(20)
        .frame(width: 560, height: 400)
    }
}

private struct APIKeysTab: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var anthropicDraft = ""
    @State private var openAIDraft = ""

    var body: some View {
        Form {
            Section {
                KeyField(
                    title: "Anthropic (Claude) — required",
                    isSaved: !settings.anthropicKey.isEmpty,
                    draft: $anthropicDraft,
                    save: { settings.saveAnthropicKey(anthropicDraft); anthropicDraft = "" },
                    clear: { settings.saveAnthropicKey("") }
                )
                Link("Get a Claude API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
            }
            Section {
                KeyField(
                    title: "OpenAI — for cloud recognition / expressive voices",
                    isSaved: !settings.openAIKey.isEmpty,
                    draft: $openAIDraft,
                    save: { settings.saveOpenAIKey(openAIDraft); openAIDraft = "" },
                    clear: { settings.saveOpenAIKey("") }
                )
                Link("Get an OpenAI API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.caption)
            }
            if let error = settings.keychainError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            Text("Keys are stored in your macOS Keychain and only sent to their own provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct KeyField: View {
    let title: String
    let isSaved: Bool
    @Binding var draft: String
    let save: () -> Void
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if isSaved {
                    Label("Saved in Keychain", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            HStack {
                SecureField(isSaved ? "Paste a new key to replace it" : "Paste API key", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("Save", action: save).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if isSaved { Button("Remove", role: .destructive, action: clear) }
            }
        }
    }
}

private struct PipelineTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Picker("Speech recognition", selection: $settings.recognition) {
                ForEach(RecognitionProvider.allCases) { Text($0.label).tag($0) }
            }
            Picker("Translation model", selection: $settings.claudeModel) {
                ForEach(ClaudeModelCatalog.options) { option in
                    Text(option.label).tag(option.id)
                }
            }
            Picker("English voices", selection: $settings.voices) {
                ForEach(VoiceProvider.allCases) { Text($0.label).tag($0) }
            }
            Picker("Capture", selection: $settings.captureTarget) {
                ForEach(CaptureTarget.allCases) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading) {
                Slider(value: $settings.maximumLag, in: 3...15, step: 1) {
                    Text("Drop dubs later than")
                }
                Text("\(Int(settings.maximumLag)) s after the original line. Lines that fall further behind are skipped so the dub stays with the picture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Changes to providers apply the next time you press Start.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PrivacyTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("What leaves your Mac").font(.headline)
                Text("• Speech recognition (OpenAI option): each spoken line's audio is sent to OpenAI. With the Apple option, audio never leaves the Mac.")
                Text("• Translation: the Japanese text of each line, plus the last few lines for context, is sent to Anthropic.")
                Text("• Voices (OpenAI option): the English text is sent to OpenAI. Apple voices run on-device.")
                Text("• Voice recognition (who is speaking) always runs on-device.")
                Text("Nothing is recorded or saved to disk. Video is never captured, and Netflix's DRM is not touched — the app only listens to the Mac's audio output, like live captions do.")
                    .padding(.top, 6)
                Text("Dubbing is for your own viewing. Respect Netflix's terms of use and don't redistribute dubbed audio.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
