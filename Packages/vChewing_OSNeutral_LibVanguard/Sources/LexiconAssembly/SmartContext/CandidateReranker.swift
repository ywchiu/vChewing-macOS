// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa

// MARK: - LXAssembly.CandidateReranker

extension LXAssembly {
  /// 候選重排器的介面。**本階段只有介面，沒有任何實作。**
  ///
  /// 這裡預留的是「日後可以接一個裝置端小模型」的位置——CoreML、ONNX、或任何其它
  /// 形式都行。之所以先只定介面，是因為介面本身就能把「這東西**不准**做什麼」
  /// 寫死下來；等到真的有模型可接時，那些界線已經是既成事實，不必再爭論。
  ///
  /// ## 契約（實作者必須遵守，呼叫端會強制執行）
  ///
  /// 1. **只重排，不生成。** 回傳的候選必須是傳入候選的**子集合**，一個都不能新增、
  ///    不能改寫。呼叫端會驗證這一點並在違反時整批放棄（見 `rerankCandidates`）。
  ///    輸入法的職責是把使用者心裡已經有的字找出來，不是替他決定要打什麼。
  /// 2. **只看 Top-N。** 呼叫端至多餵 `maxCandidateCount` 筆。使用者不會翻到第五頁
  ///    才發現模型的價值，而讓模型看完整份清單只會讓延遲與清單長度成正比。
  /// 3. **同步、有界、不得阻塞。** 它在候選窗開啟的路徑上被呼叫，超過
  ///    `timeBudget` 即視為失敗並退回原順序。不得做 I/O、不得等鎖、不得碰網路。
  /// 4. **可以整個拿掉。** 本協定的任何型別都不得出現在 `Homa` 的簽章裡；
  ///    把這個檔案與它的呼叫點刪掉之後，輸入法必須仍是一個完整可用的輸入法。
  public protocol CandidateReranker: AnyObject {
    /// 本重排器願意接受的候選數量上限。
    var maxCandidateCount: Int { get }

    /// 重排。
    ///
    /// - Parameters:
    ///   - context: 當拍語境快照。
    ///   - candidates: 至多 `maxCandidateCount` 筆的候選，依現有排序。
    /// - Returns: 重排後的候選。必須是輸入的子集合（順序可變、可剔除，不可新增）。
    func rerank(
      context: SmartInputContext,
      candidates: [Homa.CandidatePair]
    )
      -> [Homa.CandidatePair]
  }
}

// MARK: - Defaults & guardrails

extension LXAssembly {
  public enum CandidateRerankerDefaults {
    /// 餵給重排器的候選數量上限。
    public static let maxCandidateCount = 16
    /// 時間預算（秒）。超過即放棄本次重排、退回原順序。
    ///
    /// 2 ms 的依據：每次敲鍵的整體預算是半個 60 Hz 畫格（約 8 ms），而候選窗的
    /// 重排只是其中一小段。訂在這裡，意味著一個慢到有感的模型會**自動被繞過**，
    /// 而不是把整個輸入法拖慢——寧可不重排，不可卡住打字。
    public static let timeBudget: TimeInterval = 0.002
  }

  /// 以契約為準呼叫一個重排器。
  ///
  /// 所有的「不准做什麼」都在這裡強制執行，而不是仰賴實作者自律：外部模型遲早會有
  /// 行為不如預期的一天，那一天輸入法必須只是「沒有重排」，而不是「壞掉」。
  ///
  /// - Returns: 重排後的候選；重排器缺席、逾時、或違反子集合契約時，回傳原本的順序。
  public static func rerankCandidates(
    _ candidates: [Homa.CandidatePair],
    context: SmartInputContext,
    using reranker: (any CandidateReranker)?
  )
    -> [Homa.CandidatePair] {
    guard let reranker, !candidates.isEmpty else { return candidates }
    let limit = Swift.min(
      Swift.max(1, reranker.maxCandidateCount),
      CandidateRerankerDefaults.maxCandidateCount
    )
    let head = Array(candidates.prefix(limit))
    let tail = Array(candidates.dropFirst(head.count))

    let started = DispatchTime.now().uptimeNanoseconds
    let reranked = reranker.rerank(context: context, candidates: head)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000_000

    guard elapsed <= CandidateRerankerDefaults.timeBudget else { return candidates }
    // 子集合驗證：不得新增、不得改寫、不得重複。違反即整批放棄。
    guard !reranked.isEmpty, reranked.count <= head.count else { return candidates }
    var remaining = Set(head)
    for candidate in reranked {
      guard remaining.remove(candidate) != nil else { return candidates }
    }
    // 被重排器剔除的候選不丟掉、接在後面：使用者原本找得到的字，
    // 不該因為模型不喜歡它就從清單上消失。
    let dropped = head.filter { remaining.contains($0) }
    return reranked + dropped + tail
  }
}
