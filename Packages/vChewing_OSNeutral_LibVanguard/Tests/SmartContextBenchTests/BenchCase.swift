// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import LexiconAssembly

// MARK: - BenchCaseKind

/// 案例的驅動方式。不同 kind 的案例走不同的 driver 流程。
public enum BenchCaseKind: String, Codable, Sendable {
  /// 單純排序：敲完讀音之後檢查候選清單與組句結果。
  case ranking
  /// 修正學習：連續 `repeatCount` 輪「敲字 → 顯式選字」，最後一輪才計分。
  case correctionLearning
  /// App 切換：先在 `trainAppCategory` 下學習，再到 `appCategory` 下檢查**不得**被污染。
  case appSwitching
  /// 詞組升格：重複「逐字手動組出同一個詞組並遞交」若干輪，最後檢查它是否成為候選。
  case phrasePromotion
}

// MARK: - BenchAppCategory

/// App 的粗類別，直接沿用生產端的那一份。
///
/// 刻意不另立一份：基準測試若對「什麼算 editor」有自己的一套定義，量到的就不是
/// 生產端的行為了。資料集 JSON 裡寫的字串即 `LXAssembly.SmartAppCategory` 的 `rawValue`。
public typealias BenchAppCategory = LXAssembly.SmartAppCategory

// MARK: - BenchCase

/// 一筆 benchmark 案例。
///
/// 欄位的設計刻意貼近您在需求書裡給的形狀（`context` / `reading` / `expected`），
/// 只是把 `reading` 拆成逐音節陣列、把 `context` 拆成「顯示文字」與「其讀音」兩欄——
/// driver 必須真的把前文敲進組字器，否則 DP 拿不到 `previous` / `anterior` 語境。
public struct BenchCase: Codable, Sendable {
  // MARK: Lifecycle

  public init(
    id: String,
    kind: BenchCaseKind = .ranking,
    precedingText: String = "",
    precedingReadings: [String] = [],
    readings: [String],
    expected: String,
    competitors: [String] = [],
    appCategory: BenchAppCategory? = nil,
    trainAppCategory: BenchAppCategory? = nil,
    trainExpected: String? = nil,
    repeatCount: Int = 1,
    tags: [String] = []
  ) {
    self.id = id
    self.kind = kind
    self.precedingText = precedingText
    self.precedingReadings = precedingReadings
    self.readings = readings
    self.expected = expected
    self.competitors = competitors
    self.appCategory = appCategory
    self.trainAppCategory = trainAppCategory
    self.trainExpected = trainExpected
    self.repeatCount = repeatCount
    self.tags = tags
  }

  /// 手寫 decoder，讓資料集裡的絕大多數欄位都可以省略。
  ///
  /// 合成的 `Codable` 會要求每一個非 Optional 欄位都出現在 JSON 裡（預設值只對
  /// memberwise init 生效、不影響解碼），而案例檔九成的欄位都用得到預設值——
  /// 逐案例重複寫 `"kind": "ranking"` 只會讓資料集難讀、也容易寫錯。
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.kind = try container.decodeIfPresent(BenchCaseKind.self, forKey: .kind) ?? .ranking
    self.precedingText = try container.decodeIfPresent(String.self, forKey: .precedingText) ?? ""
    self.precedingReadings = try container.decodeIfPresent([String].self, forKey: .precedingReadings) ?? []
    self.readings = try container.decode([String].self, forKey: .readings)
    self.expected = try container.decode(String.self, forKey: .expected)
    self.competitors = try container.decodeIfPresent([String].self, forKey: .competitors) ?? []
    self.appCategory = try container.decodeIfPresent(BenchAppCategory.self, forKey: .appCategory)
    self.trainAppCategory = try container.decodeIfPresent(BenchAppCategory.self, forKey: .trainAppCategory)
    self.trainExpected = try container.decodeIfPresent(String.self, forKey: .trainExpected)
    self.repeatCount = try container.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
    self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
  }

  // MARK: Public

  /// 案例識別碼，須於整個資料集內唯一。
  public let id: String
  public let kind: BenchCaseKind
  /// 前文的顯示文字，僅供報表可讀性使用（不參與判定）。
  public let precedingText: String
  /// 前文的逐音節讀音。driver 會先把這些敲進組字器以建立語境。
  public let precedingReadings: [String]
  /// 待測目標的逐音節讀音。
  public let readings: [String]
  /// 期望勝出的候選。
  public let expected: String
  /// 已知的同音競爭者，僅供報表診斷（列出它們實際排在第幾）。
  public let competitors: [String]
  /// 測量時所處的 app 粗類別。
  public let appCategory: BenchAppCategory?
  /// `appSwitching` 專用：先在哪個 app 類別下訓練。
  public let trainAppCategory: BenchAppCategory?
  /// `appSwitching` 專用：訓練時選的是哪個詞（通常是 `expected` 的競爭者）。
  public let trainExpected: String?
  /// `correctionLearning` / `appSwitching` 專用：訓練輪數。
  public let repeatCount: Int
  public let tags: [String]

  /// 目標詞的音節數。用於判定候選是否為「同幅節」的可比對象。
  public var syllableCount: Int { readings.count }
}

// MARK: - BenchDataset

/// 一份資料集檔案的根結構。
public struct BenchDataset: Codable, Sendable {
  // MARK: Lifecycle

  public init(schemaVersion: Int = BenchDataset.currentSchemaVersion, name: String, cases: [BenchCase]) {
    self.schemaVersion = schemaVersion
    self.name = name
    self.cases = cases
  }

  // MARK: Public

  /// 目前的 schema 版本。載入時版本不符即**整份拒收**（不嘗試升級），
  /// 與 smart 學習資料的存檔策略一致：寧可少一份資料，不要爛一份資料。
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let name: String
  public let cases: [BenchCase]
}

// MARK: - BenchDatasetLoader

public enum BenchDatasetLoader {
  /// 資料集的檔名（不含副檔名）。順序即報表的分節順序。
  ///
  /// `cases_heldout` 的地位與其它幾份不同，請勿混用：它是在領域詞表**凍結之後**才
  /// 從原廠辭典裡重新挖出的同音歧義對，案例的語境是照一般寫作習慣寫的，寫的時候
  /// 不查詞表、事後也不為了讓它變綠而回頭加詞。`cases_smart` 量的是「這套機制在
  /// 詞表涵蓋得到的地方管不管用」，`cases_heldout` 量的才是「詞表涵蓋不到的地方
  /// 會怎樣」——也就是真實世界的多數情況。兩個數字要分開讀。
  public static let datasetStems = [
    "cases_regression",
    "cases_smart",
    "cases_heldout",
    "cases_phrases",
    "cases_correction",
    "cases_appswitch",
  ]

  /// 載入全部資料集。
  ///
  /// 優先順序：環境變數 `VCHEWING_BENCH_DATASET_DIR` 指定的目錄 → 測試靶內建資源。
  /// 前者供您在不重新編譯的前提下迭代案例。
  public static func loadAll() throws -> [BenchDataset] {
    try datasetStems.compactMap { try load(stem: $0) }
  }

  /// 載入單一資料集；找不到檔案時回傳 nil（缺某一份不該讓整個 benchmark 掛掉）。
  public static func load(stem: String) throws -> BenchDataset? {
    guard let url = resolveURL(stem: stem) else { return nil }
    let data = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode(BenchDataset.self, from: data)
    guard decoded.schemaVersion == BenchDataset.currentSchemaVersion else {
      throw BenchDatasetError.schemaVersionMismatch(
        stem: stem,
        found: decoded.schemaVersion,
        expected: BenchDataset.currentSchemaVersion
      )
    }
    return decoded
  }

  // MARK: Private

  private static func resolveURL(stem: String) -> URL? {
    if let overrideDir = ProcessInfo.processInfo.environment["VCHEWING_BENCH_DATASET_DIR"],
       !overrideDir.isEmpty {
      let candidate = URL(fileURLWithPath: overrideDir).appendingPathComponent("\(stem).json")
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    return Bundle.module.url(forResource: stem, withExtension: "json")
  }
}

// MARK: - BenchDatasetError

public enum BenchDatasetError: Error, CustomStringConvertible {
  case schemaVersionMismatch(stem: String, found: Int, expected: Int)

  // MARK: Public

  public var description: String {
    switch self {
    case let .schemaVersionMismatch(stem, found, expected):
      "Bench dataset '\(stem)' declares schemaVersion \(found), expected \(expected)."
    }
  }
}
