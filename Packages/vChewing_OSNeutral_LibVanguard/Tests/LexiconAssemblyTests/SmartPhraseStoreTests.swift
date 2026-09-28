// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
@testable import LexiconAssembly
import Testing

// MARK: - SmartPhraseStoreTests

/// `SmartPhraseStore` 的行為規格。
///
/// 需求書對這一塊的要求是「**不要第一版就自動永久新增所有新詞**」，所以這裡多數
/// 測試釘的是「什麼情況下**不得**升格」，而不是「升格之後多好用」。
@Suite("SmartPhraseStoreTests", .serialized)
struct SmartPhraseStoreTests {
  // MARK: Internal

  /// 次數不足不得升格。這是「不自動新增所有新詞」的第一道閘。
  @Test("A phrase below the confirmation threshold is not promoted")
  func belowThresholdIsNotPromoted() {
    let store = LXAssembly.SmartPhraseStore()
    for _ in 0 ..< (LXAssembly.SmartPhraseStore.confirmationsRequired - 1) {
      store.observe(keyArray: Self.nameKeys, value: "王大明", ambiguity: 0, timestamp: Self.now)
    }
    #expect(store.promotedGrams(for: Self.nameKeys, timestamp: Self.now).isEmpty)
    #expect(!store.hasPromotedGrams(for: Self.nameKeys, timestamp: Self.now))
  }

  /// 次數足夠且歧義度低即升格。
  @Test("A repeatedly confirmed, low-ambiguity phrase is promoted")
  func repeatedLowAmbiguityIsPromoted() {
    let store = LXAssembly.SmartPhraseStore()
    for _ in 0 ..< LXAssembly.SmartPhraseStore.confirmationsRequired {
      store.observe(keyArray: Self.nameKeys, value: "王大明", ambiguity: 0, timestamp: Self.now)
    }
    let grams = store.promotedGrams(for: Self.nameKeys, timestamp: Self.now)
    #expect(grams.count == 1)
    #expect(grams.first?.current == "王大明")
  }

  /// **歧義度高就不學。**
  ///
  /// 辭典裡本來就有一堆同音詞的讀音，使用者手動組出某個組合多半只是這一次要這麼打，
  /// 不代表要把它記成一個詞。
  @Test("A high-ambiguity phrase is never promoted, however often it is confirmed")
  func highAmbiguityIsNeverPromoted() {
    let store = LXAssembly.SmartPhraseStore()
    let ambiguity = LXAssembly.SmartPhraseStore.ambiguityCeiling + 1
    for _ in 0 ..< 20 {
      store.observe(keyArray: Self.nameKeys, value: "王大明", ambiguity: ambiguity, timestamp: Self.now)
    }
    #expect(store.promotedGrams(for: Self.nameKeys, timestamp: Self.now).isEmpty)
  }

  /// 升格分數必須落在約定的帶內：贏得過逐字拆解，輸得給常用原廠詞條。
  @Test("A promoted phrase scores inside the agreed band")
  func promotedScoreStaysInsideTheBand() throws {
    let store = LXAssembly.SmartPhraseStore()
    for _ in 0 ..< 50 {
      store.observe(keyArray: Self.nameKeys, value: "王大明", ambiguity: 0, timestamp: Self.now)
    }
    let gram = try #require(store.promotedGrams(for: Self.nameKeys, timestamp: Self.now).first)
    let score = gram.probability
    #expect(score >= LXAssembly.SmartPhraseStore.scoreFloor)
    #expect(score <= LXAssembly.SmartPhraseStore.scoreCeiling)
    // 必須贏過「王(−5.154) ＋ 大名(−5.317)」這種逐字拆解（合計約 −10.5）。
    #expect(score > -10.0)
    // 必須輸給常用的三音節原廠詞條（「資料庫」是 −4.361）。
    #expect(score < -4.361)
  }

  /// 確認次數越多，分數越高（但仍受上限夾住）。
  @Test("More confirmations raise the score monotonically")
  func moreConfirmationsRaiseTheScore() {
    let sparse = LXAssembly.SmartPhraseStore()
    let dense = LXAssembly.SmartPhraseStore()
    for _ in 0 ..< LXAssembly.SmartPhraseStore.confirmationsRequired {
      sparse.observe(keyArray: Self.nameKeys, value: "王大明", ambiguity: 0, timestamp: Self.now)
    }
    for _ in 0 ..< 30 {
      dense.observe(keyArray: Self.nameKeys, value: "王大明", ambiguity: 0, timestamp: Self.now)
    }
    let sparseScore = sparse.promotedGrams(for: Self.nameKeys, timestamp: Self.now).first?.probability ?? 0
    let denseScore = dense.promotedGrams(for: Self.nameKeys, timestamp: Self.now).first?.probability ?? 0
    #expect(denseScore > sparseScore)
  }

  /// 單字與過長的串都不是「詞組」，一律不收。
  @Test("Runs outside the accepted length range are ignored")
  func lengthRangeIsEnforced() {
    let store = LXAssembly.SmartPhraseStore()
    for _ in 0 ..< 10 {
      store.observe(keyArray: ["ㄨㄤˊ"], value: "王", ambiguity: 0, timestamp: Self.now)
      store.observe(
        keyArray: Array(repeating: "ㄨㄤˊ", count: LXAssembly.SmartPhraseStore.lengthRange.upperBound + 1),
        value: String(repeating: "王", count: LXAssembly.SmartPhraseStore.lengthRange.upperBound + 1),
        ambiguity: 0,
        timestamp: Self.now
      )
    }
    #expect(store.count == 0)
  }

  /// 讀音段數與字數對不上的東西不得收進來。
  @Test("A value whose length disagrees with its reading is rejected")
  func mismatchedLengthIsRejected() {
    let store = LXAssembly.SmartPhraseStore()
    store.observe(keyArray: Self.nameKeys, value: "王大", ambiguity: 0, timestamp: Self.now)
    #expect(store.count == 0)
  }

  /// 久未使用者衰減；超過壽命即完全失效。
  @Test("A promoted phrase fades and eventually expires")
  func promotedPhrasesExpire() {
    let store = LXAssembly.SmartPhraseStore()
    for _ in 0 ..< 10 {
      store.observe(keyArray: Self.nameKeys, value: "王大明", ambiguity: 0, timestamp: Self.now)
    }
    let fresh = store.promotedGrams(for: Self.nameKeys, timestamp: Self.now).first?.probability ?? 0
    let midlife = Self.now + 45 * 86_400
    let aged = store.promotedGrams(for: Self.nameKeys, timestamp: midlife).first?.probability ?? 0
    #expect(aged < fresh, "衰減之後分數應當變低（\(fresh) → \(aged)）")

    let expired = Self.now + (LXAssembly.SmartPhraseStore.lifespanDays + 1) * 86_400
    #expect(store.promotedGrams(for: Self.nameKeys, timestamp: expired).isEmpty)
  }

  /// 清除必須是真的清除。
  @Test("Clearing removes every learned phrase")
  func clearingWipesEverything() {
    let store = LXAssembly.SmartPhraseStore()
    for _ in 0 ..< 10 {
      store.observe(keyArray: Self.nameKeys, value: "王大明", ambiguity: 0, timestamp: Self.now)
    }
    store.clearAll()
    #expect(store.count == 0)
    #expect(store.promotedGrams(for: Self.nameKeys, timestamp: Self.now).isEmpty)
  }

  /// 逐詞遺忘。
  @Test("Forgetting one phrase leaves the others alone")
  func forgettingIsScoped() {
    let store = LXAssembly.SmartPhraseStore()
    let otherKeys = ["ㄌㄧˇ", "ㄇㄟˇ", "ㄌㄧㄥˊ"]
    for _ in 0 ..< 10 {
      store.observe(keyArray: Self.nameKeys, value: "王大明", ambiguity: 0, timestamp: Self.now)
      store.observe(keyArray: otherKeys, value: "李美玲", ambiguity: 0, timestamp: Self.now)
    }
    store.forget(values: ["王大明"])
    #expect(store.promotedGrams(for: Self.nameKeys, timestamp: Self.now).isEmpty)
    #expect(!store.promotedGrams(for: otherKeys, timestamp: Self.now).isEmpty)
  }

  /// 存檔來回無損。
  @Test("An archive round-trips without loss")
  func archiveRoundTrips() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("SmartPhraseStoreTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("phrases.json")

    let original = LXAssembly.SmartPhraseStore(dataURL: url)
    for _ in 0 ..< 5 {
      original.observe(keyArray: Self.nameKeys, value: "王大明", ambiguity: 0, timestamp: Self.now)
    }
    original.saveToDisk()

    let reloaded = LXAssembly.SmartPhraseStore(dataURL: url)
    reloaded.loadFromDisk()
    #expect(reloaded.count == original.count)
    #expect(
      reloaded.promotedGrams(for: Self.nameKeys, timestamp: Self.now).first?.probability
        == original.promotedGrams(for: Self.nameKeys, timestamp: Self.now).first?.probability
    )
  }

  /// 版本不符的存檔整份丟棄。
  @Test("An archive with an unknown schemaVersion is discarded")
  func futureArchiveIsDiscarded() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("SmartPhraseStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("phrases.json")
    try #"{"schemaVersion":999,"savedAt":0,"candidates":[]}"#
      .write(to: url, atomically: true, encoding: .utf8)

    let store = LXAssembly.SmartPhraseStore(dataURL: url)
    store.loadFromDisk()
    #expect(store.count == 0)
  }

  // MARK: Private

  private static let now: Double = 1_800_000_000
  private static let nameKeys = ["ㄨㄤˊ", "ㄉㄚˋ", "ㄇㄧㄥˊ"]
}
