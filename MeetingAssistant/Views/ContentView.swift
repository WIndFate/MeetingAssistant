import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: MeetingViewModel
    @ObservedObject var settings: SettingsViewModel
    @State private var isSettingsPresented = false

    var body: some View {
        VStack(spacing: 12) {
            if !viewModel.isStealthEnabled {
                StealthOffBanner()
            }

            ToolbarView(
                viewModel: viewModel,
                onOpenSettings: { isSettingsPresented = true },
                onCopy: copyTranscript
            )
            .popover(isPresented: $isSettingsPresented, arrowEdge: .bottom) {
                SettingsView(settings: settings)
            }

            if let error = viewModel.lastError {
                NoticeLine(text: error, isError: true)
            } else if !settings.hasAPIKey {
                NoticeLine(text: "OpenAI API key is not set. Open Settings (gear) to add it.", isError: true)
            }

            MeetingTimelineView(viewModel: viewModel, live: viewModel.live)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Color.black, Color(red: 0.07, green: 0.07, blue: 0.09)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .animation(.easeInOut(duration: 0.18), value: viewModel.isStealthEnabled)
        .preferredColorScheme(.dark)
    }

    private func copyTranscript() {
        let text = viewModel.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct MeetingTimelineView: View {
    @ObservedObject var viewModel: MeetingViewModel
    @ObservedObject var live: LiveTranscript

    // A lone character is usually recognizer noise; do not flash it.
    private var visibleLiveText: String {
        live.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 ? live.text : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Meeting")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.82))
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                // Always laid out, hidden via opacity: inserting it would
                // resize the scroll container and break bottom pinning.
                ProgressView()
                    .controlSize(.small)
                    .opacity(viewModel.isAnyHintStreaming ? 1 : 0)
            }

            GeometryReader { viewport in
                FollowBottomScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if viewModel.turns.isEmpty && visibleLiveText.isEmpty {
                            Text(viewModel.isListening ? "Waiting for speech..." : viewModel.statusText)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(viewModel.turns) { turn in
                            TurnView(turn: turn, width: viewport.size.width)
                        }
                        if !visibleLiveText.isEmpty {
                            MessageBubble(role: "Speaker", text: visibleLiveText, style: .draft, width: viewport.size.width)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
                    .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .top) {
            if let alert = viewModel.callAlertText {
                CallAlertView(text: alert)
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.callAlertText)
    }
}

private struct TurnView: View {
    let turn: MeetingTurn
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageBubble(role: "Speaker", text: turn.text, style: .incoming, width: width) {
                if turn.isTranslating || !turn.translation.isEmpty || turn.translationError != nil {
                    TranslationView(text: turn.translation, isLoading: turn.isTranslating, error: turn.translationError)
                }
            }
            ForEach(Array(turn.archivedHints.enumerated()), id: \.offset) { _, hint in
                MessageBubble(role: "Reply hint", text: hint, style: .hint(isStreaming: false), width: width)
            }
            if turn.isHintStreaming || !turn.hint.isEmpty {
                MessageBubble(
                    role: "Reply hint",
                    text: turn.hint.isEmpty ? "Preparing reply hint..." : turn.hint,
                    style: .hint(isStreaming: turn.isHintStreaming),
                    width: width
                )
            }
        }
        .padding(.bottom, 4)
    }
}
