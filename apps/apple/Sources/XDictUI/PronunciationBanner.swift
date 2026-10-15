import SwiftUI
import XDictSearch

/// **What a sound did, told where the reader is looking** (plan-macos-v1 WI-7; R9, L6): a small notice at the foot of
/// the entry — the dictionary's recording playing, or why it could not and what the system voice did instead. It does
/// not take the keyboard, is read out by VoiceOver as it appears, and goes after a few seconds or when dismissed; each new
/// sound replaces it.
struct PronunciationBanner: View {
    let pronunciation: Pronunciation
    /// The notice the reader dismissed, or that has had its time.
    @State private var dismissed: Int?

    var body: some View {
        if let shown = pronunciation.shown, shown.serial != dismissed {
            let lines = SpeechSentences.lines(shown.notice)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.symbol(shown.notice))
                    .foregroundStyle(Self.isProblem(shown.notice) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .font(index == 0 ? .callout : .caption)
                            .foregroundStyle(index == 0 ? .primary : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button {
                    dismissed = shown.serial
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Dismiss"))
                .accessibilityLabel(Text("Dismiss"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 2, y: 1)
            .padding(12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pronunciation-notice")
            .transition(.opacity)
            .task(id: shown.serial) {
                AccessibilityNotification.Announcement(lines.map { String(localized: $0) }.joined(separator: "\n")).post()
                try? await Task.sleep(for: .seconds(6))
                dismissed = shown.serial
            }
        }
    }

    /// Nothing was heard: the reader has something to do (set a language, add a voice). A Speex recording spoken by
    /// the voice is information, not a fault: four of the 25 are wholly Speex, and every click there would warn.
    static func isProblem(_ notice: PronunciationNotice) -> Bool {
        switch notice {
        case .recording, .speech(.spoken), .fallback(_, .spoken): false
        case .speech, .fallback: true
        }
    }

    static func symbol(_ notice: PronunciationNotice) -> String {
        switch notice {
        case .recording: "speaker.wave.2.fill"
        case .speech(.spoken): "waveform"
        case .fallback(_, .spoken): "info.circle"
        case .speech, .fallback: "exclamationmark.triangle.fill"
        }
    }
}
