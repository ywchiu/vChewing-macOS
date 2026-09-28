// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - Homa.ContextScoreAdjuster

extension Homa {
  /// 組句評分的上下文加權鉤子。
  ///
  /// 護摩引擎本身是 OS-neutral、也不認得「使用者」「app」這些概念，故它只提供這個
  /// 注入點、不提供任何實作——與既有的 `Homa.GramQuerier`／`Homa.BehaviorPerceptor`
  /// 同一個路數。實作由 `LexiconAssembly` 提供、由 `LibVanguard` 接線。
  ///
  /// ## 語義：**純加法，且只能是加法**
  ///
  /// DP 的每一步原本是 `dp[i] + node.getScore(previous:anterior:)`，而後者回傳的已經是
  /// 「原廠權重 ＋ 既有 n-gram 加分 ＋ POM 統計」的合值。本鉤子的回傳值**加在它之後**：
  ///
  /// ```text
  /// final = base_lexicon + existing_contextual + existing_user_model + smart_adjustment
  /// ```
  ///
  /// 這麼做是為了不動到 `Homa.Node.getScore()` 內部的覆寫語義——那裡有
  /// `selectOverrideGram` 的就地寫回副作用，是整個引擎最不該被碰的一塊。
  /// 也因此，使用者顯式選字所用的 `overridingScore`（野獸常數 114514）依然完勝任何
  /// 合理量級的 adjustment：**手動選字的絕對優先權不受本鉤子影響**。
  ///
  /// ## 效能契約（**硬性**）
  ///
  /// 本鉤子位於整個輸入法最熱的迴圈裡：`assemble()` 每次按鍵會被呼叫 1–3 次，
  /// 而單次 DP 的內層最多跑 `keyCount × maxSegLength`（實務上 ≈ 200）輪，
  /// 每一輪都會呼叫本鉤子一次。實測基線（release、真實辭典）的 `assemble()`
  /// p95 是 6.34 ms，而每次敲鍵的預算是半個 60 Hz 畫格（8 ms）——也就是說
  /// **本鉤子的單次成本必須落在 100 ns 量級**。
  ///
  /// 實作端因此只准做「對預先壓平好的字典做一次查表」。明確禁止：
  /// - 任何字串建構（`joined()`、`components(separatedBy:)`、字串插值、`+`）
  /// - 任何陣列／集合的配置
  /// - 任何鎖、任何 I/O、任何 `Date()`
  ///
  /// 語境的展開（把前後文、app、session 詞彙壓成一張 `[String: Double]`）必須在
  /// **進入 `assemble()` 之前**做一次，不得放在鉤子裡。
  ///
  /// - Parameters:
  ///   - value: 該元圖的資料值（候選詞本身）。
  ///   - keyArray: 該元圖的真實讀音索引鍵陣列。
  ///   - previous: DP 沿最佳路徑回看的前一個詞值；句首時為空字串。
  ///   - anterior: 再往前一格的詞值；不存在時為空字串。
  /// - Returns: 要加到該節點分數上的增量。回傳 0 即等同於沒有這個鉤子。
  public typealias ContextScoreAdjuster = (
    _ value: String,
    _ keyArray: [String],
    _ previous: String,
    _ anterior: String
  ) -> Double
}
