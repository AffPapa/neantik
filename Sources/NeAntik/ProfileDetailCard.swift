import SwiftUI

/// An explicitly named section whose controls remain separate accessibility
/// children. The heading is ordinary content, including its Help buttons.
struct ProfileDetailCard<Heading: View, Content: View>: View {
    private let title: String
    private let heading: Heading
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content,
         @ViewBuilder label: () -> Heading) {
        self.title = title
        heading = label()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.secondary.opacity(0.15))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension ProfileDetailCard where Heading == Text {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content) { Text(title).font(.headline) }
    }
}

extension ProfileDetailCard where Heading == EmptyView {
    init(accessibilityTitle title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content) { EmptyView() }
    }
}
