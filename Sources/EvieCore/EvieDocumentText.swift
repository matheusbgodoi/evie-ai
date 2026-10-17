import AppKit
import Foundation
import PDFKit

/// The text inside an everyday document — a PDF, a Word file, an RTF — taken
/// from its bytes without OCR.
///
/// This is the fast, synchronous path the folder tools use, so "lê o PDF na
/// pasta e me resume" works on the file itself rather than only on something
/// attached. A scanned PDF has no text layer and yields nothing here; reading
/// its pixels is `EvieDocumentReader`'s job, on a file the person attaches.
///
/// Every byte comes from `EvieScopedFileReader.readData`, so extraction never
/// opens a path of its own and inherits the kernel containment. The text that
/// comes out is the document's, which makes it untrusted content: it reaches the
/// model as a tool result, never as an instruction.
public enum EvieDocumentText {
  /// Formats whose text has to be extracted rather than read.
  public static let extractedExtensions: Set<String> = ["pdf", "docx", "doc", "rtf", "odt"]

  /// Plain text formats, read as UTF-8.
  public static let plainExtensions: Set<String> = [
    "txt", "text", "md", "markdown", "csv", "tsv",
  ]

  /// How much text one document contributes. Long enough for a chapter, short
  /// enough that one file cannot fill the Mac brain's whole context.
  public static let maximumCharacters = 60_000

  /// PDF pages read for text. A 300-page book stops here instead of becoming a
  /// minute of work for an opening it will be cut to anyway.
  public static let maximumPDFPages = 60

  public static func isExtracted(_ name: String) -> Bool {
    extractedExtensions.contains((name as NSString).pathExtension.lowercased())
  }

  public static func isReadable(_ name: String) -> Bool {
    let extensionName = (name as NSString).pathExtension.lowercased()
    return extractedExtensions.contains(extensionName) || plainExtensions.contains(extensionName)
  }

  /// What was extracted, and whether it was cut.
  public struct Extract: Hashable, Sendable {
    public var text: String
    public var isTruncated: Bool
    /// Pages, for a PDF.
    public var pageCount: Int?
  }

  /// The document's text, or nil when the format is unknown or holds none.
  public static func extract(
    from data: Data,
    fileExtension: String,
    maximumCharacters: Int = EvieDocumentText.maximumCharacters
  ) -> Extract? {
    let format = fileExtension.lowercased()
    var pageCount: Int?
    let raw: String?
    switch format {
    case "pdf":
      guard let document = PDFDocument(data: data) else {
        return nil
      }
      pageCount = document.pageCount
      // Stops as soon as there is more than will be kept, so a short extract
      // of a long PDF reads a page or two rather than sixty.
      var pages: [String] = []
      var collected = 0
      for index in 0..<min(document.pageCount, maximumPDFPages) where collected <= maximumCharacters {
        guard let page = document.page(at: index)?.string else {
          continue
        }
        pages.append(page)
        collected += page.count
      }
      raw = pages.joined(separator: "\n\n")
    case "docx":
      raw = attributedText(data, type: .officeOpenXML)
    case "doc":
      raw = attributedText(data, type: .docFormat)
    case "rtf":
      raw = attributedText(data, type: .rtf)
    case "odt":
      raw = attributedText(data, type: .openDocument)
    case _ where plainExtensions.contains(format):
      raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    default:
      return nil
    }

    let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      return nil
    }
    let isTruncated = text.count > maximumCharacters
    return Extract(
      text: isTruncated ? String(text.prefix(maximumCharacters)) : text,
      isTruncated: isTruncated,
      pageCount: pageCount
    )
  }

  private static func attributedText(
    _ data: Data,
    type: NSAttributedString.DocumentType
  ) -> String? {
    try? NSAttributedString(
      data: data,
      options: [.documentType: type],
      documentAttributes: nil
    ).string
  }
}
