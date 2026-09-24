// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Homa

// MARK: - LXAssembly.SmartBoostTable

extension LXAssembly {
  /// 語境壓平後的加權表，供組句 DP 的熱路徑查用。
  ///
  /// ## 為什麼要有這層
  ///
  /// `Homa.ContextScoreAdjuster` 的效能契約要求單次呼叫落在 100 ns 量級（理由見該
  /// typealias 的說明）。任何「在鉤子裡看一眼前後文、算一下分數」的寫法都做不到——
  /// 光是把讀音陣列 `joined()` 成字串就已經超標。
  ///
  /// 所以語境的展開必須**在進入 `assemble()` 之前做一次**：scorer 把
  /// `SmartInputContext` 編譯成這張以候選詞值為鍵的扁平表，DP 內層只做一次雜湊查表。
  public struct SmartBoostTable: Sendable, Hashable {
    // MARK: Lifecycle

    public init(entries: [String: Double] = [:], clamp: Double = SmartBoostTable.defaultClamp) {
      let effectiveClamp = Swift.max(0, clamp)
      // 夾在建表時做完，查表時就不必再付出任何算術成本。
      self.entries = entries.isEmpty ? [:] : entries.mapValues {
        Swift.max(-effectiveClamp, Swift.min(effectiveClamp, $0))
      }
      self.clamp = effectiveClamp
    }

    // MARK: Public

    /// 加權的絕對值上限（對數空間）。
    ///
    /// 取 1.5 的依據：原廠 unigram 的分數帶落在 −3 ～ −13，同音競爭者之間的差距
    /// 小至 0.001、大至 1 附近（實測最尖銳的一批二音節鍵 top-2 差距是 0.001，
    /// 而「城市 vs 程式」這種最極端的也只差 0.85）。1.5 足以翻轉任何一組真實的
    /// 同音競爭，又遠小於「單字 vs 雙字詞」之間的結構性差距（動輒 5 以上），
    /// 故不會把 DP 的分詞行為整個掀掉。使用者顯式選字的 `overridingScore`
    /// （114514）更是完全不受影響。
    public static let defaultClamp: Double = 1.5

    /// 空表。查表恆回 0，且 `isEmpty` 讓呼叫端得以整個跳過鉤子的掛載。
    public static let empty = SmartBoostTable()

    public let entries: [String: Double]
    public let clamp: Double

    public var isEmpty: Bool { entries.isEmpty }

    /// 熱路徑查表。**這個函式裡不得出現任何配置或字串運算。**
    @inlinable
    public func adjustment(for value: String) -> Double {
      entries[value] ?? 0
    }

    /// 把本表接成 `Homa` 的加權鉤子。
    ///
    /// 讀音與前後文在此一律被忽略——它們的資訊在建表時就已經被吃進去了。
    /// 保留這四個參數是為了讓日後需要「逐位置」判斷的實作有路可走，而不必再改
    /// `Homa` 的簽章。
    public func asContextScoreAdjuster() -> Homa.ContextScoreAdjuster {
      { value, _, _, _ in self.adjustment(for: value) }
    }
  }
}

// MARK: - LXAssembly.SmartContextScorer

extension LXAssembly {
  /// 上下文加權的計分介面。
  ///
  /// ## 契約
  ///
  /// 1. **只能是加法**。回傳值會被加在「原廠權重＋既有 n-gram＋POM 統計」之上，
  ///    絕不取代其中任何一項。這是為了不破壞 Homa 既有的 ranking 語義。
  /// 2. **有界**。回傳值一律被 `SmartBoostTable.clamp` 夾住；實作不得假設自己可以
  ///    給出任意大的分數來「保證」某個候選勝出——要那種效果，該走的是使用者顯式
  ///    覆寫（`overridingScore`），不是本介面。
  /// 3. **可完全移除**。整個 SmartContext 子系統從產品裡拿掉之後，輸入法必須仍然
  ///    是一個完整可用的輸入法。故本介面的任何型別都不得出現在 `Homa` 的簽章裡
  ///    （那裡只認得 `Homa.ContextScoreAdjuster` 這個純閉包）。
  public protocol SmartContextScorer: AnyObject {
    /// 逐候選計分。
    ///
    /// 這條路徑**不在** DP 熱路徑上——它供候選窗 rerank、單元測試與診斷使用，
    /// 因此允許做比查表更重的事。組句側一律走 `compileBoostTable(context:)`。
    /// - Parameters:
    ///   - candidate: 候選詞值。
    ///   - reading: 該候選的讀音索引鍵陣列。
    ///   - baseScore: 該候選在加權之前的既有分數（原廠＋n-gram＋POM 的合值）。
    ///   - context: 當拍語境快照。
    /// - Returns: 要加上去的增量，已夾在 clamp 之內。
    func scoreAdjustment(
      candidate: String,
      reading: [String],
      baseScore: Double,
      context: SmartInputContext
    )
      -> Double

    /// 把語境編譯成扁平加權表，供組句 DP 使用。
    ///
    /// 呼叫端保證：每次語境變動**至多**呼叫一次，且一律在 `assemble()` 之外。
    func compileBoostTable(context: SmartInputContext) -> SmartBoostTable
  }
}

// MARK: - LXAssembly.NullSmartContextScorer

extension LXAssembly {
  /// 恆回 0 的 scorer。
  ///
  /// 用於「介面已接好、但功能關閉」的狀態，也是所有 Phase 的行為基準：
  /// 掛上它之後的組句結果必須與完全沒有 SmartContext 時**逐位元一致**。
  public final class NullSmartContextScorer: SmartContextScorer {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func scoreAdjustment(
      candidate _: String,
      reading _: [String],
      baseScore _: Double,
      context _: SmartInputContext
    )
      -> Double {
      0
    }

    public func compileBoostTable(context _: SmartInputContext) -> SmartBoostTable {
      .empty
    }
  }
}
