// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
@testable import LexiconAssembly
import Testing

// MARK: - CandidateRerankerTests

/// `rerankCandidates` 的護欄測試。
///
/// Phase 6 交付的是**介面與契約**，沒有任何模型實作——所以這裡測的不是「重排得好不好」，
/// 而是「一個亂來的重排器能不能把輸入法弄壞」。答案必須是不能。
@Suite("CandidateRerankerTests", .serialized)
struct CandidateRerankerTests {
  // MARK: Internal

  /// 沒掛重排器時，候選原封不動。
  @Test("Without a reranker the candidates are untouched")
  func absentRerankerIsInert() {
    let input = Self.makeCandidates(["甲", "乙", "丙"])
    let output = LXAssembly.rerankCandidates(input, context: .empty, using: nil)
    #expect(output == input)
  }

  /// 正常的重排會被採納。
  @Test("A well-behaved reranker takes effect")
  func wellBehavedRerankerApplies() {
    let input = Self.makeCandidates(["甲", "乙", "丙"])
    let reranker = StubReranker { $0.reversed() }
    let output = LXAssembly.rerankCandidates(input, context: .empty, using: reranker)
    #expect(output.map(\.value) == ["丙", "乙", "甲"])
  }

  /// **憑空生成的候選一律整批放棄。**
  ///
  /// 這是本介面最重要的一條界線：輸入法的職責是把使用者心裡已經有的字找出來，
  /// 不是替他決定要打什麼。一個會生成的重排器必須完全無效，而不是部分生效。
  @Test("A reranker that invents a candidate is discarded wholesale")
  func inventedCandidatesAreRejected() {
    let input = Self.makeCandidates(["甲", "乙"])
    let reranker = StubReranker { _ in Self.makeCandidates(["甲", "乙", "丁"]) }
    let output = LXAssembly.rerankCandidates(input, context: .empty, using: reranker)
    #expect(output == input, "含新增候選的結果必須整批放棄")
  }

  /// 改寫既有候選也算生成。
  @Test("A reranker that rewrites a candidate is discarded wholesale")
  func rewrittenCandidatesAreRejected() {
    let input = Self.makeCandidates(["甲", "乙"])
    let reranker = StubReranker { _ in Self.makeCandidates(["甲", "丙"]) }
    let output = LXAssembly.rerankCandidates(input, context: .empty, using: reranker)
    #expect(output == input)
  }

  /// 重複輸出同一個候選也不接受。
  @Test("A reranker that duplicates a candidate is discarded wholesale")
  func duplicatedCandidatesAreRejected() {
    let input = Self.makeCandidates(["甲", "乙"])
    let reranker = StubReranker { _ in Self.makeCandidates(["甲", "甲"]) }
    let output = LXAssembly.rerankCandidates(input, context: .empty, using: reranker)
    #expect(output == input)
  }

  /// **被重排器剔除的候選不會消失，而是被接到後面。**
  ///
  /// 使用者原本找得到的字，不該因為模型不喜歡它就從清單上不見了。
  @Test("Candidates the reranker drops are appended rather than lost")
  func droppedCandidatesSurvive() {
    let input = Self.makeCandidates(["甲", "乙", "丙"])
    let reranker = StubReranker { candidates in [candidates[2], candidates[0]] }
    let output = LXAssembly.rerankCandidates(input, context: .empty, using: reranker)
    #expect(output.map(\.value) == ["丙", "甲", "乙"])
    #expect(Set(output) == Set(input), "沒有任何候選可以憑空消失")
  }

  /// 逾時即放棄，退回原順序。
  @Test("A reranker that blows the time budget is ignored")
  func slowRerankerIsIgnored() {
    let input = Self.makeCandidates(["甲", "乙", "丙"])
    let reranker = StubReranker { candidates in
      Thread.sleep(forTimeInterval: LXAssembly.CandidateRerankerDefaults.timeBudget * 20)
      return candidates.reversed()
    }
    let output = LXAssembly.rerankCandidates(input, context: .empty, using: reranker)
    #expect(output == input, "逾時的重排結果必須被丟棄")
  }

  /// 只有 Top-N 會被交給重排器，其餘原樣接在後面。
  @Test("Only the head of the list reaches the reranker")
  func onlyTheHeadIsHandedOver() {
    let values = (0 ..< 24).map { "字\($0)" }
    let input = Self.makeCandidates(values)
    var seenCount = 0
    let reranker = StubReranker(maxCandidateCount: 4) { candidates in
      seenCount = candidates.count
      return candidates.reversed()
    }
    let output = LXAssembly.rerankCandidates(input, context: .empty, using: reranker)
    #expect(seenCount == 4, "重排器至多只該看到 4 筆，實得 \(seenCount)")
    #expect(output.count == input.count)
    #expect(Set(output) == Set(input))
    // 尾段順序必須原封不動。
    #expect(Array(output.suffix(20)).map(\.value) == Array(values.suffix(20)))
  }

  /// 回傳空陣列視為失敗。
  @Test("An empty result is treated as failure")
  func emptyResultIsRejected() {
    let input = Self.makeCandidates(["甲", "乙"])
    let reranker = StubReranker { _ in [] }
    let output = LXAssembly.rerankCandidates(input, context: .empty, using: reranker)
    #expect(output == input)
  }

  // MARK: Private

  /// 可注入行為的假重排器。
  private final class StubReranker: LXAssembly.CandidateReranker {
    // MARK: Lifecycle

    init(
      maxCandidateCount: Int = LXAssembly.CandidateRerankerDefaults.maxCandidateCount,
      body: @escaping ([Homa.CandidatePair]) -> [Homa.CandidatePair]
    ) {
      self.maxCandidateCount = maxCandidateCount
      self.body = body
    }

    // MARK: Internal

    let maxCandidateCount: Int

    func rerank(
      context _: LXAssembly.SmartInputContext,
      candidates: [Homa.CandidatePair]
    )
      -> [Homa.CandidatePair] {
      body(candidates)
    }

    // MARK: Private

    private let body: ([Homa.CandidatePair]) -> [Homa.CandidatePair]
  }

  private static func makeCandidates(_ values: [String]) -> [Homa.CandidatePair] {
    values.map { .init(keyArray: ["ㄗˋ"], value: $0) }
  }
}
