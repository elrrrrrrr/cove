import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let coveSite = UTType(exportedAs: "dev.cove.site", conformingTo: .plainText)
}

struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.coveSite, .yaml, .plainText, .json] }
    var text: String
    var type: UTType
    init(text: String, type: UTType = .coveSite) { self.text = text; self.type = type }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CoveError.message("文件不是 UTF-8 文本")
        }
        self.text = text; type = configuration.contentType
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
