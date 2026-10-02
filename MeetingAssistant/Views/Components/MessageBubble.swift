import SwiftUI

/// Chat-style bubble (iMessage / LINE): speaker text on the left, reply
/// hints on the right. Bubbles hug their content and grow with the window up
/// to `maxWidthFraction` of it.
struct MessageBubble<Accessory: View>: View {
    enum Style: Equatable {
        case incoming
        case draft
        case hint
    }

    let text: String
    let style: Style
    let width: CGFloat
    @ViewBuilder var accessory: () -> Accessory

    private let maxWidthFraction: CGFloat = 0.78

    init(
        text: String,
        style: Style,
        width: CGFloat,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.text = text
        self.style = style
        self.width = width
        self.accessory = accessory
    }

    private var isTrailing: Bool { style == .hint }

    var body: some View {
        HStack(spacing: 0) {
            if isTrailing { Spacer(minLength: width * (1 - maxWidthFraction)) }
            VStack(alignment: .leading, spacing: 0) {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 14, weight: .regular))
                    .lineSpacing(2)
                    .foregroundStyle(foreground)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(background, in: shape)
            if !isTrailing { Spacer(minLength: width * (1 - maxWidthFraction)) }
        }
    }

    // The small corner on the speaker's side reads as the bubble's tail.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: isTrailing ? 18 : 5,
            bottomTrailingRadius: isTrailing ? 5 : 18,
            topTrailingRadius: 18,
            style: .continuous
        )
    }

    private var background: Color {
        switch style {
        case .incoming: return Color(white: 0.22)
        case .draft: return Color(white: 0.16)
        case .hint: return Color(red: 0.04, green: 0.52, blue: 1.0)
        }
    }

    private var foreground: Color {
        switch style {
        case .incoming: return .white.opacity(0.95)
        case .draft: return .white.opacity(0.6)
        case .hint: return .white
        }
    }
}

extension MessageBubble where Accessory == EmptyView {
    init(text: String, style: Style, width: CGFloat) {
        self.init(text: text, style: style, width: width) { EmptyView() }
    }
}

/// Chinese translation shown inside the speaker bubble, under the original.
struct TranslationView: View {
    let text: String
    let isLoading: Bool
    let error: String?

    var body: some View {
        Text(displayText)
            .font(.system(size: 13, weight: .regular))
            .lineSpacing(2)
            .foregroundStyle(error == nil && !text.isEmpty
                ? Color(red: 0.62, green: 0.85, blue: 0.95)
                : Color.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 7)
            // An overlay hairline instead of a Divider: a Divider is flexible
            // and would stretch every bubble to its maximum width.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 0.5)
            }
            .padding(.top, 7)
    }

    private var displayText: String {
        if let error { return error }
        if isLoading && text.isEmpty { return "翻译中…" }
        return text
    }
}

struct CallAlertView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "bell.badge.fill")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.88))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(red: 1.0, green: 0.82, blue: 0.34), in: Capsule(style: .continuous))
            .shadow(color: Color(red: 1.0, green: 0.7, blue: 0.2).opacity(0.4), radius: 12)
            .allowsHitTesting(false)
    }
}

struct NoticeLine: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(isError ? Color(red: 1.0, green: 0.72, blue: 0.54) : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
    }
}

struct StealthOffBanner: View {
    var body: some View {
        Label("VISIBLE TO SCREEN SHARE", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(red: 0.80, green: 0.10, blue: 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
