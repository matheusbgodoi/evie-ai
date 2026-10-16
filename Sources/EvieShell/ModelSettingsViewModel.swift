import EvieCore
import Foundation

@MainActor
final class ModelSettingsViewModel: ObservableObject {
  /// Which pane of the Avançado tab is showing.
  @Published var advancedPane = 0
  @Published var temperature: Double
  @Published var topP: Double
  @Published var usesDefaultTemperature: Bool
  @Published var usesDefaultTopP: Bool
  @Published var maxCompletionTokens: Int
  @Published var requestTimeout: Double
  @Published private(set) var feedback: Feedback?

  let endpoint: String
  let model: String
  let contextWindowTokens: Int

  private let store: EvieConfigurationStore
  private let loader: EvieConfigurationLoader
  private let environment: [String: String]
  private let onSave: @MainActor (EvieLoadedConfiguration) -> Void
  /// The profiles a damaged file is repaired from: those Evie launched with,
  /// then the last ones saved.
  private var repairBaseline: EvieModelProfileSet

  init(
    configuration: EvieConfiguration,
    profiles: EvieModelProfileSet,
    store: EvieConfigurationStore = EvieConfigurationStore(),
    loader: EvieConfigurationLoader = EvieConfigurationLoader(),
    environment: [String: String] = [:],
    onSave: @escaping @MainActor (EvieLoadedConfiguration) -> Void
  ) {
    self.store = store
    self.loader = loader
    self.environment = environment
    self.onSave = onSave
    repairBaseline = profiles
    temperature = configuration.temperature ?? 0.2
    topP = configuration.topP ?? 0.95
    usesDefaultTemperature = configuration.temperature == nil
    usesDefaultTopP = configuration.topP == nil
    maxCompletionTokens = configuration.maxCompletionTokens
    requestTimeout = configuration.requestTimeout
    endpoint = configuration.endpoint.absoluteString
    model = configuration.model
    contextWindowTokens = configuration.contextWindowTokens
  }

  var completionTokenRange: ClosedRange<Int> {
    1...contextWindowTokens
  }

  var timeoutRange: ClosedRange<Double> {
    min(0.1, requestTimeout)...max(3_600, requestTimeout)
  }

  var topPRange: ClosedRange<Double> {
    min(0.001, topP)...1
  }

  var temperatureIsManaged: Bool {
    environment["EVIE_MODEL_TEMPERATURE"] != nil
  }

  var topPIsManaged: Bool {
    environment["EVIE_MODEL_TOP_P"] != nil
  }

  var completionLimitIsManaged: Bool {
    environment["EVIE_MODEL_MAX_COMPLETION"] != nil
  }

  var timeoutIsManaged: Bool {
    environment["EVIE_MODEL_TIMEOUT_SECONDS"] != nil
  }

  var hasManagedValues: Bool {
    temperatureIsManaged || topPIsManaged || completionLimitIsManaged || timeoutIsManaged
  }

  func save() {
    do {
      // The store re-reads the file, edits only the profile in use and writes
      // schema v2; the environment's overrides are never written into it.
      let saved = try store.saveActiveProfile(
        reading: loader,
        environment: environment,
        otherwise: repairBaseline
      ) { profile in
        if !temperatureIsManaged {
          profile.temperature = usesDefaultTemperature ? nil : temperature
        }
        if !topPIsManaged {
          profile.topP = usesDefaultTopP ? nil : topP
        }
        if !completionLimitIsManaged {
          profile.maxCompletionTokens = maxCompletionTokens
        }
        if !timeoutIsManaged {
          profile.requestTimeout = requestTimeout
        }
      }
      let effective = try loader.loadProfiles(environment: environment)
      repairBaseline = saved
      onSave(effective)
      feedback = Feedback(
        message: hasManagedValues
          ? "Arquivo salvo. Valores gerenciados pelo ambiente continuam prevalecendo."
          : "Salvo. A próxima pergunta já usa estes ajustes.",
        isError: false
      )
    } catch {
      feedback = Feedback(message: error.localizedDescription, isError: true)
    }
  }

  func restoreRecommendedSampling() {
    temperature = 0.2
    topP = 0.95
    usesDefaultTemperature = false
    usesDefaultTopP = false
    feedback = nil
  }
}

extension ModelSettingsViewModel {
  struct Feedback: Equatable {
    let message: String
    let isError: Bool
  }
}
