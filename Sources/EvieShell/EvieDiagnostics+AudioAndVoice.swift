import AVFoundation
import AppKit
import EvieCore
import Foundation

/// The checks that touch the microphone, the speech recogniser, or a voice.
///
/// Several of these write their result to `~/Library/Logs/Evie` rather than only
/// printing it, because a bundle launched by Launch Services has no standard
/// output anyone can read, and the microphone ones can only be run that way.
extension EvieDiagnostics {
  static func audioCheck() {
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "(nenhum — não empacotado)"
    let usage =
      Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
    print("bundle: \(bundleIdentifier)")
    print("bundlePath: \(Bundle.main.bundlePath)")
    print("NSMicrophoneUsageDescription: \(usage ?? "(ausente)")")
    print("permissão do microfone: \(EvieAudioCapture.currentPermission())")
    print("pode capturar: \(EvieAudioCapture.isBundled ? "identidade OK" : "sem identidade")")
  }

  static func speechCheck() async {
    if #available(macOS 26, *) {
      let locale = Locale(identifier: "pt-BR")
      let availability = await EvieSpeechTranscription.availability(for: locale)
      print("reconhecimento disponível: \(EvieSpeechTranscription.isSupported)")
      print("pt-BR: \(availability) — \(availability.message)")
    } else {
      print("Este macOS não tem o reconhecimento de fala do sistema.")
    }
  }

  static func voiceEngineCheck() async {
    print("instalado: \(EvieVoiceEngineLauncher.isInstalled)")
    print("porta \(EvieOmniVoiceClient.defaultPort) ocupada: \(EvieVoiceEngineLauncher.isPortBound())")

    let client = EvieOmniVoiceClient()
    print("já no ar: \(await client.isHealthy())")

    let start = Date()
    do {
      try await EvieVoiceEngineLauncher().ensureRunning(client: client)
      let elapsed = Date().timeIntervalSince(start)
      let profiles = await client.voices()
      print(String(format: "RESULTADO: no ar em %.2f s, %d perfil(is)", elapsed, profiles.count))
      for profile in profiles {
        print("  \(profile.name) [\(profile.id)]")
      }
    } catch {
      print("RESULTADO: falhou — \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
      print("log: \(EvieVoiceEngineLauncher.logURL.path)")
    }
  }

  static func voicesCheck(audioURL: URL) async {
    let engine = EvieOmniVoiceClient()

    guard await engine.isHealthy() else {
      print("motor de voz fora do ar — rode Scripts/evie-voice start")
      return
    }

    let before = await engine.voices()
    print("vozes treinadas antes: \(before.map(\.name))")
    print("vozes do sistema: \(EvieSpeechOutput.availableVoices().count)")

    let identifier: String
    do {
      identifier = try await engine.createProfile(
        name: "TESTE-descartavel",
        audioURL: audioURL,
        referenceText: "Esta é uma gravação de referência para testar o treino de voz da Evie."
      )
      print("TREINAR: ok, id = \(identifier)")
    } catch {
      print("TREINAR falhou: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
      return
    }

    let during = await engine.voices()
    print("aparece na lista: \(during.contains { $0.id == identifier })")

    // And it can actually speak, which is the only thing that makes a trained
    // voice worth having.
    do {
      let buffer = try await engine.synthesise("Pronta.", profileID: identifier)
      let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
      print(String(format: "FALAR: ok, %.2f s de áudio", seconds))
    } catch {
      print("FALAR falhou: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }

    do {
      try await engine.deleteProfile(id: identifier)
      print("APAGAR: ok")
    } catch {
      print("APAGAR falhou: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }

    let after = await engine.voices()
    print("vozes depois: \(after.map(\.name))")
    print("suas vozes intactas: \(before.map(\.id).sorted() == after.map(\.id).sorted())")
  }

  static func speakCheck() async {
    var report: [String] = []
    let voices = EvieSpeechOutput.availableVoices()
    report.append("vozes pt-BR instaladas: \(voices.count)")
    for voice in voices.prefix(4) {
      report.append("  \(voice.displayName)  [\(voice.id)]")
    }

    // The natural Siri voices appear in the system list. Whether a third-party
    // app can actually instantiate one is a different question, and the answer
    // decides how good Evie can sound without a cloned voice.
    for identifier in ["com.apple.siri.natural.Sandra", "com.apple.siri.natural.Nando"] {
      let resolved = AVSpeechSynthesisVoice(identifier: identifier) != nil
      report.append("\(identifier): \(resolved ? "utilizável" : "INDISPONÍVEL para este app")")
    }

    let output = EvieSpeechOutput()
    var peak: CGFloat = 0
    var updates = 0
    var started = false
    output.onStarted = { started = true }
    output.onLevels = { levels in
      peak = max(peak, levels.max() ?? 0)
      updates += 1
    }

    let start = Date()
    output.speak(
      EvieRichText(
        "Oi, Matheus. Agora eu falo. Interrompa quando quiser, é só falar por cima."
      ),
      using: .system(identifier: voices.first?.id),
      rate: 0.5
    )
    while !started, Date().timeIntervalSince(start) < 20 {
      try? await Task.sleep(for: .milliseconds(50))
    }
    report.append(
      String(
        format: "áudio começou depois de %.2f s: %@",
        Date().timeIntervalSince(start), started ? "sim" : "NÃO"))

    while output.isSpeaking, Date().timeIntervalSince(start) < 40 {
      try? await Task.sleep(for: .milliseconds(100))
    }
    report.append(String(format: "duração: %.2f s", Date().timeIntervalSince(start)))
    report.append(String(format: "pico de nível de saída: %.3f", Double(peak)))
    report.append("amostras de nível publicadas: \(updates)")
    report.append(
      peak > 0.05
        ? "RESULTADO (voz do sistema): falou, e o anel tem nível real."
        : "RESULTADO (voz do sistema): terminou sem nível audível — investigar."
    )

    // Now the cloned engine, if it is running.
    let cloned = EvieOmniVoiceClient()
    report.append("")
    if await cloned.isHealthy() {
      let profiles = await cloned.voices()
      report.append("motor de voz clonada: no ar, \(profiles.count) perfil(is)")
      for profile in profiles {
        report.append("  \(profile.name) [\(profile.id)] \(profile.language)")
      }
      // Prefer a profile whose reference text is stored: without it the backend
      // transcribes the reference with Whisper on first use, which is a one-time
      // cost measured at over thirty seconds.
      let chosen =
        profiles.first { $0.name.localizedCaseInsensitiveContains("matheus") }
        ?? profiles.first
      if let profile = chosen {
        var clonedPeak: CGFloat = 0
        var clonedStarted = false
        let output = EvieSpeechOutput()
        output.onLevels = { levels in clonedPeak = max(clonedPeak, levels.max() ?? 0) }
        output.onStarted = { clonedStarted = true }
        let clonedStart = Date()
        output.speak(
          EvieRichText("Oi Matheus. Agora sou eu falando com a sua voz clonada."),
          using: .cloned(profileID: profile.id),
          rate: 0.5
        )
        while !clonedStarted, Date().timeIntervalSince(clonedStart) < 90 {
          try? await Task.sleep(for: .milliseconds(100))
        }
        report.append(
          String(
            format: "primeiro áudio clonado em %.2f s: %@",
            Date().timeIntervalSince(clonedStart), clonedStarted ? "sim" : "NÃO"))
        while output.isSpeaking, Date().timeIntervalSince(clonedStart) < 120 {
          try? await Task.sleep(for: .milliseconds(100))
        }
        report.append(String(format: "pico de nível clonado: %.3f", Double(clonedPeak)))
      }
    } else {
      report.append("motor de voz clonada: desligado (Scripts/evie-voice start)")
    }

    writeLog(report, named: "speak-check.txt")
  }

  /// Result goes to a file because a bundle launched by Launch Services has no
  /// standard output anyone can read.
  static func voiceCheck() async {
    var report = ["bundle: \(Bundle.main.bundleIdentifier ?? "(nenhum)")"]
    report.append("permissão antes de pedir: \(EvieAudioCapture.currentPermission())")

    let capture = EvieAudioCapture()
    var peak: CGFloat = 0
    // Every published level, so a gate that misbehaves can be read rather than
    // guessed at. Theorising about this cost two wrong fixes.
    var trace: [CGFloat] = []
    capture.onLevels = { levels in
      peak = max(peak, levels.max() ?? 0)
      if let latest = levels.last {
        trace.append(latest)
      }
    }

    do {
      let format = try await capture.prepareInputFormat()
      report.append("permissão depois de pedir: \(EvieAudioCapture.currentPermission())")
      report.append(
        "formato de entrada: \(Int(format.sampleRate)) Hz, \(format.channelCount) canal(is)"
      )
      // The gate's decisions are recorded, not just the peak. A capture that
      // reaches a healthy level and still never ends a turn is exactly the bug
      // the user hit, and the peak alone cannot tell the two apart.
      var ended = false
      var endedAfter: Double = 0
      let started = Date()
      capture.detectsEndOfSpeech = true
      capture.onSpeechStarted = {
        report.append(String(format: "  fala detectada em %.1f s", Date().timeIntervalSince(started)))
      }
      capture.onEndOfSpeech = {
        ended = true
        endedAfter = Date().timeIntervalSince(started)
      }

      try await capture.start()
      report.append("microfone aberto: sim")
      report.append("FALE ALGO AGORA, depois fique em silêncio.")
      for _ in 0..<40 where !ended {
        try? await Task.sleep(for: .milliseconds(250))
      }
      report.append(String(format: "pico de nível: %.3f", Double(peak)))
      report.append(String(format: "piso de ruído aprendido: %.3f", Double(capture.noiseFloor)))
      report.append(String(format: "limiar de fala: %.3f", Double(capture.speechThreshold)))
      report.append(
        ended
          ? String(format: "FIM DE FALA: detectado em %.1f s", endedAfter)
          : "FIM DE FALA: NÃO detectado em 10 s"
      )
      report.append("")
      report.append("níveis publicados (um a cada 30 ms):")
      for chunk in stride(from: 0, to: trace.count, by: 10) {
        let slice = trace[chunk..<min(chunk + 10, trace.count)]
        let stamp = String(format: "%5.1fs", Double(chunk) * 0.03)
        report.append(
          "  \(stamp)  " + slice.map { String(format: "%.3f", Double($0)) }.joined(separator: " ")
        )
      }
      capture.stop()
      report.append("microfone fechado: sim")
      report.append("RESULTADO: o caminho do áudio rodou inteiro sem derrubar o processo.")
    } catch {
      report.append(
        "FALHA: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
      )
    }

    writeLog(report, named: "voice-check.txt")
  }

  /// Measures what arming the wake listener costs, against doing nothing at all.
  ///
  /// The idle phase is not padding. Every process pays something merely for being
  /// alive, and without that baseline the armed figure includes the cost of the
  /// runloop and reads higher than the feature really is.
  static func wakeCostCheck(seconds: Double) async {
    setvbuf(stdout, nil, _IOLBF, 0)
    var report: [String] = []
    func say(_ lines: [String]) {
      for line in lines {
        print(line)
        report.append(line)
      }
    }

    say(["janela de medição: \(Int(seconds)) s por fase"])
    say(["permissão do microfone: \(EvieAudioCapture.currentPermission())"])
    if let format = try? await EvieAudioCapture().prepareInputFormat() {
      say([
        "formato de entrada: \(Int(format.sampleRate)) Hz, \(format.channelCount) canal(is)"
      ])
    }
    say(await measureCost(label: "parada (nada armado)", seconds: seconds))

    guard EvieWakeListener().isSupported, #available(macOS 26, *) else {
      say(["FALHA: este Mac não faz reconhecimento de fala, não há o que medir."])
      writeLog(report, named: "wake-cost-check.txt")
      return
    }

    // Both arrangements, back to back, in the same room. Measuring the gated
    // version against a number taken yesterday would compare rooms, not code.
    // The order is a knob because the second phase runs against warm daemons and
    // that alone could look like a saving. Run it both ways and the bias shows.
    let order = CommandLine.arguments.contains("--gated-first") ? [true, false] : [false, true]
    for gated in order {
      let listener = EvieWakeListener()
      listener.gatesRecogniser = gated
      let label = gated ? "armada com portão" : "armada sem portão (como era)"
      say(
        await measureCost(label: label, seconds: seconds) {
          await listener.arm(phrases: EvieVoicePreferences.defaultWakePhrase)
        }
      )
      say(["  armada de fato: \(listener.isArmed)"])
      if let failure = listener.failure {
        say(["  falha ao armar: \(failure)"])
      }
      if let stats = listener.gateStatistics, stats.buffers > 0 {
        say([
          String(
            format:
              "  portão aberto em %d de %d buffers (%.1f%%), %d aberturas, "
              + "piso %.3f, limiar %.3f, pico %.3f",
            stats.fed, stats.buffers, Double(stats.fed) / Double(stats.buffers) * 100,
            stats.openings, Double(stats.floor), Double(stats.openThreshold),
            Double(stats.peakLevel)
          ),
          String(format: "  cada buffer dura %.0f ms", stats.bufferSeconds * 1_000),
        ])
        // The distribution of the levels, because the thresholds are supposed to
        // come from what this microphone reports and not from a guess about it.
        let sorted = stats.levels.sorted()
        if !sorted.isEmpty {
          let at = { (fraction: Double) -> Double in
            Double(sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))])
          }
          say([
            String(
              format: "  níveis: p10 %.3f  p50 %.3f  p90 %.3f  p99 %.3f  máx %.3f",
              at(0.1), at(0.5), at(0.9), at(0.99), at(1)
            )
          ])
          // The whole trace goes to the file, and only to the file. Tuning a
          // threshold against a summary is how the first version ended up with a
          // gate that never closed; replaying the levels the microphone really
          // produced is how it was fixed.
          report.append(
            "  trace: " + stats.levels.map { String(format: "%.3f", Double($0)) }
              .joined(separator: " ")
          )
        }
      }
      say(["  último trecho reconhecido: \"\(listener.lastHeard)\""])
      listener.disarm()
      // The microphone and the recogniser both take a moment to actually go
      // away; measuring the next phase over that tail would charge it to the
      // wrong arrangement.
      try? await Task.sleep(for: .seconds(3))
    }

    writeLog(report, named: "wake-cost-check.txt")
  }

  /// What this process has consumed so far, as the kernel accounts it.
  ///
  /// `powermetrics` reports energy in watts but needs sudo, and a diagnostic that
  /// needs a password is a diagnostic nobody runs. `proc_pid_rusage` needs
  /// nothing. Energy is deliberately not reported here: `ri_billed_energy` was
  /// read on this Mac and comes back exactly 0 for an unentitled process, and
  /// printing a zero as if it were a measurement is worse than printing nothing.
  /// Cycles are what the kernel really counts, and between two versions of the
  /// same code they are the closest honest stand-in for energy.
  struct ProcessCost {
    var cpuSeconds: Double
    var cycles: Double
    var instructions: Double
    var footprintBytes: Double
    /// The highest the footprint has been since this process started, which the
    /// kernel keeps for us. Sampling before and after a piece of work cannot see
    /// a spike that has already been released by the time the second sample is
    /// taken, and a spike released quickly is exactly what a decoder produces.
    var peakFootprintBytes: Double

    /// `ri_user_time` is in mach ticks, not nanoseconds, and the difference is
    /// not cosmetic: on this Mac the timebase is 125/3, so reading the raw value
    /// as nanoseconds reports 2.4% of the CPU that was actually spent. Verified
    /// against a busy loop of a known second — raw 23_968_445 ticks, 0.999 s
    /// after conversion.
    static let ticksToSeconds: Double = {
      var timebase = mach_timebase_info_data_t()
      mach_timebase_info(&timebase)
      guard timebase.denom > 0 else {
        return 1e-9
      }
      return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    static func current() -> ProcessCost {
      var info = rusage_info_v4()
      let read = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
          proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
        }
      }
      guard read == 0 else {
        return ProcessCost(
          cpuSeconds: 0,
          cycles: 0,
          instructions: 0,
          footprintBytes: 0,
          peakFootprintBytes: 0
        )
      }
      return ProcessCost(
        cpuSeconds: Double(info.ri_user_time + info.ri_system_time) * ticksToSeconds,
        cycles: Double(info.ri_cycles),
        instructions: Double(info.ri_instructions),
        footprintBytes: Double(info.ri_phys_footprint),
        peakFootprintBytes: Double(info.ri_lifetime_max_phys_footprint)
      )
    }
  }

  /// Runs `body` for `seconds` and reports what the process spent doing it.
  ///
  /// Wall time is measured rather than assumed: `Task.sleep` is a floor, not a
  /// promise, and dividing by the requested duration would inflate every figure
  /// by however much it overslept.
  static func measureCost(
    label: String,
    seconds: Double,
    body: () async -> Void = {}
  ) async -> [String] {
    let before = ProcessCost.current()
    let started = Date()
    await body()
    try? await Task.sleep(for: .seconds(seconds))
    let elapsed = Date().timeIntervalSince(started)
    let after = ProcessCost.current()

    let cpu = after.cpuSeconds - before.cpuSeconds
    let cycles = after.cycles - before.cycles
    let instructions = after.instructions - before.instructions
    return [
      String(
        format: "%@: %.2f%% de CPU (%.3f s de CPU em %.1f s), %.2f G ciclos, %.2f G instruções",
        label, cpu / elapsed * 100, cpu, elapsed, cycles / 1e9, instructions / 1e9
      ),
      String(format: "  memória do processo ao fim: %.0f MB", after.footprintBytes / 1_048_576),
    ]
  }
}
