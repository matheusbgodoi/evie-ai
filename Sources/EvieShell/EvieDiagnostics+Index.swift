import EvieCore
import Foundation

extension EvieDiagnostics {
  /// Loads a cache file and reports what it cost to load it.
  ///
  /// This exists because the claim being made — that the index got smaller,
  /// faster and cheaper to read — is a claim about three numbers, and none of
  /// them can be had by reasoning about the code. It reads either format, so the
  /// old cache and the new one are measured by the same instrument on the same
  /// machine, which is the only way the comparison means anything.
  ///
  /// The fingerprint is what keeps the comparison honest in the other direction:
  /// a format that is smaller and faster because it lost vectors along the way
  /// would look excellent here. Two files holding the same numbers print the
  /// same fingerprint, bit for bit, including the sign of a zero and the payload
  /// of a NaN.
  static func indexCheck(path: String?, writingTo destination: String?) {
    let url = path.map { URL(fileURLWithPath: $0) } ?? EvieVaultIndex.defaultCacheURL
    print("arquivo: \(url.path)")

    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    guard let size else {
      print("não existe")
      return
    }
    print(String(format: "tamanho: %d bytes (%.1f MB)", size, Double(size) / 1_048_576))

    let before = ProcessCost.current()
    let started = Date()
    let document: EvieVaultIndexFile.Document
    let format: String
    do {
      document = try EvieVaultIndexFile.read(contentsOf: url)
      format = "binário v\(EvieVaultIndexFile.formatVersion)"
    } catch {
      // Falls back the same way the index itself does, so an old cache measures
      // through the same path it will really be read by once.
      guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
        let legacy = try? EvieVaultIndexFile.decodeLegacyJSON(data)
      else {
        print("recusado: \(error)")
        return
      }
      document = legacy
      format = "JSON antigo"
    }
    let elapsed = Date().timeIntervalSince(started)
    let after = ProcessCost.current()

    let present = document.vectors.compactMap { $0 }
    print("formato: \(format)")
    print("passagens: \(document.passages.count)")
    print("vetores: \(present.count) × \(present.first?.count ?? 0) dimensões")
    print("construído em: \(document.builtAt)")
    print(String(format: "leitura: %.0f ms", elapsed * 1000))
    print(
      String(
        format: "footprint antes: %.1f MB · depois: %.1f MB · pico do processo: %.1f MB",
        before.footprintBytes / 1_048_576,
        after.footprintBytes / 1_048_576,
        after.peakFootprintBytes / 1_048_576
      )
    )
    print(String(format: "impressão digital: %016llx", fingerprint(of: document)))

    // Writing the same index out again is how the two formats get compared
    // without touching the cache Evie is actually using: convert a copy, then
    // run this check against the result and read the same fingerprint back.
    guard let destination else {
      return
    }
    let output = URL(fileURLWithPath: destination)
    do {
      try EvieVaultIndexFile.write(document, to: output)
      let written =
        (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? nil
      print(
        String(
          format: "escrito em %@: %d bytes (%.1f MB)",
          output.path,
          written ?? 0,
          Double(written ?? 0) / 1_048_576
        )
      )
    } catch {
      print("não consegui escrever: \(error)")
    }
  }

  /// FNV-1a over every float's bit pattern and every passage's text.
  ///
  /// Bit patterns rather than values, because two vectors that differ only in a
  /// NaN payload or the sign of a zero are still two different vectors, and this
  /// is meant to catch a format that rounds things.
  private static func fingerprint(of document: EvieVaultIndexFile.Document) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    func mixByte(_ byte: UInt8) {
      hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    func mix(_ value: UInt64) {
      var remaining = value
      for _ in 0..<8 {
        mixByte(UInt8(truncatingIfNeeded: remaining))
        remaining >>= 8
      }
    }
    // The bytes of the text, not `hashValue`: Swift seeds string hashing per
    // process, so a fingerprint built on it would differ between two runs of
    // this very check and prove nothing.
    for passage in document.passages {
      for byte in passage.searchableText.utf8 {
        mixByte(byte)
      }
      for byte in passage.path.utf8 {
        mixByte(byte)
      }
    }
    for vector in document.vectors {
      guard let vector else {
        mix(0xffff_ffff_ffff_ffff)
        continue
      }
      for component in vector {
        mix(UInt64(component.bitPattern))
      }
    }
    return hash
  }
}
