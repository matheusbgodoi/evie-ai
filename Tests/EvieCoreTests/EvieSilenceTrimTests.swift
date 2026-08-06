import Foundation
import Testing

@testable import EvieCore

@Suite("Evie silence trimming")
struct EvieSilenceTrimTests {
  private let rate = 24_000.0

  private func phrase(leadingSilence: Double, trailingSilence: Double, speech: Double) -> [Float] {
    let quiet = [Float](repeating: 0.0001, count: Int(leadingSilence * rate))
    let loud = (0..<Int(speech * rate)).map { _ in Float.random(in: -0.4...0.4) }
    let after = [Float](repeating: 0.0001, count: Int(trailingSilence * rate))
    return quiet + loud + after
  }

  /// The padding a model puts at each end of every phrase. Played back to back
  /// those add up, and a paragraph comes out haltingly.
  @Test("the silence at the ends is found")
  func findsTheEnds() throws {
    let samples = phrase(leadingSilence: 0.5, trailingSilence: 0.6, speech: 1.0)
    let range = try #require(EvieSilenceTrim.speechRange(in: samples, sampleRate: rate))

    let padding = Int(EvieSilenceTrim.keptSeconds * rate)
    #expect(abs(range.lowerBound - (Int(0.5 * rate) - padding)) < 200)
    #expect(range.count < samples.count)
    // Most of the 1.1 s of padding is gone; the 1 s of speech is not.
    #expect(Double(range.count) / rate < 1.2)
    #expect(Double(range.count) / rate > 1.0)
  }

  /// Cutting to the exact first loud sample clips the attack of a plosive and
  /// the phrase begins with a click.
  @Test("a little air is left at each end")
  func keepsSomeAir() throws {
    let samples = phrase(leadingSilence: 0.5, trailingSilence: 0.5, speech: 0.5)
    let range = try #require(EvieSilenceTrim.speechRange(in: samples, sampleRate: rate))

    #expect(range.lowerBound > 0)
    #expect(range.lowerBound < Int(0.5 * rate))
    #expect(range.upperBound > Int(1.0 * rate))
  }

  /// Silence inside a phrase is punctuation being spoken, not padding.
  @Test("a pause between clauses is left alone")
  func keepsInternalPauses() throws {
    let first = phrase(leadingSilence: 0, trailingSilence: 0, speech: 0.4)
    let gap = [Float](repeating: 0.0001, count: Int(0.3 * rate))
    let second = phrase(leadingSilence: 0, trailingSilence: 0, speech: 0.4)
    let samples = first + gap + second

    let range = try #require(EvieSilenceTrim.speechRange(in: samples, sampleRate: rate))

    #expect(Double(range.count) / rate > 1.0)
  }

  @Test("a phrase that is only silence is not worth playing")
  func rejectsSilence() {
    let quiet = [Float](repeating: 0.0001, count: 12_000)

    #expect(EvieSilenceTrim.speechRange(in: quiet, sampleRate: rate) == nil)
    #expect(EvieSilenceTrim.speechRange(in: [], sampleRate: rate) == nil)
  }

  @Test("a phrase with no padding is left whole")
  func leavesTightPhrasesAlone() throws {
    let samples = phrase(leadingSilence: 0, trailingSilence: 0, speech: 1.0)
    let range = try #require(EvieSilenceTrim.speechRange(in: samples, sampleRate: rate))

    #expect(range.lowerBound == 0)
    #expect(range.upperBound == samples.count)
  }
}
