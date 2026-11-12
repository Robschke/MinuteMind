import MarkdownUI
import SwiftUI

struct MarkdownDisplayView: View {
    let content: String

    var body: some View {
        Markdown(content)
            .markdownTheme(.docC)
            .textSelection(.enabled)
    }
}
