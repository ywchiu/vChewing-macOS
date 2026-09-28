// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
@testable import LexiconAssembly
import Testing

// MARK: - SmartPreferenceStoreTests

/// `SmartPreferenceStore` 的行為規格。
///
/// 這些測試釘住的是需求書裡那幾條「不能發生」的事——單次選字不得永久生效、
/// 一次修正不得把舊詞打死、A app 的學習不得洩進 B app、久未使用必須衰減。
/// 這幾條比「修正學習有沒有用」更重要：前者壞掉是使用者自己修不好的。
@Suite("SmartPreferenceStoreTests", .serialized)
struct SmartPreferenceStoreTests {
  // MARK: Internal

  /// 單次選字的信心度跨不過門檻，故不得產生任何加權。
  ///
  /// 這就是「避免模型只因為使用者偶爾選過一次特殊詞，就永久污染一般輸入」那條要求。
  @Test("A single pick stays below the confidence threshold")
  func singlePickIsInert() {
    let store = LXAssembly.SmartPreferenceStore()
    store.note(
      reading: "ㄏㄢˊ-ㄕˋ", candidate: "韓式", previous: "正宗", anterior: "",
      appCategory: .chat, displaced: nil, timestamp: Self.now
    )
    let adjustments = store.adjustments(previous: "正宗", appCategory: .chat, timestamp: Self.now)
    #expect(
      (adjustments["韓式"] ?? 0) == 0,
      "單次選字不得生效，實得 \(adjustments["韓式"] ?? 0)"
    )
  }

  /// 重複的修正要能快速跨過門檻並生效。
  @Test("Repeated corrections promote the accepted candidate")
  func repeatedCorrectionsPromote() {
    let store = LXAssembly.SmartPreferenceStore()
    for _ in 0 ..< 2 {
      store.note(
        reading: "ㄏㄢˊ-ㄕˋ", candidate: "韓式", previous: "正宗", anterior: "",
        appCategory: .chat, displaced: "函式", timestamp: Self.now
      )
    }
    let adjustments = store.adjustments(previous: "正宗", appCategory: .chat, timestamp: Self.now)
    #expect((adjustments["韓式"] ?? 0) > 0, "兩次修正之後應當生效")
    #expect((adjustments["韓式"] ?? 0) <= LXAssembly.SmartPreferenceStore.promotionCap)
  }

  /// 被換掉的那個詞只能被「輕輕壓低」，不得被打死。
  ///
  /// 上限刻意設得比正向加權小得多：退掉一個詞的意思是「這次不要它」，
  /// 不是「永遠別再給我」。
  @Test("The displaced candidate is demoted gently and never beyond the cap")
  func demotionIsBounded() {
    let store = LXAssembly.SmartPreferenceStore()
    for _ in 0 ..< 20 {
      store.note(
        reading: "ㄏㄢˊ-ㄕˋ", candidate: "韓式", previous: "正宗", anterior: "",
        appCategory: .chat, displaced: "函式", timestamp: Self.now
      )
    }
    let adjustments = store.adjustments(previous: "正宗", appCategory: .chat, timestamp: Self.now)
    let demotion = adjustments["函式"] ?? 0
    #expect(demotion < 0, "被換掉的詞應當被壓低")
    #expect(
      demotion >= -LXAssembly.SmartPreferenceStore.demotionCap,
      "壓低幅度不得超過上限 \(LXAssembly.SmartPreferenceStore.demotionCap)，實得 \(demotion)"
    )
  }

  /// 負向訊號必須是可回復的：久未再發生就該衰減回去。
  @Test("Demotion decays back toward zero as it ages")
  func demotionDecays() {
    let store = LXAssembly.SmartPreferenceStore()
    for _ in 0 ..< 5 {
      store.note(
        reading: "ㄏㄢˊ-ㄕˋ", candidate: "韓式", previous: "正宗", anterior: "",
        appCategory: .chat, displaced: "函式", timestamp: Self.now
      )
    }
    let fresh = store.adjustments(previous: "正宗", appCategory: .chat, timestamp: Self.now)["函式"] ?? 0
    let laterTimestamp = Self.now + 20 * 86_400 // 20 天後，仍在 30 天壽命內
    let aged = store.adjustments(previous: "正宗", appCategory: .chat, timestamp: laterTimestamp)["函式"] ?? 0
    #expect(fresh < 0)
    #expect(aged > fresh, "衰減之後壓低幅度應當變小（\(fresh) → \(aged)）")
  }

  /// 超過壽命的紀錄完全失效。
  @Test("Entries past their lifespan stop counting entirely")
  func entriesExpire() {
    let store = LXAssembly.SmartPreferenceStore()
    for _ in 0 ..< 5 {
      store.note(
        reading: "ㄏㄢˊ-ㄕˋ", candidate: "韓式", previous: "正宗", anterior: "",
        appCategory: .chat, displaced: "函式", timestamp: Self.now
      )
    }
    let expiredTimestamp = Self.now + (LXAssembly.SmartPreferenceStore.lifespanDays + 1) * 86_400
    let adjustments = store.adjustments(previous: "正宗", appCategory: .chat, timestamp: expiredTimestamp)
    #expect(adjustments.isEmpty || adjustments.values.allSatisfy { $0 == 0 })
  }

  /// **A app 學到的東西不得洩進 B app。**
  @Test("Learning in one app category does not leak into another")
  func appCategoriesAreIsolated() {
    let store = LXAssembly.SmartPreferenceStore()
    for _ in 0 ..< 5 {
      store.note(
        reading: "ㄏㄢˊ-ㄕˋ", candidate: "韓式", previous: "正宗", anterior: "",
        appCategory: .chat, displaced: "函式", timestamp: Self.now
      )
    }
    let inChat = store.adjustments(previous: "正宗", appCategory: .chat, timestamp: Self.now)
    let inEditor = store.adjustments(previous: "正宗", appCategory: .editor, timestamp: Self.now)
    #expect((inChat["韓式"] ?? 0) > 0, "在學習的那個 app 類別裡應當生效")
    #expect(inEditor["韓式"] == nil, "不得洩進別的 app 類別，實得 \(String(describing: inEditor["韓式"]))")
  }

  /// 語境隔離：在「正宗」後面學到的東西，不該套用到「呼叫」後面。
  @Test("Learning is scoped to the preceding-word context")
  func contextsAreIsolated() {
    let store = LXAssembly.SmartPreferenceStore()
    for _ in 0 ..< 5 {
      store.note(
        reading: "ㄏㄢˊ-ㄕˋ", candidate: "韓式", previous: "正宗", anterior: "",
        appCategory: .chat, displaced: "函式", timestamp: Self.now
      )
    }
    let other = store.adjustments(previous: "呼叫", appCategory: .chat, timestamp: Self.now)
    #expect(other["韓式"] == nil, "不同語境不得共用學習結果")
  }

  /// 逐 app 清除只能清掉那一個 app 的東西。
  @Test("Resetting one app category leaves the others intact")
  func resetIsScopedToOneAppCategory() {
    let store = LXAssembly.SmartPreferenceStore()
    for _ in 0 ..< 5 {
      store.note(
        reading: "ㄏㄢˊ-ㄕˋ", candidate: "韓式", previous: "正宗", anterior: "",
        appCategory: .chat, displaced: "函式", timestamp: Self.now
      )
      store.note(
        reading: "ㄏㄢˊ-ㄕˋ", candidate: "函式", previous: "呼叫", anterior: "",
        appCategory: .editor, displaced: "韓式", timestamp: Self.now
      )
    }
    store.resetAppSpecificLearning(.chat)
    #expect(store.adjustments(previous: "正宗", appCategory: .chat, timestamp: Self.now).isEmpty)
    #expect(
      (store.adjustments(previous: "呼叫", appCategory: .editor, timestamp: Self.now)["函式"] ?? 0) > 0,
      "清除 chat 不得波及 editor"
    )
  }

  /// 全清必須是真的全清。
  @Test("Clearing wipes everything")
  func clearAllWipesEverything() {
    let store = LXAssembly.SmartPreferenceStore()
    for _ in 0 ..< 5 {
      store.note(
        reading: "ㄏㄢˊ-ㄕˋ", candidate: "韓式", previous: "正宗", anterior: "",
        appCategory: .chat, displaced: "函式", timestamp: Self.now
      )
    }
    store.clearAll()
    #expect(store.count == 0)
    #expect(store.adjustments(previous: "正宗", appCategory: .chat, timestamp: Self.now).isEmpty)
  }

  /// 存檔與讀檔必須來回無損。
  @Test("An archive round-trips without loss")
  func archiveRoundTrips() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("SmartPreferenceStoreTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("prefs.json")

    let original = LXAssembly.SmartPreferenceStore(dataURL: url)
    for _ in 0 ..< 3 {
      original.note(
        reading: "ㄏㄢˊ-ㄕˋ", candidate: "韓式", previous: "正宗", anterior: "餐廳",
        appCategory: .chat, displaced: "函式", timestamp: Self.now
      )
    }
    original.saveToDisk()
    #expect(FileManager.default.fileExists(atPath: url.path))

    let reloaded = LXAssembly.SmartPreferenceStore(dataURL: url)
    reloaded.loadFromDisk()
    #expect(reloaded.count == original.count)
    let before = original.adjustments(previous: "正宗", appCategory: .chat, timestamp: Self.now)
    let after = reloaded.adjustments(previous: "正宗", appCategory: .chat, timestamp: Self.now)
    #expect(before == after)
  }

  /// **版本不符的存檔一律整份丟棄，不得被誤讀成有效資料。**
  @Test("An archive with an unknown schemaVersion is discarded, not guessed at")
  func futureArchiveIsDiscarded() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("SmartPreferenceStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("prefs.json")

    let payload = #"{"schemaVersion":999,"savedAt":0,"entries":[]}"#
    try payload.write(to: url, atomically: true, encoding: .utf8)

    let store = LXAssembly.SmartPreferenceStore(dataURL: url)
    store.loadFromDisk()
    #expect(store.count == 0, "未知版本的存檔不得被收進來")
  }

  /// 壞掉的存檔不得讓載入流程崩潰。
  @Test("A corrupt archive degrades to an empty store")
  func corruptArchiveIsSurvivable() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("SmartPreferenceStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("prefs.json")
    try "{ this is not json".write(to: url, atomically: true, encoding: .utf8)

    let store = LXAssembly.SmartPreferenceStore(dataURL: url)
    store.loadFromDisk()
    #expect(store.count == 0)
  }

  /// 容量上限必須真的生效，否則長期使用下記憶體會無限長大。
  @Test("The store evicts the least recently used entries past capacity")
  func capacityIsEnforced() {
    let store = LXAssembly.SmartPreferenceStore()
    let overshoot = LXAssembly.SmartPreferenceStore.totalCapacity + 200
    for index in 0 ..< overshoot {
      store.note(
        reading: "ㄗˋ", candidate: "字\(index)", previous: "前\(index)", anterior: "",
        appCategory: .other, displaced: nil, timestamp: Self.now + Double(index)
      )
    }
    #expect(store.count <= LXAssembly.SmartPreferenceStore.totalCapacity)
  }

  // MARK: Private

  /// 固定的基準時間，讓衰減相關的斷言不受實際執行時刻影響。
  private static let now: Double = 1_800_000_000
}
