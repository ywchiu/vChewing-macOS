// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - LXAssembly.SmartScoringWeights

extension LXAssembly {
  /// Deterministic scorer 的全部可調參數。
  ///
  /// 刻意集中成一個結構、而非散落成一堆常數：這些數字是**互相牽制**的，
  /// 單獨改一個而不看其它幾個是調不出東西的。校準時請整組一起看。
  ///
  /// 尺度的依據（實測自真實原廠辭典）：同音競爭者之間的分差小至 0.001、大至 0.85
  /// （最極端的「城市 −3.510 vs 程式 −4.360」）；而「單字 vs 雙字詞」之間的結構性
  /// 差距動輒 5 以上。故所有加權都必須落在 (0, 1.5] 這個帶內——夠翻同音詞，
  /// 不夠掀分詞。
  public struct SmartScoringWeights: Sendable, Hashable {
    // MARK: Lifecycle

    public init(
      domainSingleVote: Double = 0.75,
      domainDoubleVote: Double = 1.20,
      domainFullVote: Double = 1.45,
      recencyHead: Double = 0.35,
      recencyHalfLife: Double = 4.0,
      sessionVocabulary: Double = 0.12,
      correctionAccepted: Double = 0.0,
      correctionRejected: Double = 0.0
    ) {
      self.domainSingleVote = domainSingleVote
      self.domainDoubleVote = domainDoubleVote
      self.domainFullVote = domainFullVote
      self.recencyHead = recencyHead
      self.recencyHalfLife = recencyHalfLife
      self.sessionVocabulary = sessionVocabulary
      self.correctionAccepted = correctionAccepted
      self.correctionRejected = correctionRejected
    }

    // MARK: Public

    public static let `default` = SmartScoringWeights()

    /// 語境中只有一票投給某領域時，該領域詞彙可得的加權。
    ///
    /// 0.75 刻意**小於**實測到的最大同音分差（0.85，「城市 vs 程式」）：單一個訊號
    /// 不足以推翻辭典的既有排序，那樣太武斷。要翻動它得有第二個吻合的訊號。
    public let domainSingleVote: Double
    /// 兩票投給同一領域時的加權。
    ///
    /// 1.20 的依據：它要能越過實測中「正確答案被壓在第二／第三位」的那些分差
    /// （最大者為「附件 −5.400 vs 復健 −4.258」＝1.14），但仍明顯小於
    /// 「單字 vs 雙字詞」的結構性差距（動輒 5 以上），故不會掀翻分詞。
    public let domainDoubleVote: Double
    /// 三票以上投給同一領域時的加權。仍受 `SmartBoostTable.clamp`（1.5）夾住。
    public let domainFullVote: Double

    /// 最近選過的詞可得的加權（最近一筆）。
    public let recencyHead: Double
    /// recency 的半衰筆數：第 n 筆的加權為 `recencyHead * 0.5^(n / halfLife)`。
    public let recencyHalfLife: Double
    /// 出現在 session 詞彙集合裡（但不在最近幾筆內）的詞可得的加權。
    public let sessionVocabulary: Double

    /// 使用者修正後「改成的那個詞」可得的加權。Phase 3 之前恆為 0。
    public let correctionAccepted: Double
    /// 使用者修正時「被換掉的那個詞」的扣分（正數，套用時取負）。Phase 3 之前恆為 0。
    public let correctionRejected: Double
  }
}

// MARK: - LXAssembly.DeterministicSmartScorer

extension LXAssembly {
  /// 不含任何模型的上下文計分器。
  ///
  /// 訊號有三類，全部是確定性的、可解釋的、而且可以逐項關掉來歸因：
  ///
  /// 1. **領域一致性**：語境詞為自己所屬的領域投票，得票領域的詞彙獲得加權。
  ///    這是冷啟動時唯一的語意訊號——原因見 `SmartDomain` 的說明（本倉沒有共現語料）。
  /// 2. **Session recency**：這段輸入裡剛選過的詞，短期內再出現時加權。
  /// 3. **Session vocabulary**：這段輸入裡出現過的詞，給一點點加權。
  ///
  /// 修正訊號（第 4 類）的權重此階段為 0——它要等 Phase 3 的 `SmartPreferenceStore`
  /// 提供跨 session 的資料之後才有意義；此處先把管道接好。
  ///
  /// - Important: `compileBoostTable(context:)` 的成本與「得票領域的詞彙總數」成正比
  ///   （實測約 100–300 次字典寫入，~10 µs 量級），且**每次語境變動至多跑一次**
  ///   （由 `SmartContextFingerprint` 把關）。它**不在** DP 迴圈內。
  public final class DeterministicSmartScorer: SmartContextScorer {
    // MARK: Lifecycle

    public init(
      weights: SmartScoringWeights = .default,
      preferenceStore: SmartPreferenceStore? = nil
    ) {
      self.weights = weights
      self.preferenceStore = preferenceStore
    }

    // MARK: Public

    public let weights: SmartScoringWeights
    /// 個人用字偏好（Personal Learning v2）。
    ///
    /// `nil`（或 `personal_learning_v2_enabled` 關閉時由宿主不掛載）即代表這一類訊號
    /// 不存在，其餘訊號照常運作。
    public let preferenceStore: SmartPreferenceStore?

    public func scoreAdjustment(
      candidate: String,
      reading _: [String],
      baseScore _: Double,
      context: SmartInputContext
    )
      -> Double {
      // 逐候選路徑：不在 DP 熱路徑上，故直接重算即可。與 `compileBoostTable` 共用
      // 同一組計算，以免兩條路徑給出不同的答案。
      let table = compileBoostTable(context: context)
      return table.adjustment(for: candidate)
    }

    public func compileBoostTable(context: SmartInputContext) -> SmartBoostTable {
      guard !context.isBarren else { return .empty }
      var entries = [String: Double]()

      applyDomainCoherence(context: context, into: &entries)
      applyRecency(context: context, into: &entries)
      applySessionVocabulary(context: context, into: &entries)
      applyCorrections(context: context, into: &entries)
      applyPersonalPreferences(context: context, into: &entries)

      return .init(entries: entries)
    }

    // MARK: Private

    /// App 那一票在 `voters` 集合裡的佔位符。
    ///
    /// 用一個不可能與真實詞彙相撞的字串，好讓「同一個領域不重複計票」的去重邏輯
    /// 對 app 票與詞彙票一視同仁。
    private static let appVoterToken = "\u{0000}app"

    /// 領域一致性。
    ///
    /// 投票者取「游標前的已定詞」與「最近選過的詞」。後者刻意只取前兩筆：再往前
    /// 就不是「現在在講什麼」而是「剛剛在講什麼」了，拿來決定當下的選字容易誤判。
    private func applyDomainCoherence(
      context: SmartInputContext,
      into entries: inout [String: Double]
    ) {
      var votes = [SmartDomain: Double]()
      var voters = [SmartDomain: Set<String>]()

      func castVote(_ word: String) {
        let domains = SmartDomainLexicon.domains(of: word)
        guard !domains.isEmpty else { return }
        // 一詞多領域時票數均分：「報告」同時屬商務與醫療，它不該讓兩個領域都拿滿票。
        let share = 1.0 / Double(domains.count)
        for domain in domains {
          guard voters[domain, default: []].insert(word).inserted else { continue }
          votes[domain, default: 0] += share
        }
      }

      context.precedingValues.forEach(castVote)
      context.recentSelections.prefix(2).forEach(castVote)

      // App 類別也投一票。它是語境的一部分而非學習成果——在編輯器裡打字，技術詞彙
      // 本來就比較可能。這一票的意義在於「單靠一個語境詞不足以翻盤，但語境詞＋
      // 前景 app 兩相吻合就足夠」，也正是 `domainDoubleVote` 那個門檻存在的理由。
      if let appDomain = SmartDomainLexicon.impliedDomain(of: context.appCategory),
         voters[appDomain, default: []].insert(Self.appVoterToken).inserted {
        votes[appDomain, default: 0] += 1
      }

      guard !votes.isEmpty else { return }

      for (domain, voteCount) in votes {
        let boost: Double = switch voteCount {
        case ..<1.5: weights.domainSingleVote
        case ..<2.5: weights.domainDoubleVote
        default: weights.domainFullVote
        }
        guard boost > 0 else { continue }
        for term in SmartDomainLexicon.terms(of: domain) {
          // 語境詞自己不加權：它已經在組字區裡定下來了，替它加權沒有意義，
          // 還會讓「重複同一個詞」變得比應有的容易。
          guard !context.precedingValues.contains(term) else { continue }
          entries[term] = Swift.max(entries[term] ?? 0, boost)
        }
      }
    }

    /// Session recency：剛選過的詞短期內再出現時加權，依名次半衰。
    private func applyRecency(
      context: SmartInputContext,
      into entries: inout [String: Double]
    ) {
      guard weights.recencyHead > 0, weights.recencyHalfLife > 0 else { return }
      for (index, value) in context.recentSelections.enumerated() {
        let decay = pow(0.5, Double(index) / weights.recencyHalfLife)
        entries[value, default: 0] += weights.recencyHead * decay
      }
    }

    /// Session vocabulary：這段輸入裡出現過就給一點點加權。
    private func applySessionVocabulary(
      context: SmartInputContext,
      into entries: inout [String: Double]
    ) {
      guard weights.sessionVocabulary > 0 else { return }
      for value in context.sessionVocabulary {
        entries[value, default: 0] += weights.sessionVocabulary
      }
    }

    /// 個人用字偏好（跨 session）。
    ///
    /// 這一類訊號**蓋過**其餘各類：領域詞表是我猜的，而這是使用者自己教的。
    /// 兩者衝突時，聽使用者的。
    private func applyPersonalPreferences(
      context: SmartInputContext,
      into entries: inout [String: Double]
    ) {
      guard let store = preferenceStore else { return }
      let learned = store.adjustments(
        previous: context.precedingValues.first ?? "",
        appCategory: context.appCategory,
        timestamp: Date().timeIntervalSince1970
      )
      guard !learned.isEmpty else { return }
      for (candidate, value) in learned {
        // 取代而非疊加：疊加會讓「領域詞表也剛好收了這個詞」的候選平白多拿一份，
        // 而那份加權的來源其實是同一個判斷。
        entries[candidate] = value
      }
    }

    /// Session-local 修正訊號。Phase 3 之前兩個權重都是 0，本函式因此是個早退。
    private func applyCorrections(
      context: SmartInputContext,
      into entries: inout [String: Double]
    ) {
      guard weights.correctionAccepted > 0 || weights.correctionRejected > 0 else { return }
      for correction in context.recentCorrections {
        entries[correction.accepted, default: 0] += weights.correctionAccepted
        entries[correction.rejected, default: 0] -= weights.correctionRejected
      }
    }
  }
}
