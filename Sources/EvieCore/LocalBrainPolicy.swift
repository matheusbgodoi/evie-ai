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
  /// - No `--api-key`: the per-launch key goes in the environment
  ///   (`makeEnvironment`), because an argv is readable by every process of
  ///   this user through `ps` (ADR 0017).
  /// - No `--enable-thinking`: the server's default stays off, and Evie sends
  ///   `enable_thinking` on every request regardless.
  public static func makeArguments(_ runtime: LocalRuntime, model: String) -> [String] {
    var arguments = [
      "--model", model,
      "--host", "127.0.0.1",
      "--port", String(runtime.port),
      "--max-kv-size", String(runtime.maxKVSize),
      "--max-num-seqs", "1",
    ]
    if let bits = runtime.kvBits { arguments += ["--kv-bits", String(bits)] }
    if let step = runtime.prefillStepSize { arguments += ["--prefill-step-size", String(step)] }
    if let bytes = runtime.metalCacheLimitBytes {
      arguments = ["-I", "-c", boundedBootstrap, runtime.executable, String(bytes)] + arguments
    }
    return arguments
  }

  /// Applies MLX's public allocator limit before running the unmodified CLI.
  /// Exact bytes identify this wrapper before a process may be reused or stopped.
  public static let boundedBootstrap =
    "import sys,runpy;import mlx.core as mx;server=sys.argv.pop(1);cache=int(sys.argv.pop(1));mx.set_cache_limit(cache);sys.argv[0]=server;runpy.run_path(server,run_name='__main__')"

  /// Bounded launches require the CLI's absolute Python shebang, never PATH/env.
  public static func launchExecutable(_ runtime: LocalRuntime, scriptHead: String) -> String? {
    guard runtime.hasValidMemoryConfiguration else { return nil }
    guard runtime.metalCacheLimitMB != nil else { return runtime.executable }
    guard let interpreter = interpreterPath(fromScriptHead: scriptHead),
      URL(fileURLWithPath: interpreter).lastPathComponent.lowercased().hasPrefix("python"),
      let firstLine = scriptHead.split(separator: "\n", maxSplits: 1).first,
      firstLine.dropFirst(2).split(whereSeparator: { $0.isWhitespace }).count == 1
    else { return nil }
    return interpreter
  }

  /// The server's environment: the account basics and where the model cache
  /// lives, nothing else inherited, offline, and `apiKey` — the key made for
  /// this launch — as `MLX_VLM_SERVER_API_KEY`, which mlx-vlm 0.7.8 reads on
  /// every request (`server/app.py`, `_server_api_key`) and then demands as
  /// `Authorization: Bearer` on every route, `/health` included. A stray
  /// `MLX_VLM_SERVER_API_KEY`, `MAX_KV_SIZE` or `PYTHONPATH` in Evie's
  /// environment would otherwise reconfigure the server behind the argv.
  public static func makeEnvironment(
    inheriting environment: [String: String],
    apiKey: String
  ) -> [String: String] {
    var result = environment.filter { inheritedNames.contains($0.key) }
    result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    result["HF_HUB_OFFLINE"] = "1"
    result[apiKeyVariable] = apiKey
    return result
  }

  /// The variable mlx-vlm reads its key from.
  public static let apiKeyVariable = "MLX_VLM_SERVER_API_KEY"

  /// Whether a server holds to the key: it refused `/health` without it (401)
  /// and answered it with it. A server started by hand without a key answers
  /// both, and one started with another key refuses both; neither is the
  /// server Evie (or her script) started this time.
  public static func enforcesKey(statusWithoutKey: Int?, statusWithKey: Int?) -> Bool {
    statusWithoutKey == 401 && statusWithKey.map { (200...299).contains($0) } == true
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
    guard let options = serverOptions(arguments, runtime: runtime) else { return false }
    return lastValue(of: "--port", in: options) == String(runtime.port)
      && lastValue(of: "--host", in: options) == "127.0.0.1"
  }

  /// Identity allows stopping a previous configuration; reuse additionally
  /// requires the model and all memory controls to match the current profile.
  public static func argumentsServeProfile(
    _ arguments: [String], runtime: LocalRuntime, model: String
  ) -> Bool {
    guard runtime.hasValidMemoryConfiguration,
      argumentsIdentifyServer(arguments, runtime: runtime),
      let options = serverOptions(arguments, runtime: runtime),
      lastValue(of: "--model", in: options) == model,
      lastValue(of: "--max-kv-size", in: options) == String(runtime.maxKVSize),
      lastValue(of: "--max-num-seqs", in: options) == "1",
      lastValue(of: "--kv-bits", in: options) == runtime.kvBits.map(String.init),
      lastValue(of: "--prefill-step-size", in: options) == runtime.prefillStepSize.map(String.init)
    else { return false }
    let actualBytes = options.startIndex == 6 ? Int(arguments[5]) : nil
    return actualBytes == runtime.metalCacheLimitBytes
  }

  private static func serverOptions(
    _ arguments: [String], runtime: LocalRuntime
  ) -> ArraySlice<String>? {
    if arguments.count >= 6, arguments[1] == "-I", arguments[2] == "-c",
      arguments[3] == boundedBootstrap, arguments[4] == runtime.executable,
      let bytes = Int(arguments[5]), bytes > 0
    {
      return arguments.dropFirst(6)
    }
    guard let program = arguments.firstIndex(of: runtime.executable), program <= 1 else {
      return nil
    }
    return arguments.dropFirst(program + 1)
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
  /// The server on the port did not hold to the key it was started with: it
  /// answered without one, or refused the one in `brain.key`.
  case unverifiedKey(port: Int)
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
    case .unverifiedKey(let port):
      "O servidor na porta \(port) não confirmou a chave com que a Evie o iniciou; "
        + "ela não vai mandar nada para lá."
    case .couldNotLaunch(let reason):
      "Não consegui acordar o cérebro do Mac: \(reason)"
    }
  }

  private static let logHint = "O log fica em Application Support/Evie/Runtime/brain.log."
}
