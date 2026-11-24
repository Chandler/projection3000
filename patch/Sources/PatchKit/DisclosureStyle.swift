import SwiftUI

/// One full-width target for the arrow, title and remaining header space.
struct PatchDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Button {
                var transaction = Transaction(animation:nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing:6) {
                    Image(systemName:configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size:10)).frame(width:12)
                    configuration.label
                    Spacer(minLength:0)
                }
                .frame(maxWidth:.infinity,minHeight:26,alignment:.leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
