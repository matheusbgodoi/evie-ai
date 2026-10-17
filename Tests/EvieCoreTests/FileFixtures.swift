import AppKit
import CoreText
import Foundation

/// Folders and documents built for a test, always under the temporary
/// directory. Nothing here touches the real Desktop, Documents or Downloads: a
/// "home" is a fresh folder with those three names inside it.
enum FileFixtures {
  static func directory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A stand-in home folder with Desktop, Documents and Downloads.
  static func home() throws -> URL {
    let home = try directory("home")
    for name in ["Desktop", "Documents", "Downloads"] {
      try FileManager.default.createDirectory(
        at: home.appendingPathComponent(name, isDirectory: true),
        withIntermediateDirectories: true
      )
    }
    return home
  }

  static func write(_ text: String, to url: URL, modified: Date? = nil) throws {
    try write(Data(text.utf8), to: url, modified: modified)
  }

  static func write(_ data: Data, to url: URL, modified: Date? = nil) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url)
    if let modified {
      try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
  }

  /// A one-page PDF with a real text layer, drawn with Core Text.
  static func pdf(text: String) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let consumer = CGDataConsumer(data: data),
      let context = CGContext(consumer: consumer, mediaBox: &box, nil)
    else {
      return Data()
    }
    context.beginPDFPage(nil)
    let string = NSAttributedString(
      string: text,
      attributes: [.font: NSFont.systemFont(ofSize: 12)]
    )
    let framesetter = CTFramesetterCreateWithAttributedString(string)
    let frame = CTFramesetterCreateFrame(
      framesetter,
      CFRange(location: 0, length: 0),
      CGPath(rect: box.insetBy(dx: 50, dy: 50), transform: nil),
      nil
    )
    CTFrameDraw(frame, context)
    context.endPDFPage()
    context.closePDF()
    return data as Data
  }

  /// A Word document written by the system's own Office Open XML writer.
  static func docx(text: String) throws -> Data {
    let string = NSAttributedString(string: text)
    return try string.data(
      from: NSRange(location: 0, length: string.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
    )
  }
}
