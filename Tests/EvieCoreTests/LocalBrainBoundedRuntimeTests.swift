import Foundation
import Testing

@testable import EvieCore

@Suite("Bounded MLX runtime")
struct LocalBrainBoundedRuntimeTests {
  private let python = "/opt/evie/venv/bin/python3.12"
  private let model = "example/local-vision"
  private var runtime: LocalRuntime {
    LocalRuntime(
      launcher: .mlxVLM, executable: "/opt/evie/bin/mlx_vlm.server", port: 38_480,
      maxKVSize: 65_536, kvBits: 8, prefillStepSize: 512, metalCacheLimitMB: 256
    )
  }

  @Test("old profiles decode with unchanged launch semantics; new controls round-trip")
  func backwardCompatibleCodable() throws {
    let old = Data(
      #"{"launcher":"mlxVLM","executable":"/opt/server","port":38480,"max_kv_size":32768}"#.utf8
    )
    let decoded = try JSONDecoder().decode(LocalRuntime.self, from: old)
    #expect(decoded.kvBits == nil)
    #expect(decoded.prefillStepSize == nil)
    #expect(decoded.metalCacheLimitMB == nil)
    #expect(LocalBrainPolicy.makeArguments(decoded, model: model).first == "--model")
    let data = try JSONEncoder().encode(runtime)
    #expect(try JSONDecoder().decode(LocalRuntime.self, from: data) == runtime)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["metal_cache_limit_mb"] as? Int == 256)
    #expect(object["kv_bits"] as? Int == 8)
    #expect(object["prefill_step_size"] as? Int == 512)
  }

  @Test("bounded argv sets the public MLX cache limit before the unmodified upstream CLI")
  func boundedArguments() {
    let arguments = LocalBrainPolicy.makeArguments(runtime, model: model)
    #expect(
      Array(arguments.prefix(5)) == [
        "-I", "-c", LocalBrainPolicy.boundedBootstrap, runtime.executable, "268435456",
      ])
    #expect(Array(arguments.suffix(4)) == ["--kv-bits", "8", "--prefill-step-size", "512"])
    #expect(
      LocalBrainPolicy.argumentsServeProfile([python] + arguments, runtime: runtime, model: model))
  }

  @Test("the bounded launch uses only an absolute, argument-free Python shebang")
  func interpreterSelection() {
    #expect(LocalBrainPolicy.launchExecutable(runtime, scriptHead: "#!\(python)\n") == python)
    for head in ["#!/usr/bin/env python3\n", "#!python3\n", "#!/bin/sh\n", "#!\(python) -E\n", ""] {
      #expect(LocalBrainPolicy.launchExecutable(runtime, scriptHead: head) == nil)
    }
    var legacy = runtime
    legacy.metalCacheLimitMB = nil
    #expect(LocalBrainPolicy.launchExecutable(legacy, scriptHead: "") == runtime.executable)
  }

  @Test("only the exact bootstrap and a positive cache byte count identify the wrapper")
  func rejectsModifiedWrapper() {
    let ours = [python] + LocalBrainPolicy.makeArguments(runtime, model: model)
    for replacement in [
      LocalBrainPolicy.boundedBootstrap + ";print('changed')", "runpy.run_path('other')",
    ] {
      var other = ours
      other[3] = replacement
      #expect(!LocalBrainPolicy.argumentsIdentifyServer(other, runtime: runtime))
    }
    for invalid in ["0", "-1", "NaN", "999999999999999999999999"] {
      var other = ours
      other[5] = invalid
      #expect(!LocalBrainPolicy.argumentsIdentifyServer(other, runtime: runtime))
    }
    #expect(
      !LocalBrainPolicy.argumentsIdentifyServer(
        [python, "-E"] + Array(ours.dropFirst()), runtime: runtime))
    #expect(!LocalBrainPolicy.argumentsIdentifyServer(Array(ours.prefix(5)), runtime: runtime))
  }

  @Test("identity permits stopping an old server while reuse rejects changed profile controls")
  func identityIsNotReuse() {
    let ours = [python] + LocalBrainPolicy.makeArguments(runtime, model: model)
    var other = runtime
    other.maxKVSize = 32_768
    #expect(LocalBrainPolicy.argumentsIdentifyServer(ours, runtime: other))
    #expect(!LocalBrainPolicy.argumentsServeProfile(ours, runtime: other, model: model))
    other = runtime
    other.metalCacheLimitMB = 512
    #expect(LocalBrainPolicy.argumentsIdentifyServer(ours, runtime: other))
    #expect(!LocalBrainPolicy.argumentsServeProfile(ours, runtime: other, model: model))
    other = runtime
    other.kvBits = 4
    #expect(!LocalBrainPolicy.argumentsServeProfile(ours, runtime: other, model: model))
    other = runtime
    other.prefillStepSize = 1_024
    #expect(!LocalBrainPolicy.argumentsServeProfile(ours, runtime: other, model: model))
    #expect(!LocalBrainPolicy.argumentsServeProfile(ours, runtime: runtime, model: "other/model"))
    var legacy = runtime
    legacy.metalCacheLimitMB = nil
    let old = [runtime.executable] + LocalBrainPolicy.makeArguments(legacy, model: model)
    #expect(LocalBrainPolicy.argumentsIdentifyServer(old, runtime: runtime))
    #expect(!LocalBrainPolicy.argumentsServeProfile(old, runtime: runtime, model: model))
    #expect(LocalBrainPolicy.argumentsServeProfile(old, runtime: legacy, model: model))
  }

  @Test("last option values govern reuse and loopback identity even inside the wrapper")
  func lastOptionsGovernReuse() {
    let ours = [python] + LocalBrainPolicy.makeArguments(runtime, model: model)
    for changed in [
      ["--model=other/model"], ["--max-kv-size", "32768"], ["--max-num-seqs", "2"],
      ["--kv-bits=4"], ["--prefill-step-size", "1024"],
    ] {
      #expect(LocalBrainPolicy.argumentsIdentifyServer(ours + changed, runtime: runtime))
      #expect(
        !LocalBrainPolicy.argumentsServeProfile(ours + changed, runtime: runtime, model: model))
    }
    #expect(!LocalBrainPolicy.argumentsIdentifyServer(ours + ["--hos=0.0.0.0"], runtime: runtime))
    #expect(!LocalBrainPolicy.argumentsIdentifyServer(ours + ["--port=38481"], runtime: runtime))
  }

  @Test("invalid or overflowing memory settings cannot become a launch executable")
  func invalidSettings() {
    var invalid = runtime
    for limit in [0, -1, Int.max] {
      invalid.metalCacheLimitMB = limit
      #expect(invalid.metalCacheLimitBytes == nil)
      #expect(!invalid.hasValidMemoryConfiguration)
      #expect(LocalBrainPolicy.launchExecutable(invalid, scriptHead: "#!\(python)\n") == nil)
    }
    invalid = runtime
    invalid.kvBits = 5
    #expect(!invalid.hasValidMemoryConfiguration)
    invalid = runtime
    invalid.prefillStepSize = 0
    #expect(!invalid.hasValidMemoryConfiguration)
  }
}
