import Foundation

/// The rules for the brain that runs on this Mac (ADR 0015): when it unloads,
/// when there is too little memory to start it, the exact command it starts
/// with, and how its process is recognised. Pure, so every rule is tested
/// without starting a model; `EvieLocalBrainLauncher` (EvieShell) carries them
/// out.
public struct LocalBrainPolicy: Sendable, Equatable {
  public enum StartVerdict: Sendable, Equatable {
    case start
    case refuse(String)
  }

  /// How long the brain may sit unused before it is stopped. It holds about
  /// 8 GB of a 24 GB Mac, and waking it again costs seconds, not minutes.
  public let idleUnloadAfter: Duration
  /// The free memory a start needs. Measured 2026-10-16 on this Mac (M5,
  /// 24 GB, macOS 27.2): LensVLM under mlx-vlm 0.7.8 holds a footprint of
  /// 8,148–8,164 MB once loaded. A start with 8.27 GiB free worked (ready in
  /// 5.4 s) and pushed 1.7 GB of other apps to swap; the spec's ~10 GB would
  /// have refused it. Below the footprint the whole model has to come out of
  /// other apps' memory, so that is the floor.
  public let minimumAvailableBytes: UInt64
  /// What a running voice engine holds (`EvieVoiceEngineLauncher`: a 2.4 GB
  /// model). Idle between phrases, its pages read as inactive, which is
  /// counted as free, so it is taken off again: starting the brain on top of
  /// it would push Evie's own voice into the compressor.
  public let voiceEngineBytes: UInt64

  public static let standard = LocalBrainPolicy(
    idleUnloadAfter: .seconds(600),
    minimumAvailableBytes: 8 << 30,
    voiceEngineBytes: 2_576_980_378
  )

  public init(idleUnloadAfter: Duration, minimumAvailableBytes: UInt64, voiceEngineBytes: UInt64) {
    self.idleUnloadAfter = idleUnloadAfter
    self.minimumAvailableBytes = minimumAvailableBytes
    self.voiceEngineBytes = voiceEngineBytes
  }

  public func shouldUnload(
    lastUse: ContinuousClock.Instant,
    now: ContinuousClock.Instant
  ) -> Bool {
    now - lastUse >= idleUnloadAfter
  }

  /// `availableBytes` is free + inactive + purgeable pages (`host_statistics64`),
  /// what macOS can hand out without paging anything that is in use.
  public func startVerdict(availableBytes: UInt64, voiceEngineResident: Bool) -> StartVerdict {
    let deduction = voiceEngineResident ? voiceEngineBytes : 0
    let usable = availableBytes > deduction ? availableBytes - deduction : 0
    guard usable < minimumAvailableBytes else {
      return .start
    }
    let voiceNote =
      voiceEngineResident
      ? " (sem contar ~\(Self.gigabytes(voiceEngineBytes)) GB do motor de voz)" : ""
    return .refuse(
      "O Mac está com pouca memória livre para o cérebro local: "
        + "\(Self.gigabytes(usable)) GB livres\(voiceNote), "
        + "e ele precisa de ~\(Self.gigabytes(minimumAvailableBytes)) GB. "
        + "Feche alguns apps e tente de novo."
    )
  }

  /// The server's argv, after the executable.
  ///
  /// - `--model` is the profile's model id exactly. mlx-vlm 0.7.8 loads
  ///   whatever a request names and drops the model it held, so the requests
  ///   carry the same id; with `HF_HUB_OFFLINE=1` a wrong one fails instead of
  ///   downloading. Naming it here also loads it at startup, so `/health` only
  ///   answers once the model is in memory.
  /// - `--host 127.0.0.1`: the server's default is 0.0.0.0, every interface.
  /// - `--max-kv-size`: the server refuses (or, with automatic compaction,
  ///   trims the output of) any request whose prompt plus `max_tokens` exceeds
  ///   it; read from the 0.7.8 source and checked live, 2026-10-16.
  /// - `--max-num-seqs 1`: one sequence at a time, so that cap is also the
  ///   memory cap; Evie sends one request at a time anyway.
  /// - No `--api-key`: nothing but this Mac reaches loopback, and a key would
  ///   only be one more secret to keep.
  /// - No `--enable-thinking`: the server's default stays off, and Evie sends
  ///   `enable_thinking` on every request regardless.
  public static func makeArguments(_ runtime: LocalRuntime, model: String) -> [String] {
    [
      "--model", model,
      "--host", "127.0.0.1",
      "--port", String(runtime.port),
      "--max-kv-size", String(runtime.maxKVSize),
      "--max-num-seqs", "1",
    ]
  }

  /// The server's environment: the account basics and where the model cache
  /// lives, nothing else inherited, and offline. A stray
  /// `MLX_VLM_SERVER_API_KEY`, `MAX_KV_SIZE` or `PYTHONPATH` in Evie's
  /// environment would otherwise reconfigure the server behind the argv.
  public static func makeEnvironment(inheriting environment: [String: String]) -> [String: String] {
    var result = environment.filter { inheritedNames.contains($0.key) }
    result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    result["HF_HUB_OFFLINE"] = "1"
    return result
  }

  private static let inheritedNames: Set<String> = [
    "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "HF_HOME", "HF_HUB_CACHE",
  ]

  /// Whether a process's argv is this server's: the configured executable as
  /// the program (`argv[0]`), or as the script an interpreter runs (`argv[1]`,
  /// which is how the kernel starts a `#!` script), serving the configured
  /// port on loopback only. A pid file can name a pid that was since reused,
  /// and a server can be started by hand; this is what is checked before
  /// trusting it, and before signalling it.
  ///
  /// The port and the host are the *last* values given, in any spelling
  /// argparse accepts (`--host X`, `--host=X`, an unambiguous prefix such as
  /// `--hos X`), because that is the value the server uses. The host must be
  /// `127.0.0.1`: mlx-vlm's default is `0.0.0.0`, so a server started without
  /// `--host` serves every interface, with no key, and would be handed the
  /// conversation and the screen.
  public static func argumentsIdentifyServer(_ arguments: [String], runtime: LocalRuntime) -> Bool {
    guard let program = arguments.firstIndex(where: { $0 == runtime.executable }), program <= 1
    else {
      return false
    }
    let options = arguments[(program + 1)...]
    return lastValue(of: "--port", in: options) == String(runtime.port)
      && lastValue(of: "--host", in: options) == "127.0.0.1"
  }

  /// Whether every address the server listens on is loopback: exactly
  /// `127.0.0.1` or `::1`. A wildcard (`0.0.0.0`, `::`) or a real interface is
  /// reachable from the network. No listener at all (still loading) exposes
  /// nothing.
  public static func listensOnlyOnLoopback(_ addresses: [String]) -> Bool {
    addresses.allSatisfy { $0 == "127.0.0.1" || $0 == "::1" }
  }

  /// The value argparse ends up with for `option`: the last `option value`,
  /// `option=value`, or the same with an abbreviation argparse would expand
  /// (a prefix of at least `--` and two letters; the shorter `--h` and `--p`
  /// are ambiguous in mlx-vlm and refused by it).
  static func lastValue(of option: String, in arguments: ArraySlice<String>) -> String? {
    var value: String?
    var index = arguments.startIndex
    while index < arguments.endIndex {
      let argument = arguments[index]
      let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
      if name.count >= 4, option.hasPrefix(name) {
        if name.count < argument.count {
          value = String(argument.dropFirst(name.count + 1))
        } else if index + 1 < arguments.endIndex {
          value = arguments[index + 1]
          index += 1
        }
      }
      index += 1
    }
    return value
  }

  /// The interpreter a script names on its first line, when that is an
  /// absolute path. The image of a script's process is its interpreter, so this
  /// is what `proc_pidpath` is compared with; an interpreter found on `$PATH`
  /// cannot be compared, and gives nil.
  public static func interpreterPath(fromScriptHead head: String) -> String? {
    guard head.hasPrefix("#!") else {
      return nil
    }
    let line = head.dropFirst(2).prefix { $0 != "\n" }
    guard let path = line.split(separator: " ", omittingEmptySubsequences: true).first,
      path.hasPrefix("/")
    else {
      return nil
    }
    return String(path)
  }

  /// Binary gigabytes with one decimal and a decimal comma, as Activity
  /// Monitor shows them: "7,6".
  static func gigabytes(_ bytes: UInt64) -> String {
    String(format: "%.1f", Double(bytes) / Double(1 << 30))
      .replacingOccurrences(of: ".", with: ",")
  }
}

/// Why the Mac brain could not be started or used, as the person reads it.
public enum LocalBrainLaunchError: LocalizedError, Equatable, Sendable {
  /// Something that is not the configured server listens on the port. It is
  /// refused rather than fought over: whatever it is would be handed the
  /// conversation and the screen.
  case portHeld(port: Int)
  case notInstalled(executable: String)
  case lowMemory(String)
  case neverAnswered(seconds: Int)
  case exitedDuringStartup
  /// `/health` answered, but the listener is not the process Evie started.
  case notOurServer(port: Int)
  case couldNotLaunch(String)

  public var errorDescription: String? {
    switch self {
    case .portHeld(let port):
      "A porta \(port) está ocupada por outro processo."
    case .notInstalled(let executable):
      "O cérebro do Mac não está instalado: falta \(executable)."
    case .lowMemory(let explanation):
      explanation
    case .neverAnswered(let seconds):
      "O cérebro do Mac não respondeu em \(seconds) s. \(Self.logHint)"
    case .exitedDuringStartup:
      "O cérebro do Mac fechou enquanto acordava. \(Self.logHint)"
    case .notOurServer(let port):
      "Quem respondeu na porta \(port) não é o cérebro que a Evie iniciou; "
        + "ela não vai mandar nada para lá."
    case .couldNotLaunch(let reason):
      "Não consegui acordar o cérebro do Mac: \(reason)"
    }
  }

  private static let logHint = "O log fica em Application Support/Evie/Runtime/brain.log."
}
