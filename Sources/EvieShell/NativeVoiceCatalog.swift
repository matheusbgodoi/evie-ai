import AVFoundation
import AppKit
import Foundation

/// Only public AVFoundation voices that this app can instantiate are offered.
/// A voice appearing in speechVoices() alone is not evidence it is usable.
@MainActor
enum NativeVoiceCatalog {
  struct Record: Encodable, Sendable {
    let identifier: String
    let name: String
    let language: String
    let quality: String
    let usable: Bool
    let personal: Bool
    let novelty: Bool
    let rank: Int
  }

  static func records(language: String = "pt-BR") -> [Record] {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.caseInsensitiveCompare(language) == .orderedSame }
      .map { voice in
        let personal = voice.voiceTraits.contains(.isPersonalVoice)
        let novelty =
          voice.voiceTraits.contains(.isNoveltyVoice)
          || voice.identifier.contains(".eloquence.")
        let quality: String
        let qualityRank: Int
        switch voice.quality {
        case .premium:
          quality = "premium"
          qualityRank = 0
        case .enhanced:
          quality = "aprimorada"
          qualityRank = 1
        case .default:
          quality = "padrão"
          qualityRank = 2
        @unknown default:
          quality = "do sistema"
          qualityRank = 3
        }
        return Record(
          identifier: voice.identifier, name: voice.name, language: voice.language,
          quality: quality, usable: AVSpeechSynthesisVoice(identifier: voice.identifier) != nil,
          personal: personal, novelty: novelty,
          rank: (novelty ? 100 : 0) + (personal ? 10 : 0) + qualityRank * 2
            + (voice.identifier.contains("super-compact") ? 1 : 0))
      }
      .sorted {
        $0.rank == $1.rank
          ? ($0.name == $1.name ? $0.identifier < $1.identifier : $0.name < $1.name)
          : $0.rank < $1.rank
      }
  }

  static func options(language: String = "pt-BR") -> [EvieVoiceOption] {
    // Personal Voice requires a direct-playback path: Apple does not expose its
    // samples through this app's metered-buffer pipeline. Do not offer a voice
    // whose output cannot currently be verified.
    records(language: language).filter { $0.usable && !$0.personal }.map { record in
      EvieVoiceOption(
        id: record.identifier, name: record.name,
        isEnhanced: record.quality == "aprimorada" || record.quality == "premium",
        rank: record.rank, qualityLabel: record.personal ? "pessoal" : record.quality)
    }
  }

  static func openSystemVoiceSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")
    {
      NSWorkspace.shared.open(url)
    }
  }

  static var personalVoiceStatus: String {
    switch AVSpeechSynthesizer.personalVoiceAuthorizationStatus {
    case .authorized: "Permitida"
    case .denied: "Não permitida nos Ajustes do Sistema"
    case .notDetermined: "Ainda não solicitada"
    case .unsupported: "Indisponível neste Mac"
    @unknown default: "Estado desconhecido"
    }
  }

}

/// An event-driven catalog refreshes after a voice is downloaded or authorized.
@MainActor
final class NativeVoiceCatalogModel: ObservableObject {
  @Published private(set) var options: [EvieVoiceOption] = []
  @Published private(set) var personalVoiceStatus = ""

  func refresh() {
    options = NativeVoiceCatalog.options()
    personalVoiceStatus = NativeVoiceCatalog.personalVoiceStatus
  }

}
