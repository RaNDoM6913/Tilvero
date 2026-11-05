import SwiftUI

/// Small "i" next to a section title; the explanation lives in its popover instead of as caption text under the
/// controls. No focus frame is drawn around it (VoiceOver and the accessibility label are unaffected).
@MainActor struct SectionInfoButton: View {
    let title: String
    let paragraphs: [String]
    let id: String
    var action: (title: String, handler: () -> Void)?
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .accessibilityLabel(L10n.text("About") + ": " + title)
        .accessibilityIdentifier(id)
        .help(L10n.text("About") + ": " + title)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                ForEach(paragraphs, id: \.self) { paragraph in
                    Text(paragraph).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let action {
                    Button(action.title) { shown = false; action.handler() }.padding(.top, 2)
                }
            }
            .frame(width: 270, alignment: .leading).padding(14)
        }
    }
}
