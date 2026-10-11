import Foundation

/// How a link goes on the clipboard: plain, or ready to paste into Markdown or HTML.
public enum LinkFormat: String, CaseIterable, Codable, Sendable {
    case plain, markdown, html

    public func text(for url: URL) -> String {
        let link = url.absoluteString
        let name = url.lastPathComponent
        // PDFs count as screenshots for uploading, but they don't embed as images.
        let kind = url.pathExtension.lowercased() == "pdf" ? nil : Inbox.kind(of: name)
        switch (self, kind) {
        case (.plain, _): return link
        case (.markdown, .screenshot?): return "![](\(link))"
        case (.markdown, _): return "[\(name)](\(link))"
        case (.html, .screenshot?): return "<img src=\"\(link)\">"
        case (.html, .video?): return "<video src=\"\(link)\" controls></video>"
        case (.html, nil): return "<a href=\"\(link)\">\(name)</a>"
        }
    }
}
