import SwiftUI
import OutputBridge

enum EditorTypography {
    static let caption = CGFloat(EDITOR_FONT_CAPTION)
    static let item = CGFloat(EDITOR_FONT_ITEM)
    static let body = CGFloat(EDITOR_FONT_BODY)
    static let title = CGFloat(EDITOR_FONT_TITLE)
}

extension Font {
    static let editorCaption = Font.system(size: EditorTypography.caption)
    static let editorItem = Font.system(size: EditorTypography.item)
    static let editorValue = editorItem.monospacedDigit()
    static let editorBody = Font.system(size: EditorTypography.body)
    static let editorHeading = editorBody.weight(.semibold)
    static let editorTitle = Font.system(size: EditorTypography.title, weight: .semibold)
}
