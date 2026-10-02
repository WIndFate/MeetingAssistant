import SwiftUI

struct ToolbarView: View {
    @ObservedObject var viewModel: MeetingViewModel
    let onOpenSettings: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(
                systemImage: viewModel.isListening ? "stop.fill" : "play.fill",
                isHighlighted: viewModel.isListening,
                help: viewModel.isListening ? "Stop listening" : "Start listening",
                action: viewModel.toggleListening
            )

            HStack(spacing: 3) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Button {
                        viewModel.setLanguage(language)
                    } label: {
                        Text(language.shortTitle)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(viewModel.language == language ? Color.black : Color.primary.opacity(0.88))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(viewModel.language == language
                                    ? Color(red: 0.55, green: 0.70, blue: 0.62)
                                    : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(.white.opacity(0.035), in: Capsule())
            .help("Meeting language (⌘⇧L)")

            ToolbarIconButton(
                systemImage: "text.bubble",
                isHighlighted: false,
                help: "Reply hint now (⌘⇧Return)",
                action: viewModel.requestHintNow
            )

            ToolbarIconButton(
                systemImage: viewModel.isStealthEnabled ? "eye.slash.fill" : "exclamationmark.triangle.fill",
                isHighlighted: !viewModel.isStealthEnabled,
                help: viewModel.isStealthEnabled
                    ? "Hidden from screen sharing (best effort). Click to show."
                    : "Visible to screen sharing. Click to hide.",
                action: viewModel.toggleStealth
            )

            Spacer(minLength: 0)

            ToolbarIconButton(systemImage: "trash", isHighlighted: false, help: "Clear transcript", action: viewModel.clear)
            ToolbarIconButton(systemImage: "doc.on.doc", isHighlighted: false, help: "Copy transcript", action: onCopy)
            ToolbarIconButton(systemImage: "gearshape", isHighlighted: false, help: "Settings", action: onOpenSettings)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ToolbarIconButton: View {
    let systemImage: String
    let isHighlighted: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHighlighted ? Color(red: 1.0, green: 0.83, blue: 0.83) : .secondary.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(
                    isHighlighted ? Color(red: 0.42, green: 0.16, blue: 0.16).opacity(0.45) : Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
