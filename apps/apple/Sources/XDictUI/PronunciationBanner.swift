import AppKit
import SwiftUI
import XDictSearch
import XDictSpeech
import XDictTokens

/// **What a sound did, told where the reader is looking** (plan-macos-v1 WI-7; R9, L6): a small notice at the foot of
/// the entry — the dictionary's recording playing, or why it could not and what the system voice did instead. It does
/// not take the keyboard, is read out by VoiceOver as it appears, and goes after a few seconds or when dismissed; each new
/// sound replaces it.
struct PronunciationBanner: View {
    let pronunciation: Pronunciation
    /// The notice the reader dismissed, or that has had its time.
    @State private var dismissed: Int?

    var body: some View {
        if let shown = pronunciation.shown, shown.serial != dismissed, Self.shows(shown.notice, hasTip: shown.tip != nil) {
            let lines = SpeechSentences.lines(shown.notice)
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.sm) {
                Image(systemName: Self.symbol(shown.notice))
                    .foregroundStyle(Self.isProblem(shown.notice) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .font(index == 0 ? .callout : .caption)
                            .foregroundStyle(index == 0 ? .primary : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Once only (the pronunciation decides): a better voice than the compact one that spoke.
                    // The tip and its way on as Settings ▸ Reading & Speech shows them (R1, R4): the sentence leads, the
                    // button trails at regular size.
                    if let tip = shown.tip {
                        ActionRow {
                            Text(SpeechSentences.caveat(tip))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("voice-tip")
                        } actions: {
                            Button("Open Read & Speak Settings") { NSWorkspace.shared.open(Voices.voiceSettingsURL) }
                        }
                    }
                }
                Button {  // placement: glyph
                    dismissed = shown.serial
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Dismiss"))
                .accessibilityLabel(Text("Dismiss"))
            }
            .padding(.horizontal, Tokens.Space.l)
            .padding(.vertical, Tokens.Space.sm)
            // A floating control layer: glass, as wide as its words (UI review M-15).
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Tokens.Window.bannerMax)
            .glassEffect(.regular, in: .rect(cornerRadius: Tokens.Radius.banner))
            .padding(Tokens.Space.m)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pronunciation-notice")
            .transition(.opacity)
            .task(id: shown.serial) {
                let spoken = lines + (shown.tip.map { [SpeechSentences.caveat($0)] } ?? [])
                AccessibilityNotification.Announcement(spoken.map { String(localized: $0) }.joined(separator: "\n")).post()
                guard let after = Self.dismissal(hasTip: shown.tip != nil) else { return }
                try? await Task.sleep(for: after)
                dismissed = shown.serial
            }
        }
    }

    /// Nothing was heard: the reader has something to do (set a language, add a voice). A Speex recording spoken by
    /// the voice is information, not a fault: four of the 25 are wholly Speex, and every click there would warn.
    /// Whether a notice is worth showing: not for a word spoken, or a recording played, as asked (UI review M-15).
    static func shows(_ notice: PronunciationNotice, hasTip: Bool) -> Bool {
        switch notice {
        case .recording, .speech(.spoken): hasTip
        case .speech, .fallback: true
        }
    }

    static func isProblem(_ notice: PronunciationNotice) -> Bool {
        switch notice {
        case .recording, .speech(.spoken), .fallback(_, .spoken): false
        case .speech, .fallback: true
        }
    }

    /// When a notice goes by itself: after a few seconds, or, carrying the one-time voice tip, never (the reader closes
    /// it: it is shown once, and has a button to act on).
    static func dismissal(hasTip: Bool) -> Duration? {
        hasTip ? nil : .seconds(6)
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
