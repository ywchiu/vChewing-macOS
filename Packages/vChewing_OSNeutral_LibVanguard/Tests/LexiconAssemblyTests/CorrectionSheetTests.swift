// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
@testable import LexiconAssembly
import Testing

// MARK: - CorrectionSheetTests

/// 對照修改表（Phase 7）的測試。
///
/// 這份表是**外部資料**——它出自某個 AI，而模型會有行為不如預期的一天。所以這裡測的
/// 主要是那一天會發生什麼：答案必須是「沒學到東西」，而不是「輸入法被寫壞了」。
@Suite("CorrectionSheetTests", .serialized)
struct CorrectionSheetTests {
  // MARK: Internal

  /// 版本不符即拒收。
  @Test("A sheet with an unknown schemaVersion is rejected")
  func unsupportedVersionIsRejected() throws {
    let payload = #"{"schemaVersion":999,"sheetID":"\#(UUID().uuidString)","entries":[]}"#
    let data = try #require(payload.data(using: .utf8))
    #expect(throws: LXAssembly.CorrectionSheetError.self) {
      _ = try LXAssembly.LXFacade.parseCorrectionSheet(from: data)
    }
  }

  /// 超過筆數上限即整份拒收。
  @Test("An oversized sheet is rejected wholesale")
  func oversizedSheetIsRejected() throws {
    let entries = (0 ... LXAssembly.CorrectionSheet.maxEntries).map { index in
      LXAssembly.CorrectionSheetEntry(reading: "ㄗˋ", from: "字\(index)", to: "自\(index)")
    }
    let sheet = LXAssembly.CorrectionSheet(entries: entries)
    let data = try JSONEncoder().encode(sheet)
    #expect(throws: LXAssembly.CorrectionSheetError.self) {
      _ = try LXAssembly.LXFacade.parseCorrectionSheet(from: data)
    }
  }

  /// 試算會攔下空欄位、自我修正、重複項，以及**指向不存在詞彙的修正**。
  @Test("The dry run rejects malformed rows and rows pointing at nonexistent words")
  func dryRunRejectsGarbage() {
    defer { Self.teardown() }
    let facade = Self.makeFacade()
    let good = LXAssembly.CorrectionSheetEntry(
      reading: "ㄔㄥˊ-ㄕˋ", from: "城市", to: "程式", previous: "寫"
    )
    let sheet = LXAssembly.CorrectionSheet(entries: [
      good,
      good, // 重複
      .init(reading: "", from: "甲", to: "乙"),
      .init(reading: "ㄔㄥˊ-ㄕˋ", from: "程式", to: "程式"),
      .init(reading: "ㄔㄥˊ-ㄕˋ", from: "城市", to: "橙柿"), // 不在庫
    ])
    let report = facade.dryRunCorrectionSheet(sheet)
    #expect(report.accepted == [good])
    #expect(report.rejected.count == 4)
    #expect(report.renderSummary().contains("程式"))
  }

  /// 套用之後，正負訊號都走與「使用者手動改字」相同的路徑。
  @Test("Applying a sheet promotes the target and demotes what it replaces")
  func applyingMovesBothSides() {
    defer { Self.teardown() }
    let facade = Self.makeFacade()
    let store = try! #require(facade.smartPreferenceStore)
    let entry = LXAssembly.CorrectionSheetEntry(
      reading: "ㄔㄥˊ-ㄕˋ", from: "城市", to: "程式", previous: "寫"
    )
    let sheet = LXAssembly.CorrectionSheet(entries: [entry])
    let report = facade.dryRunCorrectionSheet(sheet)
    #expect(facade.applyCorrectionSheet(sheet, report: report, timestamp: Self.t0) == 1)

    let adjustments = store.adjustments(previous: "寫", appCategory: .other, timestamp: Self.t0)
    #expect((adjustments["城市"] ?? 0) < 0, "被換掉的那個詞該稍微往後")
    // 一筆修正即跨過信心門檻（frequency ＋ correctionCount 合計約 0.44 > 0.35），
    // 與「使用者自己動手改一次」的效果**逐位元相同**——這正是本機制的設計前提：
    // 匯入不是另一條更強的捷徑，它只是把同一個動作批次化。
    #expect((adjustments["程式"] ?? 0) > 0)
  }

  /// 重複出現的修正會繼續累積，但受上限把守（見下一個測試）。
  @Test("Repeated corrections from sheets accumulate")
  func repeatedImportsAccumulate() {
    defer { Self.teardown() }
    let facade = Self.makeFacade()
    let store = try! #require(facade.smartPreferenceStore)
    let entry = LXAssembly.CorrectionSheetEntry(
      reading: "ㄔㄥˊ-ㄕˋ", from: "城市", to: "程式", previous: "寫"
    )
    for _ in 0 ..< 3 {
      let sheet = LXAssembly.CorrectionSheet(entries: [entry])
      facade.applyCorrectionSheet(
        sheet, report: facade.dryRunCorrectionSheet(sheet), timestamp: Self.t0
      )
    }
    let adjustments = store.adjustments(previous: "寫", appCategory: .other, timestamp: Self.t0)
    #expect((adjustments["程式"] ?? 0) > 0)
  }

  /// **加權一律夾在既有上下限內**：一份亂寫的表最壞只是排序變難看。
  @Test("A sheet cannot push any adjustment past the existing caps")
  func adjustmentsStayWithinCaps() {
    defer { Self.teardown() }
    let facade = Self.makeFacade()
    let store = try! #require(facade.smartPreferenceStore)
    let entry = LXAssembly.CorrectionSheetEntry(
      reading: "ㄔㄥˊ-ㄕˋ", from: "城市", to: "程式", previous: "寫"
    )
    // 同一筆灌 200 次——模擬一份把同一條修正重複到荒謬程度的表。
    for _ in 0 ..< 200 {
      let sheet = LXAssembly.CorrectionSheet(entries: [entry])
      facade.applyCorrectionSheet(
        sheet, report: facade.dryRunCorrectionSheet(sheet), timestamp: Self.t0
      )
    }
    let adjustments = store.adjustments(previous: "寫", appCategory: .other, timestamp: Self.t0)
    let promotion = adjustments["程式"] ?? 0
    let demotion = adjustments["城市"] ?? 0
    #expect(promotion <= LXAssembly.SmartPreferenceStore.promotionCap)
    #expect(demotion >= -LXAssembly.SmartPreferenceStore.demotionCap)
  }

  /// 整批復原：把那份表加上去的扣掉，紀錄歸零即刪除。
  @Test("Reverting a sheet undoes exactly what that sheet added")
  func revertUndoesTheImport() {
    defer { Self.teardown() }
    let facade = Self.makeFacade()
    let store = try! #require(facade.smartPreferenceStore)
    let sheet = LXAssembly.CorrectionSheet(entries: [
      .init(reading: "ㄔㄥˊ-ㄕˋ", from: "城市", to: "程式", previous: "寫"),
    ])
    facade.applyCorrectionSheet(
      sheet, report: facade.dryRunCorrectionSheet(sheet), timestamp: Self.t0
    )
    #expect(store.count == 2)
    #expect(facade.revertCorrectionSheet(sheet.sheetID) == 2)
    #expect(store.count == 0, "整筆都來自該表時，復原即刪除")
  }

  /// **復原不得刮掉使用者自己累積的紀錄。**
  ///
  /// 這是整個匯入機制裡最容易做錯、而且做錯了使用者也很難察覺的一處：他只是想收回
  /// 一份 AI 給的表，結果連自己改了半個月的偏好一起沒了。
  @Test("Reverting a sheet leaves the user's own signals intact")
  func revertPreservesManualSignals() {
    defer { Self.teardown() }
    let facade = Self.makeFacade()
    let store = try! #require(facade.smartPreferenceStore)
    // 使用者自己先改過兩次。
    for _ in 0 ..< 2 {
      store.note(
        reading: "ㄔㄥˊ-ㄕˋ", candidate: "程式", previous: "寫", anterior: "",
        appCategory: .other, displaced: "城市", timestamp: Self.t0
      )
    }
    let manual = try! #require(
      store.snapshot(timestamp: Self.t0).first { $0.entry.candidate == "程式" }?.entry
    )
    #expect(manual.correctionCount == 2)

    let sheet = LXAssembly.CorrectionSheet(entries: [
      .init(reading: "ㄔㄥˊ-ㄕˋ", from: "城市", to: "程式", previous: "寫"),
    ])
    facade.applyCorrectionSheet(
      sheet, report: facade.dryRunCorrectionSheet(sheet), timestamp: Self.t0
    )
    facade.revertCorrectionSheet(sheet.sheetID)

    let after = try! #require(
      store.snapshot(timestamp: Self.t0).first { $0.entry.candidate == "程式" }?.entry
    )
    #expect(after.frequency == manual.frequency)
    #expect(after.correctionCount == manual.correctionCount)
    #expect(after.imports.isEmpty)
  }

  /// 沒掛偏好表時，套用是個乾淨的早退。
  @Test("Applying a sheet without a preference store is a clean no-op")
  func applyingWithoutAStoreIsInert() {
    defer { Self.teardown() }
    let facade = Self.makeFacade(withStore: false)
    let sheet = LXAssembly.CorrectionSheet(entries: [
      .init(reading: "ㄔㄥˊ-ㄕˋ", from: "城市", to: "程式"),
    ])
    #expect(facade.applyCorrectionSheet(sheet, report: facade.dryRunCorrectionSheet(sheet)) == 0)
    #expect(facade.revertCorrectionSheet(sheet.sheetID) == 0)
  }

  /// 舊版（沒有 `imports` 欄位）的存檔仍然讀得進來。
  ///
  /// Swift 合成的解碼器對缺少的鍵一律擲錯，就算該屬性有預設值也一樣；而本表的持久化層
  /// 見到讀不懂的檔案會整份丟棄。兩者相乘的結果是「加一個欄位 ＝ 清空使用者的學習資料」，
  /// 所以這條測試守的其實是那件事。
  @Test("An archive written before the imports field still decodes")
  func legacyEntryWithoutImportsStillDecodes() throws {
    let payload = """
    {"reading":"ㄗˋ","candidate":"字","previous":"打","anterior":"",
     "appCategory":"editor","frequency":3,"correctionCount":1,
     "demotionCount":0,"lastUsed":1,"firstSeen":1}
    """
    let data = try #require(payload.data(using: .utf8))
    let entry = try JSONDecoder().decode(LXAssembly.SmartPreferenceEntry.self, from: data)
    #expect(entry.candidate == "字")
    #expect(entry.frequency == 3)
    #expect(entry.imports.isEmpty)
  }

  // MARK: Private

  private static let t0: Double = 1_800_000_000

  private static func teardown() {
    LXAssembly.LXFacade.disconnectFactoryDictionary()
    LXAssembly.resetSharedState()
  }

  /// 造一個只認得「ㄔㄥˊ-ㄕˋ → 城市／程式」的迷你語言模型。
  private static func makeFacade(withStore: Bool = true) -> LXAssembly.LXFacade {
    let facade = LXAssembly.LXFacade(isCHS: false)
    facade.setOptions { config in
      config.isCNSEnabled = false
      config.isSymbolEnabled = false
      config.alwaysSupplyETenDOSUnigrams = false
    }
    let key = ["ㄔㄥˊ", "ㄕˋ"]
    facade.mountGramSupplier(
      StubGramSupplier(gramsByKeyChain: [
        key.joined(separator: "-"): [
          Homa.Gram(keyArray: key, current: "城市", probability: -3.510),
          Homa.Gram(keyArray: key, current: "程式", probability: -4.360),
        ],
      ])
    )
    if withStore { facade.smartPreferenceStore = .init() }
    return facade
  }
}
