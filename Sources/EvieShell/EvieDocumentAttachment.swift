import EvieCore
import Foundation

/// A file Evie has read but not yet been asked about.
struct EvieDocumentAttachment: Identifiable, Hashable {
  let id = UUID()
  let name: String
  let pages: [EvieDocumentObservation]

  var characterCount: Int {
    pages.reduce(0) { $0 + $1.text.count }
  }

  /// What the card says at a glance.
  var summary: String {
    guard characterCount > 0 else {
      return "Não encontrei texto legível neste arquivo."
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
