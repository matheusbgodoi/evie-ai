import CryptoKit
import EvieCore
import Foundation
import Security

/// Decides whether a downloaded copy of Evie was signed by whoever signed the
/// one already running.
///
/// This is the only thing standing between a release feed and code executing on
/// the machine, so what it does and does not catch was measured rather than
/// assumed. Against a bundle signed with this project's own certificate:
///
/// | what was done to it            | seal check | leaf hash |
/// | ------------------------------ | ---------- | --------- |
/// | `Info.plist` edited            | fails      | unchanged |
/// | a byte flipped in the binary   | fails      | unchanged |
/// | a file added to `Resources`    | fails      | unchanged |
/// | re-signed ad-hoc by an attacker| **passes** | **absent**|
/// | re-signed with another identity| **passes** | different |
///
/// Neither check is sufficient alone and that is the whole design: the seal
/// catches modification without re-signing, and the certificate catches
/// re-signing. Both must hold.
///
/// One thing it deliberately does not catch, because there is nothing to catch:
/// bytes appended past the end of the signed range of the executable. They are
/// outside every loaded segment and the load commands are sealed, so they are
/// inert.
enum EvieBundleSignature {
  enum SignatureError: LocalizedError, Equatable {
    case unreadable(OSStatus)
    case sealBroken(OSStatus)
    case unsigned
    case runningCopyUnsigned
    case differentSigner

    var errorDescription: String? {
      switch self {
      case .unreadable(let status):
        "Não consegui ler a assinatura do download (erro \(status))."
      case .sealBroken(let status):
        "O download foi alterado depois de assinado (erro \(status)). Não vou instalar."
      case .unsigned:
        "O download não está assinado. Não vou instalar."
      case .runningCopyUnsigned:
        "A Evie que está rodando não tem assinatura estável, então não há como "
          + "conferir um download. Rode Scripts/evie-app identity e reinstale."
      case .differentSigner:
        "O download foi assinado por outra pessoa. Não vou instalar."
      }
    }
  }

  /// The SHA-256 of the leaf signing certificate, or nil when the bundle is
  /// signed ad-hoc and therefore carries no certificate at all.
  ///
  /// Nil is a meaningful answer, not a failure: an ad-hoc signature is exactly
  /// what an attacker who re-signs a modified bundle ends up with, since they
  /// cannot produce this certificate's private key.
  static func leafCertificateHash(ofBundleAt url: URL) throws -> Data? {
    var code: SecStaticCode?
    let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
    guard created == errSecSuccess, let code else {
      throw SignatureError.unreadable(created)
    }

    // Default flags, measured above to reject an edited `Info.plist`, a flipped
    // byte, and an added resource.
    let valid = SecStaticCodeCheckValidity(code, [], nil)
    guard valid == errSecSuccess else {
      throw SignatureError.sealBroken(valid)
    }

    var information: CFDictionary?
    let copied = SecCodeCopySigningInformation(
      code,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &information
    )
    guard copied == errSecSuccess, let dictionary = information as? [String: Any] else {
      throw SignatureError.unreadable(copied)
    }
    guard
      let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
      let leaf = certificates.first
    else {
      return nil
    }
    return Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
  }

  /// Throws unless `candidate` was signed by whoever signed `running`.
  ///
  /// Fails closed in both directions. An unsigned download is refused, and so is
  /// a download checked against an unsigned running copy — with no certificate
  /// to compare against there is nothing to verify, and accepting anything would
  /// be worse than having no updater at all.
  static func verify(candidateAt candidate: URL, matchesSignerOf running: URL) throws {
    guard let expected = try leafCertificateHash(ofBundleAt: running) else {
      throw SignatureError.runningCopyUnsigned
    }
    guard let found = try leafCertificateHash(ofBundleAt: candidate) else {
      throw SignatureError.unsigned
    }
    // Constant time is not required — both values are already public — but the
    // comparison must be of the whole digest, which `==` on `Data` is.
    guard found == expected else {
      throw SignatureError.differentSigner
    }
  }
}
