import AppIntents
import EvieCore
import Foundation

/// These actions open visible UI only. A Shortcut is not approval to submit a
/// model request or grant computer control, even when its text asks for either.
enum NativeAppleRequest: Equatable {
  case openConversation
  case prepareQuestion(String)
  case captureScreen
  case requestCaptureConfirmation
}

enum NativeAppleError: LocalizedError {
  case notReady
  case busy
  case emptyQuestion
  case questionTooLong

  var errorDescription: String? {
    switch self {
    case .notReady: "A Evie ainda está iniciando. Tente novamente em um instante."
    case .busy: "A Evie está ocupada. Termine a interação atual e tente novamente."
    case .emptyQuestion: "Escreva a pergunta que deseja preparar na Evie."
    case .questionTooLong: "A pergunta precisa ter até 8.000 caracteres."
    }
  }
}

/// The coordinator installs the same visible UI paths used by Evie's menu.
/// No listener, polling timer, shell command, private Siri API or IPC endpoint.
@MainActor
enum NativeAppleActions {
  static var handle: ((NativeAppleRequest) throws -> Void)?

  static func perform(url: URL) throws {
    try performURLRequest(EvieNativeURLRequest.parse(url))
  }

  static func performURLRequest(_ request: EvieNativeURLRequest) throws {
    switch request {
    case .openConversation: try perform(.openConversation)
    case .prepareQuestion(let text): try perform(.prepareQuestion(text))
    case .requestCaptureConfirmation: try perform(.requestCaptureConfirmation)
    }
  }

  static func perform(_ request: NativeAppleRequest) throws {
    guard let handle else { throw NativeAppleError.notReady }
    if case .prepareQuestion(let question) = request {
      let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw NativeAppleError.emptyQuestion }
      guard trimmed.count <= EvieNativeURLRequest.maximumQuestionCharacters else {
        throw NativeAppleError.questionTooLong
      }
      try handle(.prepareQuestion(trimmed))
    } else {
      try handle(request)
    }
  }
}

#if EVIE_DIRECT_APP_INTENTS
  struct OpenEvieIntent: AppIntent {
    static var title: LocalizedStringResource { "Abrir Evie" }
    static var description: IntentDescription {
      IntentDescription("Abre o campo de conversa da Evie.", categoryName: "Evie")
    }
    static var supportedModes: IntentModes { .foreground(.immediate) }
    static var authenticationPolicy: IntentAuthenticationPolicy {
      .requiresLocalDeviceAuthentication
    }

    @MainActor
    func perform() async throws -> some IntentResult {
      try NativeAppleActions.perform(.openConversation)
      return .result()
    }
  }

  struct PrepareEvieQuestionIntent: AppIntent {
    static var title: LocalizedStringResource { "Preparar pergunta na Evie" }
    static var description: IntentDescription {
      IntentDescription(
        "Abre uma pergunta para você revisar e enviar. Não inicia ações automaticamente.",
        categoryName: "Evie")
    }
    static var supportedModes: IntentModes { .foreground(.immediate) }
    static var authenticationPolicy: IntentAuthenticationPolicy {
      .requiresLocalDeviceAuthentication
    }

    @Parameter(title: "Pergunta", description: "Texto para revisar na Evie antes de enviar.")
    var question: String

    static var parameterSummary: some ParameterSummary {
      Summary("Preparar \(\.$question) na Evie")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
      try NativeAppleActions.perform(.prepareQuestion(question))
      return .result()
    }
  }

  struct CaptureEvieScreenIntent: AppIntent {
    static var title: LocalizedStringResource { "Olhar tela com a Evie" }
    static var description: IntentDescription {
      IntentDescription(
        "Captura uma vez a tela sob o ponteiro, com indicador visível, para a próxima pergunta. Requer a permissão de gravação de tela do macOS.",
        categoryName: "Evie")
    }
    static var supportedModes: IntentModes { .foreground(.immediate) }
    static var authenticationPolicy: IntentAuthenticationPolicy {
      .requiresLocalDeviceAuthentication
    }

    @MainActor
    func perform() async throws -> some IntentResult {
      try NativeAppleActions.perform(.captureScreen)
      return .result()
    }
  }

  struct EvieAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
      AppShortcut(
        intent: OpenEvieIntent(),
        phrases: ["Abrir \(.applicationName)", "Conversar com \(.applicationName)"],
        shortTitle: "Conversar", systemImageName: "bubble.left.and.bubble.right")
      AppShortcut(
        intent: PrepareEvieQuestionIntent(),
        phrases: ["Preparar pergunta na \(.applicationName)"],
        shortTitle: "Preparar pergunta", systemImageName: "text.bubble")
      AppShortcut(
        intent: CaptureEvieScreenIntent(),
        phrases: ["Olhar tela com \(.applicationName)"],
        shortTitle: "Olhar tela", systemImageName: "viewfinder")
    }
  }
#endif

enum NativeAppleCapability {
  static let mode: String = {
    #if EVIE_DIRECT_APP_INTENTS
      "app-intents"
    #else
      "public-urls"
    #endif
  }()
}
