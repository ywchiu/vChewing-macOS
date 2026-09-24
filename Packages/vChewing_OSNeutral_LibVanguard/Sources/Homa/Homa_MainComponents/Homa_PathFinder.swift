// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

extension Homa.Assembler {
  /// 組句函式，會以 DAG (Directed Acyclic Graph) 動態規劃演算法更新當前組字器的 assembledSentence。
  ///
  /// 此演算法使用動態規劃在有向無環圖中尋找具有最優評分的路徑，從而確定最合適的詞彙組合。
  /// DAG 演算法相對於 Dijkstra 演算法更簡潔，記憶體使用量更少。
  ///
  /// - Returns: 組句結果（已選字詞陣列）。
  @discardableResult
  public func assemble() -> [Homa.GramInPath] {
    var finalScore = Double(Int32.min)
    let result = Homa.PathFinder.run(
      config: &config,
      contextScoreAdjuster: contextScoreAdjuster,
      finalScore: &finalScore
    )
    mostRecentPathScore = finalScore
    assembledSentence = result
    return assembledSentence
  }
}

// MARK: - Homa.PathFinder

extension Homa {
  enum PathFinder {
    // MARK: Internal

    /// 組句工具，會以 DAG 動態規劃演算法更新當前組字器的 assembledSentence。
    ///
    /// 該演算法使用動態規劃在有向無環圖中尋找具有最高分數的路徑，即最可能的字詞組合。
    /// DAG 演算法相對簡潔，記憶體使用量較少。
    /// - Parameters:
    ///   - config: 組字器組態（inout，因為 DP 遍歷時 `getScore(previous:)` 的自動覆寫
    ///     副作用需要就地寫回節點狀態——節點為 Struct，無法再靠引用穿透值拷貝）。
    ///   - contextScoreAdjuster: 上下文加權鉤子（可選）。語義與效能契約見
    ///     `Homa.ContextScoreAdjuster`；為 `nil` 時本函式的行為與引入該機制前逐位元一致。
    ///   - finalScore: 寫出本次 DP 的整句最佳路徑總分（不可達時為 `Double(Int32.min)`）。
    /// - Returns: 組句結果（已選字詞陣列）。
    @discardableResult
    static func run(
      config: inout Homa.Config,
      contextScoreAdjuster: Homa.ContextScoreAdjuster? = nil,
      finalScore: inout Double
    )
      -> [Homa.GramInPath] {
      var newAssembledSentence = [Homa.GramInPath]()
      guard !config.segments.isEmpty else {
        finalScore = Double(Int32.min)
        return newAssembledSentence
      }

      let keyCount = config.keys.count

      // 動態規劃陣列：dp[i] 表示到位置 i 的最佳分數
      var dp = [Double](repeating: Double(Int32.min), count: keyCount + 1)
      // 回溯陣列：parent[i] 記錄到達位置 i 的最佳前驅節點和使用者刻意覆蓋之狀態
      var parent = [GramState?](repeating: nil, count: keyCount + 1)

      // 起始狀態
      dp[0] = 0

      // 收集 DP 遍歷期間被 getScore() 就地修改的節點，於遍歷結束後統一寫回。
      // 這樣可以避免「for-in 遍歷段字典的同時、透過下標寫回同一字典」所觸發的
      // 寫時複製（COW），讓寫回發生在字典為唯一引用的時點、直接原地更新。
      var visitedNodes = [(position: Int, segLength: Int, node: Homa.Node)]()
      // 預估容量，減少 DP 遍歷過程中 visitedNodes 反覆搬移緩衝區的次數。
      visitedNodes.reserveCapacity(keyCount * config.maxSegLength)

      // DAG 動態規劃主循環
      for i in 0 ..< keyCount {
        guard dp[i] > Double(Int32.min) else { continue } // 只處理可達的位置

        // 遍歷從位置 i 開始的所有可能節點
        for (length, nextNode) in config.segments[i] {
          guard let nextGram = nextNode.currentGram else { continue }

          let nextPos = i + length
          guard nextPos <= keyCount else { continue }

          // 計算新的權重分數，考慮前一個字詞的影響
          let previousCurrent = parent[i]?.gram?.current ?? ""
          // 三元圖前驅之二：沿最佳路徑往回看「前驅節點起點」之前的節點值
          // （與既有 bigram「最佳路徑前驅」近似一致；1D DP 結構零改動）。
          let anteriorCurrent: String = {
            guard let parentInfo = parent[i], parentInfo.segLength > 0 else { return "" }
            let previousStart = i - parentInfo.segLength
            guard previousStart >= 0 else { return "" }
            return parent[previousStart]?.gram?.current ?? ""
          }()
          var nodeCopy = nextNode
          // 上下文加權一路交給 `getScore()`，**不在這裡另外加**。
          //
          // 原因是節點的內部結構：一個 `Homa.Node` 承載該讀音下的所有元圖，而 DP 每個
          // 節點只看得到一個 `currentGram`——「同音詞之間誰勝出」是在節點內部決定的。
          // 加權若只疊在這裡（節點外），就只能改變斷詞方式，永遠改變不了「同一個讀音
          // 下選哪個詞」，而後者正是上下文消歧的全部。故加權必須進 `getScore()`，
          // 參與單元圖的擇定；回傳值已含加權，此處再加一次就是重複計分。
          let newScore = dp[i] + nodeCopy.getScore(
            previous: previousCurrent,
            anterior: anteriorCurrent,
            contextAdjuster: contextScoreAdjuster
          )
          visitedNodes.append((i, length, nodeCopy))

          // 如果找到更好的路徑，更新 dp 和 parent
          if newScore > dp[nextPos] {
            dp[nextPos] = newScore
            // 幅節長度以段字典鍵為準：gram.keyArray 的長度可能與格位幅節長度
            // 不一致（如前綴匹配回傳的更長 gram），回溯時不得依賴後者。
            //
            // 記錄的是 **getScore() 之後**的 `currentGram`：`getScore()` 會依語境
            // 就地改選節點內的元圖（雙元／三元圖匹配、以及上下文加權下的單元圖擇優），
            // 而 `newScore` 算的正是那個被選中的元圖。若此處沿用呼叫前的 `nextGram`，
            // 分數與輸出就會對不上——輸出要等下一次 `assemble()` 讀到已更新的節點狀態
            // 才會追上，於是「最後一個音節永遠慢一拍」。
            parent[nextPos] = (nodeCopy.currentGram ?? nextGram, nodeCopy.isExplicitlyOverridden, length)
          }
        }
      }

      // 統一寫回節點狀態（此時遍歷已結束，段字典為唯一引用，不觸發 COW 複製）。
      for entry in visitedNodes {
        config.segments[entry.position][entry.segLength] = entry.node
      }

      // 回溯構建最佳路徑
      var resultReversed: [Homa.GramInPath] = []
      var currentPos = keyCount

      // 從終點開始回溯
      while currentPos > 0 {
        guard let parentInfo = parent[currentPos] else { break }
        guard let gram = parentInfo.gram else { break }

        resultReversed.append(
          .init(gram: gram, isExplicit: parentInfo.isExplicit)
        )
        currentPos -= parentInfo.segLength
      }

      finalScore = dp[keyCount]
      if !resultReversed.isEmpty {
        newAssembledSentence = resultReversed.reversed()
      }
      return newAssembledSentence
    }

    // MARK: Private

    private typealias GramState = (gram: Homa.Gram?, isExplicit: Bool, segLength: Int)
  }
}
