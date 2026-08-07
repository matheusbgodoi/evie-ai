import Foundation
import IOKit
import IOKit.ps

extension EvieDiagnostics {
  /// What this Mac will say about power and heat, sampled over a window.
  ///
  /// The honest framing first: `powermetrics` is the tool that reports watts per
  /// process, and it needs sudo. A diagnostic that needs a password is a
  /// diagnostic nobody runs, so this reports only what an unprivileged process can
  /// read, and says out loud which numbers this Mac refuses to give.
  ///
  /// Three things it can read, none of which needed elevation:
  ///
  /// - **GPU utilisation**, from the `PerformanceStatistics` dictionary the
  ///   accelerator publishes in the IO registry. This matters more than CPU for
  ///   local inference, because decoding runs on the GPU; a check that watched
  ///   only `%CPU` would report a fraction of the work and call it the whole cost.
  /// - **Thermal state**, from `ProcessInfo`, which is macOS's own summary of
  ///   whether the machine is being asked for more than it can cool.
  /// - **Instantaneous battery draw**, as amperage times voltage, but only while
  ///   the machine is actually on battery. On AC the battery reports zero
  ///   amperage, which is not a measurement of nothing — it is the absence of a
  ///   measurement, and it is reported as such rather than printed as "0 W".
  ///
  /// Run it once while nothing is happening and once while a question is being
  /// answered; the difference between the two windows is what a question costs.
  static func energyCheck(seconds: Double) async {
    setvbuf(stdout, nil, _IOLBF, 0)
    var report: [String] = []
    func say(_ line: String) {
      print(line)
      report.append(line)
    }

    say("máquina: \(machineDescription())")
    say("estado térmico ao começar: \(thermalStateName())")
    say("modo de baixo consumo: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "ligado" : "desligado")")
    say(powerSourceLine())
    say("janela de medição: \(Int(seconds)) s, amostrando a cada segundo")

    var utilisations: [Int] = []
    var thermalStates: Set<String> = [thermalStateName()]
    let started = Date()
    while Date().timeIntervalSince(started) < seconds {
      if let utilisation = gpuUtilisation() {
        utilisations.append(utilisation)
      }
      thermalStates.insert(thermalStateName())
      try? await Task.sleep(for: .seconds(1))
    }

    if utilisations.isEmpty {
      say("GPU: este Mac não publicou 'Device Utilization %' — nada a relatar")
    } else {
      let mean = Double(utilisations.reduce(0, +)) / Double(utilisations.count)
      say(
        String(
          format: "GPU: mínimo %d%%, média %.1f%%, pico %d%% em %d amostras",
          utilisations.min() ?? 0, mean, utilisations.max() ?? 0, utilisations.count
        )
      )
      say("  (a GPU é compartilhada; outros aplicativos também aparecem nesse número)")
    }
    say("estados térmicos vistos na janela: \(thermalStates.sorted().joined(separator: ", "))")
    say(powerSourceLine())

    // Said every time, on purpose. A resource report with a silence where the
    // watts should be reads as if nobody looked.
    say("")
    say("o que esta máquina não informa sem privilégios:")
    say("  - watts por processo (só `sudo powermetrics`)")
    say("  - rotação das ventoinhas (precisa de um auxiliar privilegiado)")
    say("  - temperatura dos sensores em graus (idem)")
    say("  - watts totais enquanto estiver na tomada: a bateria informa 0 A")

    writeLog(report, named: "energy-check.txt")
  }

  /// Model, chip, cores, and memory, so a measurement is never separated from the
  /// machine that produced it.
  private static func machineDescription() -> String {
    let info = ProcessInfo.processInfo
    let memory = Double(info.physicalMemory) / 1_073_741_824
    return String(
      format: "%@, %@, %d núcleos, %.0f GB, macOS %@",
      sysctlString("hw.model") ?? "modelo desconhecido",
      sysctlString("machdep.cpu.brand_string") ?? "chip desconhecido",
      info.processorCount,
      memory,
      info.operatingSystemVersionString
    )
  }

  private static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var value = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    // `sysctl` writes a C string, so the buffer ends in a null that would
    // otherwise become a character in the middle of a printed line.
    return String(decoding: value.prefix(while: { $0 != 0 }), as: UTF8.self)
  }

  private static func thermalStateName() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "moderado"
    case .serious: return "sério"
    case .critical: return "crítico"
    @unknown default: return "desconhecido"
    }
  }

  /// Where the power is coming from, and the draw when the battery can report it.
  ///
  /// `Amperage` is unsigned in the registry but is a discharge current expressed
  /// as a two's-complement negative while discharging, so it is read as a signed
  /// 64-bit value and its magnitude taken. Zero means the battery is neither
  /// charging nor discharging, which is what a machine on AC reports, and in that
  /// case there is no draw figure to give.
  private static func powerSourceLine() -> String {
    guard let battery = registryProperties(ofClass: "AppleSmartBattery") else {
      return "energia: este Mac não publicou uma bateria"
    }
    let external = (battery["ExternalConnected"] as? Bool) ?? false
    let charge = (battery["CurrentCapacity"] as? Int).map { "\($0)%" } ?? "carga desconhecida"
    let amperage = (battery["Amperage"] as? Int) ?? 0
    let millivolts = (battery["Voltage"] as? Int) ?? 0
    let source = external ? "tomada" : "bateria"

    guard amperage != 0, millivolts > 0 else {
      return "energia: \(source), bateria em \(charge); "
        + "corrente 0 A, então não há watts a medir agora"
    }
    let watts = Double(abs(amperage)) / 1_000 * Double(millivolts) / 1_000
    return String(
      format: "energia: %@, bateria em %@; %.1f W (%d mA × %d mV)",
      source, charge, watts, abs(amperage), millivolts
    )
  }

  /// How busy the GPU is, as the accelerator itself reports it.
  private static func gpuUtilisation() -> Int? {
    guard let accelerator = registryProperties(ofClass: "IOAccelerator"),
      let statistics = accelerator["PerformanceStatistics"] as? [String: Any]
    else {
      return nil
    }
    return statistics["Device Utilization %"] as? Int
  }

  /// Every property of the first service matching an IO registry class.
  private static func registryProperties(ofClass name: String) -> [String: Any]? {
    guard let matching = IOServiceMatching(name) else { return nil }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }

    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
      let properties = unmanaged?.takeRetainedValue() as? [String: Any]
    else {
      return nil
    }
    return properties
  }
}
