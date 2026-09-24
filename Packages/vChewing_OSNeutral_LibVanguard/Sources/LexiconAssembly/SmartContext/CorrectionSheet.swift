// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa

// MARK: - LXAssembly.CorrectionSheetEntry

extension LXAssembly {
  /// 對照修改表的一筆：在某個語境下，把 `from` 改成 `to`。
  ///
  /// 這個形狀與「使用者手動把 A 改成 B」在語義上**完全同構**，所以匯入走的是
  /// Phase 3 既有的正／負訊號路徑，不另開一套評分機制——差別只在於一次來一批。
  public struct CorrectionSheetEntry: Codable, Sendable, Hashable {
    // MARK: Lifecycle

    public init(
      reading: String,
      from: String,
      to: String,
      previous: String = "",
      appCategory: SmartAppCategory = .other
    ) {
      self.reading = reading
      self.from = from
      self.to = to
      self.previous = previous
      self.appCategory = appCategory
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.reading = try container.decode(String.self, forKey: .reading)
      self.from = try container.decode(String.self, forKey: .from)
      self.to = try container.decode(String.self, forKey: .to)
      self.previous = try container.decodeIfPresent(String.self, forKey: .previous) ?? ""
      self.appCategory = try container
        .decodeIfPresent(SmartAppCategory.self, forKey: .appCategory) ?? .other
    }

    // MARK: Public

    /// 讀音索引鍵（以組字器分隔符連接）。
    public let reading: String
    /// 原本被選出來的詞。
    public let from: String
    /// 應該改成的詞。
    public let to: String
    /// 語境（前一個詞）。
    public let previous: String
    /// 這筆修正適用的 app 粗類別。
    public let appCategory: SmartAppCategory

    // MARK: Internal

    enum CodingKeys: String, CodingKey {
      case reading, from, to, previous, appCategory
    }
  }

  /// 一整份對照修改表。
  public struct CorrectionSheet: Codable, Sendable {
    // MARK: Lifecycle

    public init(
      schemaVersion: Int = CorrectionSheet.currentVersion,
      sheetID: UUID = UUID(),
      entries: [CorrectionSheetEntry]
    ) {
      self.schemaVersion = schemaVersion
      self.sheetID = sheetID
      self.entries = entries
    }

    // MARK: Public

    public nonisolated static let currentVersion = 1
    /// 單一份表的筆數上限。
    ///
    /// 一份好的對照表是針對使用者實際打錯的地方做的幾十筆修正，不是一本詞典。
    /// 上限同時是對「模型把整個日誌原樣吐回來」這種失敗模式的防禦。
    public nonisolated static let maxEntries = 500

    public let schemaVersion: Int
    /// 本次匯入的識別碼，供整批復原使用。
    public let sheetID: UUID
    public let entries: [CorrectionSheetEntry]
  }
}

// MARK: - LXAssembly.CorrectionSheetImportReport

extension LXAssembly {
  /// 匯入前的試算報告。
  public struct CorrectionSheetImportReport: Sendable {
    public struct Rejection: Sendable, Hashable {
      public let entry: CorrectionSheetEntry
      public let reason: String
    }

    /// 通過驗證、會被套用的項目。
    public var accepted: [CorrectionSheetEntry] = []
    /// 被拒絕的項目與原因。
    public var rejected: [Rejection] = []

    public var isEmpty: Bool { accepted.isEmpty }

    /// 供使用者確認用的文字摘要。
    public func renderSummary() -> String {
      var lines: [String] = []
      lines.append("將套用 \(accepted.count) 筆、略過 \(rejected.count) 筆。")
      for entry in accepted.prefix(20) {
        let context = entry.previous.isEmpty ? "" : "「\(entry.previous)」之後："
        lines.append("  ＋ \(context)\(entry.from) → \(entry.to)（\(entry.reading)）")
      }
      if accepted.count > 20 { lines.append("  …另有 \(accepted.count - 20) 筆") }
      for rejection in rejected.prefix(10) {
        lines.append("  － \(rejection.entry.from) → \(rejection.entry.to)：\(rejection.reason)")
      }
      if rejected.count > 10 { lines.append("  …另有 \(rejected.count - 10) 筆被略過") }
      return lines.joined(separator: "\n")
    }
  }
}

// MARK: - Importing

extension LXAssembly.LXFacade {
  /// 解析一份對照修改表。
  ///
  /// **這份東西是外部資料，一律當成不可信輸入處理。** 它可能出自任何一個模型，
  /// 而模型會有行為不如預期的一天；那一天輸入法必須只是「沒學到東西」，
  /// 而不是「被寫壞了」。
  public static func parseCorrectionSheet(from data: Data) throws -> LXAssembly.CorrectionSheet {
    let sheet = try JSONDecoder().decode(LXAssembly.CorrectionSheet.self, from: data)
    guard sheet.schemaVersion == LXAssembly.CorrectionSheet.currentVersion else {
      throw LXAssembly.CorrectionSheetError.unsupportedVersion(sheet.schemaVersion)
    }
    guard sheet.entries.count <= LXAssembly.CorrectionSheet.maxEntries else {
      throw LXAssembly.CorrectionSheetError.tooManyEntries(sheet.entries.count)
    }
    return sheet
  }

  /// 試算一份對照修改表會造成什麼影響，但**不套用**。
  ///
  /// 驗證的判準：讀音與詞必須都不是空的、`from` 與 `to` 必須不同、
  /// 而且 `to` 必須是該讀音底下**真實存在的候選**——一個指向不存在詞彙的修正，
  /// 只會在表裡留下一筆永遠不會命中的垃圾。
  public func dryRunCorrectionSheet(
    _ sheet: LXAssembly.CorrectionSheet
  )
    -> LXAssembly.CorrectionSheetImportReport {
    var report = LXAssembly.CorrectionSheetImportReport()
    var seen = Set<LXAssembly.CorrectionSheetEntry>()
    let separator = Homa.Assembler.theSeparator

    for entry in sheet.entries {
      func reject(_ reason: String) {
        report.rejected.append(.init(entry: entry, reason: reason))
      }
      guard !entry.reading.isEmpty, !entry.from.isEmpty, !entry.to.isEmpty else {
        reject("欄位不得為空")
        continue
      }
      guard entry.from != entry.to else {
        reject("from 與 to 相同")
        continue
      }
      guard seen.insert(entry).inserted else {
        reject("重複的項目")
        continue
      }
      let keyArray = separator.isEmpty
        ? [entry.reading]
        : entry.reading.components(separatedBy: separator).filter { !$0.isEmpty }
      guard !keyArray.isEmpty else {
        reject("讀音無法解析")
        continue
      }
      guard hasKeyValuePairFor(keyArray: keyArray, value: entry.to) else {
        reject("「\(entry.to)」不是該讀音底下的候選")
        continue
      }
      report.accepted.append(entry)
    }
    return report
  }

  /// 套用一份已試算過的對照修改表。
  ///
  /// 每一筆都走與「使用者手動改字」完全相同的訊號路徑，因此也一律受同一組上下限
  /// （`SmartBoostTable.clamp`、`promotionCap`、`demotionCap`）夾住——
  /// **一份亂寫或惡意的對照表不可能把輸入法弄壞，最壞的情況只是排序變難看。**
  ///
  /// - Returns: 實際寫入的筆數。
  @discardableResult
  public func applyCorrectionSheet(
    _ sheet: LXAssembly.CorrectionSheet,
    report: LXAssembly.CorrectionSheetImportReport,
    timestamp: Double = Date().timeIntervalSince1970
  )
    -> Int {
    guard let store = smartPreferenceStore else { return 0 }
    for entry in report.accepted {
      store.note(
        reading: entry.reading,
        candidate: entry.to,
        previous: entry.previous,
        anterior: "",
        appCategory: entry.appCategory,
        displaced: entry.from,
        timestamp: timestamp,
        provenance: .importedSheet(sheet.sheetID)
      )
    }
    Self.pomGeneration &+= 1
    saveSmartPreferenceData()
    return report.accepted.count
  }

  /// 整批復原某一次匯入。
  ///
  /// 匯入是使用者按下去的動作，而他按下去的時候並不知道結果會怎樣——所以它必須是
  /// 可以收回的。以 sheet id 標記來源，就是為了讓這件事做得到。
  @discardableResult
  public func revertCorrectionSheet(_ sheetID: UUID) -> Int {
    guard let store = smartPreferenceStore else { return 0 }
    let removed = store.forgetEntries(fromSheet: sheetID)
    if removed > 0 {
      Self.pomGeneration &+= 1
      saveSmartPreferenceData()
    }
    return removed
  }
}

// MARK: - LXAssembly.CorrectionSheetError

extension LXAssembly {
  public enum CorrectionSheetError: Error, CustomStringConvertible {
    case unsupportedVersion(Int)
    case tooManyEntries(Int)

    // MARK: Public

    public var description: String {
      switch self {
      case let .unsupportedVersion(version):
        "Unsupported correction-sheet schemaVersion: \(version)."
      case let .tooManyEntries(count):
        "Correction sheet holds \(count) entries, over the limit of \(CorrectionSheet.maxEntries)."
      }
    }
  }
}
