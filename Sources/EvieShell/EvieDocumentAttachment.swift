import EvieCore
import Foundation

/// A file Evie has read but not yet been asked about.
struct EvieDocumentAttachment: Identifiable, Hashable {
  let id = UUID()
  let name: String
  let pages: [EvieDocumentObservation]
  /// What the picture shows, when this is a picture and this Mac can see.
  ///
  /// Kept beside the recognised text rather than replacing it, because the two
  /// answer different questions. Reading a screenshot needs the exact characters;
  /// understanding a photograph, a chart or a diagram needs what it depicts. A
  /// description alone loses the numbers; the text alone loses the picture.
  var visualDescription: String?

  var characterCount: Int {
    pages.reduce(0) { $0 + $1.text.count }
  }

  /// What the card says at a glance.
  var summary: String {
    guard characterCount > 0 else {
      return visualDescription == nil
        ? "Não encontrei texto legível neste arquivo."
        : "Sem texto, mas eu vi a imagem."
    }
    let pageDescription =
      pages.count == 1
      ? ""
      : "\(pages.count) páginas · "
    return "\(pageDescription)\(characterCount.formatted()) caracteres lidos"
  }

  /// The first lines, so the user can confirm Evie read the right thing before
  /// asking anything about it.
  var preview: String {
    let joined = pages.combinedText
    guard joined.count > 400 else {
      return joined
    }
    let cut = joined.index(joined.startIndex, offsetBy: 400)
    return String(joined[..<cut]) + "…"
  }

  /// Which path produced the text, because exact extraction and recognition
  /// deserve different levels of trust.
  var provenanceDescription: String {
    let recognised = pages.filter { $0.provenance == .recognizedFromPixels }
    if recognised.isEmpty {
      return "Texto extraído do próprio arquivo"
    }
    if recognised.count == pages.count {
      let confidence = recognised.compactMap(\.lowestConfidence).min()
      guard let confidence else {
        return "Texto reconhecido da imagem"
      }
      return String(format: "Reconhecido da imagem · confiança mínima %.0f%%", confidence * 100)
    }
    return "Parte extraída do arquivo, parte reconhecida da imagem"
  }
}
