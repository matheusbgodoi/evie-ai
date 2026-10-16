import Foundation
import Testing

@testable import EvieCore

/// The rules the Mac brain's launcher follows, without starting anything: when
/// it unloads, when memory is too low to start, the exact argv and environment
/// it launches with, and how it recognises its own server before trusting or
/// signalling a pid.
@Suite("Local brain policy")
struct LocalBrainPolicyTests {
  private let policy = LocalBrainPolicy.standard
  private let runtime = LocalRuntime(
    launcher: .mlxVLM,
    executable: "/Users/someone/.local/bin/mlx_vlm.server",
    port: 38_480,
    maxKVSize: 32_768
  )
  private let model = "mlx-community/LensVLM-9B-OptiQ-4bit"
  private let gib: UInt64 = 1 << 30

  // MARK: - Idle unload

  @Test("the brain unloads after ten idle minutes, not before")
  func idleThresholds() {
    let start = ContinuousClock.now

    #expect(policy.idleUnloadAfter == .seconds(600))
    #expect(!policy.shouldUnload(lastUse: start, now: start))
    #expect(!policy.shouldUnload(lastUse: start, now: start + .seconds(599)))
    #expect(policy.shouldUnload(lastUse: start, now: start + .seconds(600)))
    #expect(policy.shouldUnload(lastUse: start, now: start + .seconds(3_600)))
  }

  // MARK: - Memory

  @Test("enough free memory starts the brain")
  func enoughMemoryStarts() {
    #expect(policy.startVerdict(availableBytes: 9 * gib, voiceEngineResident: false) == .start)
    #expect(
      policy.startVerdict(availableBytes: policy.minimumAvailableBytes, voiceEngineResident: false)
        == .start
    )
  }

  @Test("too little free memory refuses, and says how much there is and how much it needs")
  func lowMemoryRefuses() {
    let verdict = policy.startVerdict(availableBytes: 6 * gib, voiceEngineResident: false)

    #expect(
      verdict
        == .refuse(
          "O Mac está com pouca memória livre para o cérebro local: 6,0 GB livres, "
            + "e ele precisa de ~8,0 GB. Feche alguns apps e tente de novo."
        )
    )
  }

  @Test("a running voice engine's memory is not counted as free")
  func voiceEngineIsDeducted() {
    // 10 GiB looks like enough, but 2.4 GiB of it is the idle voice engine,
    // whose pages read as inactive between phrases.
    let withVoice = policy.startVerdict(availableBytes: 10 * gib, voiceEngineResident: true)
    let withoutVoice = policy.startVerdict(availableBytes: 10 * gib, voiceEngineResident: false)
    let roomForBoth = policy.startVerdict(availableBytes: 11 * gib, voiceEngineResident: true)

    #expect(
      withVoice
        == .refuse(
          "O Mac está com pouca memória livre para o cérebro local: 7,6 GB livres "
            + "(sem contar ~2,4 GB do motor de voz), e ele precisa de ~8,0 GB. "
            + "Feche alguns apps e tente de novo."
        )
    )
    #expect(withoutVoice == .start)
    #expect(roomForBoth == .start)
  }

  @Test("less free memory than the voice engine holds is refused, not wrapped around")
  func deductionNeverUnderflows() {
    let verdict = policy.startVerdict(availableBytes: gib, voiceEngineResident: true)

    guard case .refuse(let reason) = verdict else {
      Issue.record("expected a refusal, got \(verdict)")
      return
    }
    #expect(reason.contains("0,0 GB livres"))
  }

  // MARK: - Launch command

  @Test("the argv binds loopback, caps the KV cache, and carries no API key")
  func argumentsAreLoopbackAndCapped() {
    let arguments = LocalBrainPolicy.makeArguments(runtime, model: model)

    #expect(
      arguments == [
        "--model", model,
        "--host", "127.0.0.1",
        "--port", "38480",
        "--max-kv-size", "32768",
        "--max-num-seqs", "1",
      ]
    )
    #expect(!arguments.contains("--api-key"))
    #expect(!arguments.contains("0.0.0.0"))
    #expect(!arguments.contains("--enable-thinking"))
  }

  @Test("the argv follows the profile's port, KV cap and model exactly")
  func argumentsFollowTheRuntime() {
    var other = runtime
    other.port = 39_001
    other.maxKVSize = 16_384

    let arguments = LocalBrainPolicy.makeArguments(other, model: "org/another-model")

    #expect(pair("--port", in: arguments) == "39001")
    #expect(pair("--max-kv-size", in: arguments) == "16384")
    #expect(pair("--model", in: arguments) == "org/another-model")
    #expect(pair("--host", in: arguments) == "127.0.0.1")
  }

  @Test("the environment is offline, carries Evie's key, and inherits nothing that could reconfigure the server")
  func environmentIsMinimalAndOffline() {
    let inherited = [
      "HOME": "/Users/someone",
      "USER": "someone",
      "LOGNAME": "someone",
      "TMPDIR": "/var/folders/xy/T/",
      "LANG": "pt_BR.UTF-8",
      "HF_HOME": "/Volumes/Models/hf",
      "PATH": "/opt/homebrew/bin:/usr/bin",
      "MLX_VLM_SERVER_API_KEY": "would-lock-evie-out",
      "MAX_KV_SIZE": "262144",
      "MLX_VLM_ENABLE_THINKING": "1",
      "PYTHONPATH": "/tmp/planted",
      "DYLD_INSERT_LIBRARIES": "/tmp/planted.dylib",
      "HF_HUB_OFFLINE": "0",
      "EVIE_MODEL_PROFILE": "mac-local",
    ]

    let key = LocalBrainKeyFile.makeKey()

    let environment = LocalBrainPolicy.makeEnvironment(inheriting: inherited, apiKey: key)

    #expect(
      environment == [
        "HOME": "/Users/someone",
        "USER": "someone",
        "LOGNAME": "someone",
        "TMPDIR": "/var/folders/xy/T/",
        "LANG": "pt_BR.UTF-8",
        "HF_HOME": "/Volumes/Models/hf",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HF_HUB_OFFLINE": "1",
        // Evie's own per-launch key, never the one her environment carried.
        "MLX_VLM_SERVER_API_KEY": key,
      ]
    )
  }

  @Test("the key reaches the server through its environment, never its argv")
  func keyIsNotInTheArguments() {
    let key = LocalBrainKeyFile.makeKey()

    let arguments = LocalBrainPolicy.makeArguments(runtime, model: model)
    let environment = LocalBrainPolicy.makeEnvironment(inheriting: [:], apiKey: key)

    #expect(environment["MLX_VLM_SERVER_API_KEY"] == key)
    #expect(!arguments.contains(key))
    #expect(!arguments.contains { $0.hasPrefix("--api") })
  }

  @Test("the environment is offline even when the caller has almost nothing")
  func environmentFromNothing() {
    let environment = LocalBrainPolicy.makeEnvironment(
      inheriting: [:], apiKey: LocalBrainKeyFile.makeKey())

    #expect(environment["HF_HUB_OFFLINE"] == "1")
    #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
  }

  // MARK: - Recognising the server

  @Test("a script server is recognised by its interpreter argv naming the executable and port")
  func recognisesTheScriptServer() {
    let arguments = [
      "/Users/someone/.local/share/uv/tools/mlx-vlm/bin/python",
      runtime.executable,
    ] + LocalBrainPolicy.makeArguments(runtime, model: model)

    #expect(LocalBrainPolicy.argumentsIdentifyServer(arguments, runtime: runtime))
  }

  @Test("a binary server is recognised by argv[0]")
  func recognisesABinaryServer() {
    let arguments = [runtime.executable] + LocalBrainPolicy.makeArguments(runtime, model: model)

    #expect(LocalBrainPolicy.argumentsIdentifyServer(arguments, runtime: runtime))
  }

  @Test("another program, another port, or a look-alike path is not the server")
  func rejectsLookAlikes() {
    let ours = LocalBrainPolicy.makeArguments(runtime, model: model)
    var otherPort = runtime
    otherPort.port = 38_481

    #expect(!LocalBrainPolicy.argumentsIdentifyServer(["/usr/bin/nc", "-l", "38480"], runtime: runtime))
    #expect(
      !LocalBrainPolicy.argumentsIdentifyServer(
        ["/usr/bin/python3", runtime.executable + "-evil"] + ours, runtime: runtime))
    #expect(
      !LocalBrainPolicy.argumentsIdentifyServer(
        ["/usr/bin/python3", runtime.executable] + LocalBrainPolicy.makeArguments(
          otherPort, model: model), runtime: runtime))
    #expect(
      !LocalBrainPolicy.argumentsIdentifyServer(
        ["/usr/bin/python3", "/elsewhere/serve.py", runtime.executable, "--port", "38480"],
        runtime: runtime))
    #expect(!LocalBrainPolicy.argumentsIdentifyServer([], runtime: runtime))
  }

  @Test("a server not bound to loopback by its last --host is not the server")
  func requiresLoopbackAsTheLastHost() {
    let program = ["/usr/bin/python3", runtime.executable]
    let base = ["--model", model, "--port", "38480"]

    // mlx-vlm's default is 0.0.0.0: no --host at all is every interface.
    #expect(!LocalBrainPolicy.argumentsIdentifyServer(program + base, runtime: runtime))
    // argparse keeps the last value, in every spelling it accepts.
    for later in [
      ["--host", "0.0.0.0"], ["--host=0.0.0.0"], ["--hos", "0.0.0.0"], ["--ho=::"],
      ["--host", "localhost"], ["--host", "192.168.1.20"],
    ] {
      #expect(
        !LocalBrainPolicy.argumentsIdentifyServer(
          program + base + ["--host", "127.0.0.1"] + later, runtime: runtime),
        "\(later)"
      )
    }
    #expect(
      LocalBrainPolicy.argumentsIdentifyServer(
        program + base + ["--host", "0.0.0.0", "--host=127.0.0.1"], runtime: runtime))
  }

  @Test("the port that counts is the last one the server was given")
  func usesTheLastPort() {
    let program = [runtime.executable, "--model", model, "--host", "127.0.0.1"]

    #expect(
      !LocalBrainPolicy.argumentsIdentifyServer(
        program + ["--port", "38480", "--port", "9999"], runtime: runtime))
    #expect(
      !LocalBrainPolicy.argumentsIdentifyServer(
        program + ["--port", "38480", "--por=9999"], runtime: runtime))
    #expect(LocalBrainPolicy.argumentsIdentifyServer(program + ["--port=38480"], runtime: runtime))
  }

  @Test("only listening sockets on 127.0.0.1 or ::1 count as loopback")
  func listenersMustBeLoopback() {
    #expect(LocalBrainPolicy.listensOnlyOnLoopback(["127.0.0.1"]))
    #expect(LocalBrainPolicy.listensOnlyOnLoopback(["::1", "127.0.0.1"]))
    // Still loading: nothing bound yet, nothing exposed.
    #expect(LocalBrainPolicy.listensOnlyOnLoopback([]))
    for exposed in ["0.0.0.0", "::", "192.168.1.20", "100.101.102.103", "127.0.0.2", "::ffff:127.0.0.1"] {
      #expect(!LocalBrainPolicy.listensOnlyOnLoopback(["127.0.0.1", exposed]), "\(exposed)")
    }
  }

  @Test("the interpreter is read from a script's first line")
  func interpreterFromShebang() {
    #expect(
      LocalBrainPolicy.interpreterPath(
        fromScriptHead: "#!/Users/someone/.local/share/uv/tools/mlx-vlm/bin/python\n# -*- coding")
        == "/Users/someone/.local/share/uv/tools/mlx-vlm/bin/python"
    )
    #expect(LocalBrainPolicy.interpreterPath(fromScriptHead: "#! /usr/bin/python3 -I\n") == "/usr/bin/python3")
    // An interpreter looked up on $PATH is not a path the pid's image can be
    // checked against, so it is no interpreter at all.
    #expect(LocalBrainPolicy.interpreterPath(fromScriptHead: "#!python3\n") == nil)
    #expect(LocalBrainPolicy.interpreterPath(fromScriptHead: "\u{7F}ELF…") == nil)
    #expect(LocalBrainPolicy.interpreterPath(fromScriptHead: "") == nil)
  }

  // MARK: - What the person reads

  @Test("each launch failure says what happened in Portuguese")
  func launchFailureCopy() {
    #expect(
      LocalBrainLaunchError.portHeld(port: 38_480).errorDescription
        == "A porta 38480 está ocupada por outro processo."
    )
    #expect(
      LocalBrainLaunchError.notInstalled(executable: "/x/mlx_vlm.server").errorDescription
        == "O cérebro do Mac não está instalado: falta /x/mlx_vlm.server."
    )
    #expect(
      LocalBrainLaunchError.lowMemory("Pouca memória.").errorDescription == "Pouca memória."
    )
    #expect(
      LocalBrainLaunchError.neverAnswered(seconds: 90).errorDescription
        == "O cérebro do Mac não respondeu em 90 s. O log fica em Application Support/Evie/Runtime/brain.log."
    )
    #expect(
      LocalBrainLaunchError.exitedDuringStartup.errorDescription
        == "O cérebro do Mac fechou enquanto acordava. O log fica em Application Support/Evie/Runtime/brain.log."
    )
    #expect(
      LocalBrainLaunchError.notOurServer(port: 38_480).errorDescription
        == "Quem respondeu na porta 38480 não é o cérebro que a Evie iniciou; ela não vai mandar nada para lá."
    )
    #expect(
      LocalBrainLaunchError.couldNotLaunch("sem permissão").errorDescription
        == "Não consegui acordar o cérebro do Mac: sem permissão"
    )
  }

  private func pair(_ flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }
}
