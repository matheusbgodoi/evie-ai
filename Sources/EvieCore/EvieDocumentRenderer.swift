import AppKit
import CoreText
import Foundation

/// Turns the Markdown Evie wrote into the bytes of a real document.
///
/// Word and RTF come from the system's own writers (`NSAttributedString`'s
/// document export, `.officeOpenXML` for `.docx`), so the file is the one Pages
/// and TextEdit write rather than a format reimplemented here. The PDF is laid
/// out with Core Text on A4 pages. Markdown and plain text are written as text.
///
/// Arial at 12 points, because it is on every Mac and every copy of Word, and
/// it is what a Brazilian university asks for (ABNT accepts Arial or Times 12).
public enum EvieDocumentRenderer {
  public enum RenderError: Error, Equatable, Sendable {
    case failed(EvieDocumentFormat)
  }

  public static let bodySize: CGFloat = 12
  /// A4, in points.
  public static let pageSize = CGSize(width: 595.28, height: 841.89)
  public static let margin: CGFloat = 64

  public static func render(_ proposal: EvieDocumentProposal) throws -> Data {
    switch proposal.format {
    case .markdown:
      return Data(terminated(proposal.markdown).utf8)
    case .text:
      return Data(terminated(EvieRichText(proposal.markdown).plainText).utf8)
    case .rtf:
      return try export(attributed(proposal.markdown), as: .rtf, title: proposal.title)
    case .docx:
      return try export(attributed(proposal.markdown), as: .officeOpenXML, title: proposal.title)
    case .pdf:
      return pdf(attributed(proposal.markdown), title: proposal.title)
    }
  }

  private static func terminated(_ text: String) -> String {
    text.hasSuffix("\n") ? text : text + "\n"
  }

  private static func export(
    _ text: NSAttributedString,
    as type: NSAttributedString.DocumentType,
    title: String
  ) throws -> Data {
    do {
      return try text.data(
        from: NSRange(location: 0, length: text.length),
        documentAttributes: [.documentType: type, .title: title]
      )
    } catch {
      throw RenderError.failed(type == .rtf ? .rtf : .docx)
    }
  }

  // MARK: - Layout

  /// The Markdown as styled text: headings, paragraphs, lists, code, and the
  /// inline bold, italic and links inside them.
  static func attributed(_ markdown: String) -> NSAttributedString {
    let document = NSMutableAttributedString()
    for block in EvieRichText(markdown).blocks {
      switch block {
      case .heading(let level, let text):
        let size: CGFloat = level == 1 ? 20 : level == 2 ? 16 : 13
        document.append(
          paragraph(text, size: size, bold: true, spacingBefore: 12, spacingAfter: 6)
        )
      case .paragraph(let text):
        document.append(paragraph(text, size: bodySize, spacingAfter: 8))
      case .bullet(let level, let text):
        document.append(listItem("•", text, level: level))
      case .numbered(let level, let number, let text):
        document.append(listItem("\(number).", text, level: level))
      case .code(_, let text):
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        document.append(
          NSAttributedString(
            string: text + "\n",
            attributes: [
              .font: NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular),
              .paragraphStyle: style,
            ]
          )
        )
      case .rule:
        document.append(NSAttributedString(string: "\n"))
      }
    }
    return document
  }

  private static func paragraph(
    _ text: String,
    size: CGFloat,
    bold: Bool = false,
    spacingBefore: CGFloat = 0,
    spacingAfter: CGFloat
  ) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacingBefore = spacingBefore
    style.paragraphSpacing = spacingAfter
    style.lineHeightMultiple = 1.15
    return inline(text, size: size, bold: bold, style: style)
  }

  private static func listItem(_ marker: String, _ text: String, level: Int) -> NSAttributedString {
    let indent = CGFloat(level) * 18
    let style = NSMutableParagraphStyle()
    style.firstLineHeadIndent = indent
    style.headIndent = indent + 18
    style.paragraphSpacing = 3
    style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 18)]
    let line = NSMutableAttributedString(
      string: marker + "\t",
      attributes: [.font: font(size: bodySize), .paragraphStyle: style]
    )
    line.append(inline(text, size: bodySize, style: style))
    return line
  }

  /// One line of Markdown with its inline emphasis resolved, ending in a
  /// paragraph break.
  private static func inline(
    _ text: String,
    size: CGFloat,
    bold: Bool = false,
    style: NSParagraphStyle
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let parsed =
      (try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
      )) ?? AttributedString(text)
    for run in parsed.runs {
      let intent = run.inlinePresentationIntent ?? []
      var attributes: [NSAttributedString.Key: Any] = [
        .font: intent.contains(.code)
          ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
          : font(
            size: size,
            bold: bold || intent.contains(.stronglyEmphasized),
            italic: intent.contains(.emphasized)
          ),
        .paragraphStyle: style,
      ]
      if let link = run.link {
        attributes[.link] = link
      }
      if intent.contains(.strikethrough) {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      result.append(
        NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes)
      )
    }
    result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
    return result
  }

  static func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
    let base = NSFont(name: "Arial", size: size) ?? NSFont.systemFont(ofSize: size)
    var traits: NSFontDescriptor.SymbolicTraits = []
    if bold {
      traits.insert(.bold)
    }
    if italic {
      traits.insert(.italic)
    }
    guard !traits.isEmpty else {
      return base
    }
    return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
  }

  // MARK: - PDF

  /// Lays the text out on as many A4 pages as it needs, with Core Text, which
  /// is safe off the main thread (an `NSTextView` printed to PDF is not).
  static func pdf(_ text: NSAttributedString, title: String) -> Data {
    let data = NSMutableData()
    var mediaBox = CGRect(origin: .zero, size: pageSize)
    let info = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Evie"]
    guard let consumer = CGDataConsumer(data: data),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
    else {
      return Data()
    }

    let framesetter = CTFramesetterCreateWithAttributedString(text)
    let textRect = mediaBox.insetBy(dx: margin, dy: margin)
    var location = 0
    repeat {
      context.beginPDFPage(nil)
      let frame = CTFramesetterCreateFrame(
        framesetter,
        CFRange(location: location, length: 0),
        CGPath(rect: textRect, transform: nil),
        nil
      )
      CTFrameDraw(frame, context)
      context.endPDFPage()
      let visible = CTFrameGetVisibleStringRange(frame)
      // A frame that fits nothing — a line taller than the page — would loop
      // forever; one page of it is the honest result.
      guard visible.length > 0 else {
        break
      }
      location += visible.length
    } while location < text.length
    context.closePDF()
    return data as Data
  }
}
