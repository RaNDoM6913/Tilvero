import SwiftUI

/// Finite event-driven main-window motion. The menu bar has independent styling.
enum ProductMotion {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }
}

/// Opaque, adaptive surfaces shared by the main application. Menu-bar content
/// keeps its own native blue/material styling and does not use this wrapper.
struct ProductSurface<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 8) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(Color.accentColor) }
                    Text(L10n.text(title)).font(.system(size: 13, weight: .semibold))
                }
            }
            content().font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.07)))
    }
}

struct ProductSectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text(title)).font(.system(size: 13, weight: .semibold))
            if let subtitle { Text(L10n.text(subtitle)).font(.callout).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor struct ProductIntro: View {
    let title: String
    let subtitle: String
    let symbol: String
    var artwork: NSImage? = nil
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { picture; information.frame(width: 320, alignment: .leading) }
            VStack(alignment: .leading, spacing: 16) { picture; information }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
    private var picture: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit().frame(width: 160, height: 120)
            } else {
                Image(systemName: symbol).font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.accentColor).frame(width: 72, height: 72)
                    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
            }
        }.accessibilityHidden(true)
    }
    private var information: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(title)).font(.title2.weight(.medium))
            Text(L10n.text(subtitle)).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

struct ProductMetric: View {
    let title: String
    let value: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value).font(.system(size: value.rangeOfCharacter(from: .decimalDigits) == nil ? 22 : 28, weight: .medium, design: .rounded)).monospacedDigit()
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text(title)).font(.system(size: 12)).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A qualified observed level, never an empty zero substituted for missing data.
struct ProductChargeTrack: View {
    let level: Int?
    var stale = false
    var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if let level, (0...100).contains(level) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(stale ? Color.secondary : Color.green)
                        .frame(width: geometry.size.width * CGFloat(level) / 100)
                }
            }.frame(height: 6)
                .animation(animate ? ProductMotion.animation(reduceMotion: reduceMotion) : nil, value: level)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("Charge level"))
                .accessibilityValue("\(level)%")
        }
    }
}

/// The entire section header is one native button. Content controls remain
/// separate, so using them never accidentally collapses their section.
struct ProductDisclosureStyle: DisclosureGroupStyle {
    var headerInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(ProductMotion.animation(reduceMotion: reduceMotion)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    configuration.label
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, headerInset == 0 ? 6 : 0)
                .padding(headerInset)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(L10n.text(configuration.isExpanded ? "Expanded" : "Collapsed"))
            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, headerInset)
                    .padding(.bottom, headerInset)
                    .padding(.top, headerInset == 0 ? 8 : 0)
            }
        }
    }
}
