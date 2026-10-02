import SwiftUI

/// Speaker paragraphs sit on the left, reply hints on the right.
struct MessageBubble<Accessory: View>: View {
    enum Style: Equatable {
        case incoming
        case draft
        case hint(isStreaming: Bool)
    }

    let role: String
    let text: String
    let style: Style
    let width: CGFloat
    @ViewBuilder var accessory: () -> Accessory

    init(
        role: String,
        text: String,
        style: Style,
        width: CGFloat,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.role = role
        self.text = text
        self.style = style
        self.width = width
        self.accessory = accessory
    }

    private var isTrailing: Bool {
        if case .hint = style { return true }
        return false
    }

    private var sideSpacer: CGFloat { width >= 500 ? 64 : 0 }
    private var maxBubbleWidth: CGFloat { max(180, min(560, width - sideSpacer)) }

    var body: some View {
        HStack {
            if isTrailing { Spacer(minLength: sideSpacer) }
            VStack(alignment: isTrailing ? .trailing : .leading, spacing: 6) {
                Text(role)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(.secondary.opacity(0.52))
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: isTrailing ? .trailing : .leading)
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .lineSpacing(2)
                    .foregroundStyle(.white.opacity(style == .draft ? 0.88 : 0.95))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                accessory()
            }
            .frame(maxWidth: maxBubbleWidth, alignment: isTrailing ? .trailing : .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            if !isTrailing { Spacer(minLength: sideSpacer) }
        }
        .frame(maxWidth: .infinity)
    }

    private var background: AnyShapeStyle {
        switch style {
        case .incoming:
            return AnyShapeStyle(Color.white.opacity(0.075))
        case .draft:
            return AnyShapeStyle(Color.white.opacity(0.055))
        case .hint(let isStreaming):
            return AnyShapeStyle(
                isStreaming
                    ? Color(red: 0.17, green: 0.22, blue: 0.26)
                    : Color(red: 0.18, green: 0.23, blue: 0.27)
            )
        }
    }
}

struct TranslationView: View {
    let text: String
    let isLoading: Bool
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("中文", systemImage: "character.book.closed")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.59, green: 0.78, blue: 0.88).opacity(0.82))
            if let error {
                Text(error)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
            } else if isLoading && text.isEmpty {
                Text("Translating...")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.74))
            } else {
                Text(text)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineSpacing(2)
                    .foregroundStyle(Color(red: 0.78, green: 0.90, blue: 0.95).opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color(red: 0.18, green: 0.34, blue: 0.40).opacity(0.22),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
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
