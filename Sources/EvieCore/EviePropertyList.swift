import Foundation

/// A property list as a value, so building one can be tested without a disk.
///
/// `PropertyListSerialization` speaks `Any`, which is neither `Sendable` nor
/// comparable in a test — asserting on an `NSDictionary` means casting every
/// value back out and guessing at its bridged type. This is the same data as an
/// ordinary Swift enum: a generator returns one, a test reads it, and only the
/// last step hands it to Foundation to be written out.
///
/// Only the four kinds a `launchd` job needs. Dates and binary data would each
/// need a bridging rule of their own, and no job here has one.
public enum EviePropertyList: Equatable, Sendable {
  case string(String)
  case integer(Int)
  case boolean(Bool)
  indirect case array([EviePropertyList])
  indirect case dictionary([String: EviePropertyList])

  /// The value at a key, when this is a dictionary. For reading a generated
  /// plist in a test without a chain of pattern matches.
  public subscript(key: String) -> EviePropertyList? {
    guard case .dictionary(let entries) = self else {
      return nil
    }
    return entries[key]
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var integerValue: Int? {
    guard case .integer(let value) = self else { return nil }
    return value
  }

  public var booleanValue: Bool? {
    guard case .boolean(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [EviePropertyList]? {
    guard case .array(let values) = self else { return nil }
    return values
  }

  /// The Foundation object graph `PropertyListSerialization` wants.
  public var foundationObject: Any {
    switch self {
    case .string(let value):
      value as NSString
    case .integer(let value):
      value as NSNumber
    case .boolean(let value):
      value as NSNumber
    case .array(let values):
      values.map(\.foundationObject) as NSArray
    case .dictionary(let entries):
      entries.mapValues(\.foundationObject) as NSDictionary
    }
  }

  /// The XML a `.plist` file contains.
  ///
  /// Serialised by Foundation rather than by a template of our own. A plist is
  /// XML, and every string in one of these — a folder someone named `Notas & Cia`,
  /// a schedule called `"urgente"` — is user input that would have to be escaped
  /// by hand otherwise. Apple's serialiser already knows the rules; writing them
  /// again is how a folder with an ampersand in its name produces a file
  /// `launchctl` refuses to read.
  public func xmlData() throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: foundationObject,
      format: .xml,
      options: 0
    )
  }

  /// Reads one back, for checking that what was written survives the round trip.
  public static func parse(_ data: Data) throws -> EviePropertyList {
    let object = try PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    )
    guard let value = EviePropertyList(foundationObject: object) else {
      throw ParseFailure.unsupportedValue
    }
    return value
  }

  public enum ParseFailure: Error, Equatable, Sendable {
    case unsupportedValue
  }

  /// Bridged back by hand, because `Bool` and `Int` arrive from Foundation as
  /// the same `NSNumber` and only the encoded type tells them apart. Reading a
  /// `<true/>` back as `1` would make a round-trip test pass on a plist that
  /// says something else.
  private init?(foundationObject object: Any) {
    if let number = object as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .boolean(number.boolValue)
      } else {
        self = .integer(number.intValue)
      }
      return
    }
    if let value = object as? String {
      self = .string(value)
      return
    }
    if let values = object as? [Any] {
      let parsed = values.compactMap { EviePropertyList(foundationObject: $0) }
      guard parsed.count == values.count else {
        return nil
      }
      self = .array(parsed)
      return
    }
    if let entries = object as? [String: Any] {
      var parsed: [String: EviePropertyList] = [:]
      for (key, value) in entries {
        guard let item = EviePropertyList(foundationObject: value) else {
          return nil
        }
        parsed[key] = item
      }
      self = .dictionary(parsed)
      return
    }
    return nil
  }
}
