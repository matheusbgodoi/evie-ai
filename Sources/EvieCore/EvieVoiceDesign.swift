import Foundation

/// Turns a description of a voice, written the way a person would write it, into
/// the controlled vocabulary the local engine understands.
///
/// The engine's own describe endpoint only recognises English tokens, and only a
/// fixed set of them: gender, age, pitch, style, accent. Everything else — the
/// adjectives people actually reach for, like "confiante" or "irreverente" — is
/// silently dropped. Rather than make the user learn that vocabulary, or type in
/// English, the mapping lives here where it can be read and extended.
///
/// This exists because there is no legal way to take a voice you liked from a
/// commercial library and clone it: those terms forbid using their output to
/// build another voice model, and the voices are often real people who consented
/// to that service and not to this one. Describing what you liked about it is
/// the part that carries over.
public struct EvieVoiceDesign: Hashable, Sendable {
  public var gender: String?
  public var age: String?
  public var pitch: String?
  public var style: String?

  public init(gender: String? = nil, age: String? = nil, pitch: String? = nil, style: String? = nil) {
    self.gender = gender
    self.age = age
    self.pitch = pitch
    self.style = style
  }

  public var isEmpty: Bool {
    gender == nil && age == nil && pitch == nil && style == nil
  }

  /// The engine's `instruct` string.
  public var instruction: String {
    [gender, age, pitch, style].compactMap { $0 }.joined(separator: ", ")
  }

  /// What the interface shows back, so a person can see what was understood and
  /// what was ignored rather than wondering why the voice sounds generic.
  public var summary: String {
    guard !isEmpty else {
      return "Não reconheci nada na descrição."
    }
    var parts: [String] = []
    if let gender { parts.append(Self.portugueseName(for: gender)) }
    if let age { parts.append(Self.portugueseName(for: age)) }
    if let pitch { parts.append(Self.portugueseName(for: pitch)) }
    if let style { parts.append(Self.portugueseName(for: style)) }
    return parts.joined(separator: " · ")
  }

  /// Reads a Portuguese (or English) description.
  public static func parse(_ description: String) -> EvieVoiceDesign {
    let text = fold(description)
    var design = EvieVoiceDesign()

    for (terms, value) in genderTerms where terms.contains(where: text.contains) {
      design.gender = value
      break
    }
    for (terms, value) in ageTerms where terms.contains(where: text.contains) {
      design.age = value
      break
    }
    for (terms, value) in pitchTerms where terms.contains(where: text.contains) {
      design.pitch = value
      break
    }
    for (terms, value) in styleTerms where terms.contains(where: text.contains) {
      design.style = value
      break
    }
    return design
  }

  /// Words that did not contribute anything, so the interface can say so instead
  /// of letting the user believe they were used.
  public static func ignoredWords(in description: String) -> [String] {
    let recognised = (genderTerms + ageTerms + pitchTerms + styleTerms).flatMap { $0.0 }
    return
      fold(description)
      .split(whereSeparator: { !$0.isLetter })
      .map(String.init)
      .filter { $0.count > 3 }
      .filter { word in !recognised.contains { $0.contains(word) || word.contains($0) } }
      .reduce(into: [String]()) { unique, word in
        if !unique.contains(word) {
          unique.append(word)
        }
      }
  }
}

extension EvieVoiceDesign {
  // Ordered most specific first, so "mulher jovem" reads as young rather than
  // stopping at the first gender term and ignoring the rest.
  fileprivate static let genderTerms: [([String], String)] = [
    (["feminina", "feminino", "mulher", "moça", "garota", "female", "woman"], "female"),
    (["masculina", "masculino", "homem", "rapaz", "male", "man"], "male"),
  ]

  fileprivate static let ageTerms: [([String], String)] = [
    (["crianca", "infantil", "child", "kid"], "child"),
    (["adolescente", "teen"], "teenager"),
    (["jovem", "nova", "novo", "young"], "young adult"),
    (["madura", "maduro", "meia idade", "middle"], "middle-aged"),
    (["idosa", "idoso", "velha", "velho", "elderly", "old"], "elderly"),
  ]

  fileprivate static let pitchTerms: [([String], String)] = [
    (["grave", "grossa", "grosso", "profunda", "profundo", "low", "deep"], "low pitch"),
    (["aguda", "agudo", "fina", "fino", "high"], "high pitch"),
  ]

  fileprivate static let styleTerms: [([String], String)] = [
    (["calma", "calmo", "tranquila", "tranquilo", "serena", "sereno", "calm"], "calm"),
    (["energica", "energico", "animada", "animado", "energetic", "lively"], "energetic"),
    (["seria", "serio", "formal", "professional"], "professional"),
    (["alegre", "feliz", "cheerful", "happy"], "cheerful"),
    (["sussurro", "sussurrada", "whisper"], "whisper"),
  ]

  fileprivate static func fold(_ text: String) -> String {
    text.folding(
      options: [.diacriticInsensitive, .caseInsensitive],
      locale: Locale(identifier: "pt_BR")
    )
  }

  fileprivate static func portugueseName(for token: String) -> String {
    let names = [
      "female": "feminina", "male": "masculina",
      "child": "criança", "teenager": "adolescente", "young adult": "jovem",
      "middle-aged": "madura", "elderly": "idosa",
      "low pitch": "grave", "high pitch": "aguda",
      "calm": "calma", "energetic": "enérgica", "professional": "séria",
      "cheerful": "alegre", "whisper": "sussurrada",
    ]
    return names[token] ?? token
  }
}
