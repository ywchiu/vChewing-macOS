// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import TrieKit

// MARK: - LXAssembly.SmartPhraseCandidate

extension LXAssembly {
  /// 一個「正在被觀察、但還沒升格」的詞組。
  public struct SmartPhraseCandidate: Codable, Sendable, Hashable {
    // MARK: Lifecycle

    public init(keyArray: [String], value: String) {
      self.keyArray = keyArray
      self.value = value
    }

    // MARK: Public

    /// 讀音索引鍵陣列。
    public var keyArray: [String]
    /// 詞組本身。
    public var value: String

    /// 被完整、逐字手動組出來的次數。
    public var confirmations: Int = 0
    /// 最近一次被組出來的時間。
    public var lastSeen: Double = 0
    /// 最早被觀察到的時間。
    public var firstSeen: Double = 0
    /// 觀察當下，該讀音在原廠辭典裡已有幾個同長度的競品。
    ///
    /// 這一格是「低歧義」判準的依據：辭典裡本來就有一堆同音詞的讀音，使用者手動組出
    /// 某個組合多半只是這一次要這麼打，不代表要把它記成一個詞；反之，辭典裡根本沒有
    /// 對應詞條的讀音（例如人名），使用者反覆手動組出同一個結果就很說明問題。
    public var ambiguity: Int = 0

    /// 是否已跨過升格門檻。
    public func isPromoted(now: Double) -> Bool {
      guard confirmations >= SmartPhraseStore.confirmationsRequired else { return false }
      guard ambiguity <= SmartPhraseStore.ambiguityCeiling else { return false }
      return ageFactor(now: now) > 0
    }

    /// 年齡因子。與個人偏好表同款的線性核 ＋ 硬截止。
    public func ageFactor(now: Double) -> Double {
      guard lastSeen > 0 else { return 0 }
      guard now > lastSeen else { return 1 }
      let ageDays = (now - lastSeen) / 86_400
      guard ageDays < SmartPhraseStore.lifespanDays else { return 0 }
      let normalized = 1 - (ageDays / SmartPhraseStore.lifespanDays)
      return normalized * normalized
    }

    /// 升格之後，該詞組以什麼權重供給。
    ///
    /// 落在 `scoreFloor ... scoreCeiling` 之間，隨確認次數上升。這個帶的選法很關鍵：
    /// - **必須高於逐字拆開的組合**。「王大明」拆成 王(−5.154)＋大名(−5.317) 是 −10.47，
    ///   任何落在本帶內的分數都贏得過。
    /// - **必須低於真實的原廠詞條**。三音節的「資料庫」是 −4.361，本帶的上限 −6.0
    ///   離它還有 1.6 的距離——使用者自己組出來的東西不該壓過辭典裡本來就有的詞。
    public func promotedScore(now: Double) -> Double {
      let extra = Double(confirmations - SmartPhraseStore.confirmationsRequired)
      let progress = Swift.min(1, log1p(Swift.max(0, extra)) / log(6))
      let span = SmartPhraseStore.scoreCeiling - SmartPhraseStore.scoreFloor
      let raw = SmartPhraseStore.scoreFloor + span * progress
      // 衰減體現在分數上而非直接除名：久沒用的詞組會慢慢沉下去，而不是忽然消失。
      return SmartPhraseStore.scoreFloor + (raw - SmartPhraseStore.scoreFloor) * ageFactor(now: now)
    }
  }
}

// MARK: - LXAssembly.SmartPhraseStore

extension LXAssembly {
  /// 專有名詞與長詞的漸進式學習（Phase 5）。
  ///
  /// ## 為什麼不直接寫進使用者詞庫
  ///
  /// 最省事的做法是「使用者手動組出三次就寫進 `lxUserPhrases`」。本實作**刻意不這麼做**：
  /// 使用者詞庫是使用者自己擁有、自己編輯、會跟著他搬機器的資產，程式自動往裡面塞東西
  /// 是不可逆的污染——他哪天發現詞庫裡多了一堆莫名其妙的詞，也分不清哪些是自己加的。
  ///
  /// 所以升格後的詞組只活在本表裡：它會以掛載來源的身分參與候選供給（因此使用者看得到、
  /// 用得到），但隨時可以整批清掉，而且清掉之後使用者詞庫一個字都沒變。要不要把某個詞
  /// 真的收進詞庫，是使用者自己的決定，本表只負責把「這個詞你已經手動組過 N 次了」
  /// 這件事攤在他面前。
  ///
  /// ## 升格判準
  ///
  /// ```text
  /// 重複使用（confirmations >= 3）
  ///   ＋ 手動確認（每一次 confirmation 都來自逐字手動選字，見 observe 的呼叫端）
  ///   ＋ 低歧義（該讀音在原廠辭典裡的同長度競品 <= 2）
  ///   → 升格為 learned phrase
  /// ```
  public final class SmartPhraseStore {
    // MARK: Lifecycle

    public init(dataURL: URL? = nil) {
      self.dataURL = dataURL
    }

    // MARK: Public

    /// 升格所需的確認次數。
    public static let confirmationsRequired = 3
    /// 升格所容許的最大歧義度（該讀音在原廠辭典裡的同長度競品數）。
    public static let ambiguityCeiling = 2
    /// 詞組的壽命（天）。比個人偏好表更長——專有名詞的使用頻率本來就低。
    public static let lifespanDays: Double = 90
    /// 升格詞組的分數下限（剛升格時）。
    ///
    /// −6.8 的來由：它必須**贏過中低權重的原廠詞條**。實測「陳建治」在原廠辭典裡是
    /// −7.251，而使用者若已經逐字手動組出「陳建志」三次，他要的顯然是後者；
    /// 若把下限訂在該詞條之下（早期版本是 −8.5），升格等於白做——只要辭典裡碰巧有
    /// 任何一個同音詞，學到的東西就永遠浮不上來。
    public static let scoreFloor: Double = -6.8
    /// 升格詞組的分數上限（反覆確認之後）。
    ///
    /// −4.5 是刻意留的天花板：高權重的原廠詞條（三音節的「資料庫」是 −4.361）仍然
    /// 壓在它之上。使用者自己組出來的東西可以贏過冷門詞條，但不該贏過辭典裡的常用詞。
    public static let scoreCeiling: Double = -4.5
    /// 可觀察的詞組音節數範圍。
    ///
    /// 下限 2：單字不構成「詞組」。上限 6：再長的東西多半是整句話，不是詞。
    public static let lengthRange = 2 ... 6
    /// 表的容量上限。
    public static let capacity = 512

    public var dataURL: URL?

    public var count: Int { lock.withLock { candidates.count } }

    /// 觀察一次「使用者逐字手動組出來的詞組」。
    ///
    /// - Parameters:
    ///   - keyArray: 該詞組的讀音索引鍵陣列。
    ///   - value: 詞組本身。
    ///   - ambiguity: 該讀音在原廠辭典裡已有的同長度競品數，由呼叫端查得。
    public func observe(
      keyArray: [String],
      value: String,
      ambiguity: Int,
      timestamp: Double
    ) {
      guard Self.lengthRange.contains(keyArray.count) else { return }
      guard !value.isEmpty, value.count == keyArray.count else { return }
      lock.withLock {
        let key = Key(keyArray: keyArray, value: value)
        var candidate = candidates[key] ?? .init(keyArray: keyArray, value: value)
        if candidate.firstSeen == 0 { candidate.firstSeen = timestamp }
        candidate.lastSeen = timestamp
        candidate.confirmations += 1
        candidate.ambiguity = ambiguity
        candidates[key] = candidate
        indexByKeyArray[keyArray, default: []].insert(key)
        evictIfNeeded()
        isDirty = true
      }
    }

    /// 取出所有已升格、且讀音與給定索引鍵相符的詞組。
    ///
    /// - Complexity: O(該讀音底下的詞組數)，通常是 0 或 1。
    ///   **這條路徑在查詢熱路徑上**：本表一旦掛上 `LXFacade`，每一次元圖查詢都會經過
    ///   它一次。早期版本在這裡線性掃過整張表（上限 512 筆）並持鎖比對讀音陣列，
    ///   實測讓 `assemble()` 的 p95 多出約 17%。故以讀音陣列為鍵建索引。
    public func promotedGrams(for keyArray: [String], timestamp: Double) -> [Homa.Gram] {
      guard Self.lengthRange.contains(keyArray.count) else { return [] }
      return lock.withLock {
        guard let keys = indexByKeyArray[keyArray], !keys.isEmpty else { return [] }
        return keys.compactMap { key in
          guard let candidate = candidates[key], candidate.isPromoted(now: timestamp) else {
            return nil
          }
          return Homa.Gram(
            keyArray: candidate.keyArray,
            current: candidate.value,
            probability: candidate.promotedScore(now: timestamp)
          )
        }
      }
    }

    /// 是否有已升格、且讀音相符的詞組。供輕量在庫檢查使用。
    public func hasPromotedGrams(for keyArray: [String], timestamp: Double) -> Bool {
      guard Self.lengthRange.contains(keyArray.count) else { return false }
      return lock.withLock {
        guard let keys = indexByKeyArray[keyArray] else { return false }
        return keys.contains { candidates[$0]?.isPromoted(now: timestamp) == true }
      }
    }

    /// 目前的觀察清單，供設定介面呈現「你已經手動組過這些詞」。
    public func snapshot(timestamp: Double) -> [(candidate: SmartPhraseCandidate, isPromoted: Bool)] {
      lock.withLock {
        candidates.values
          .map { ($0, $0.isPromoted(now: timestamp)) }
          .sorted { $0.0.confirmations > $1.0.confirmations }
      }
    }

    /// 清除全部已學詞組。
    public func clearAll() {
      lock.withLock {
        candidates.removeAll()
        indexByKeyArray.removeAll()
        isDirty = true
      }
      if let dataURL { try? FileManager.default.removeItem(at: dataURL) }
    }

    /// 忘掉指定的詞組。
    public func forget(values: Set<String>) {
      guard !values.isEmpty else { return }
      lock.withLock {
        candidates.keys.filter { values.contains($0.value) }.forEach { remove($0) }
        isDirty = true
      }
    }

    // MARK: Internal

    struct Key: Hashable, Codable, Sendable {
      let keyArray: [String]
      let value: String
    }

    var candidates: [Key: SmartPhraseCandidate] = [:]
    /// 讀音陣列 → 該讀音底下的詞組鍵。查詢熱路徑靠它避免全表掃描。
    var indexByKeyArray: [[String]: Set<Key>] = [:]
    var isDirty = false

    func lockedSnapshotForArchive() -> [SmartPhraseCandidate] {
      lock.withLock { candidates.values.sorted { $0.lastSeen > $1.lastSeen } }
    }

    func lockedIngest(_ incoming: [SmartPhraseCandidate]) {
      lock.withLock {
        for candidate in incoming {
          let key = Key(keyArray: candidate.keyArray, value: candidate.value)
          candidates[key] = candidate
          indexByKeyArray[candidate.keyArray, default: []].insert(key)
        }
        evictIfNeeded()
      }
    }

    func lockedIsDirty() -> Bool { lock.withLock { isDirty } }

    func lockedSetDirty(_ newValue: Bool) { lock.withLock { isDirty = newValue } }

    // MARK: Private

    private let lock = NSLock()

    /// 容量控制：淘汰「確認次數最少、且最久沒用」者。
    private func evictIfNeeded() {
      guard candidates.count > Self.capacity else { return }
      let doomed = candidates.keys
        .sorted { lhs, rhs in
          let l = candidates[lhs], r = candidates[rhs]
          if (l?.confirmations ?? 0) != (r?.confirmations ?? 0) {
            return (l?.confirmations ?? 0) < (r?.confirmations ?? 0)
          }
          return (l?.lastSeen ?? 0) < (r?.lastSeen ?? 0)
        }
        .prefix(candidates.count - Self.capacity)
      doomed.forEach { remove($0) }
    }

    /// 移除一筆詞組，並同步維護索引。
    private func remove(_ key: Key) {
      candidates.removeValue(forKey: key)
      indexByKeyArray[key.keyArray]?.remove(key)
      if indexByKeyArray[key.keyArray]?.isEmpty == true {
        indexByKeyArray.removeValue(forKey: key.keyArray)
      }
    }
  }
}

// MARK: - LXAssembly.SmartPhraseSupplier

extension LXAssembly {
  /// 把 `SmartPhraseStore` 包成可掛載的辭典來源。
  ///
  /// 走的是本倉既有的多來源掛載機制（`LXFacade.mountGramSupplier`），因此升格後的詞組
  /// 會自然地出現在候選窗與組句裡，不必另外在查詢管線上開洞。
  public final class SmartPhraseSupplier: LexiconGramSupplierProtocol {
    // MARK: Lifecycle

    public init(store: SmartPhraseStore) {
      self.store = store
    }

    // MARK: Public

    public let store: SmartPhraseStore

    public func hasGrams(
      _ keys: [String],
      filterType _: VanguardTrie.Trie.EntryType,
      partiallyMatch: Bool,
      partiallyMatchedKeysHandler _: ((Set<[String]>) -> ())?
    )
      -> Bool {
      // 部分匹配不支援：升格詞組是「完整讀音 → 完整詞」的對應，
      // 讓它參與前綴匹配只會在狂拼等場景下冒出半截的東西。
      guard !partiallyMatch else { return false }
      return store.hasPromotedGrams(for: keys, timestamp: Date().timeIntervalSince1970)
    }

    public func queryGrams(
      _ keys: [String],
      filterType _: VanguardTrie.Trie.EntryType,
      partiallyMatch: Bool,
      partiallyMatchedKeysPostHandler _: ((Set<[String]>) -> ())?
    )
      -> [Homa.Gram] {
      guard !partiallyMatch else { return [] }
      return store.promotedGrams(for: keys, timestamp: Date().timeIntervalSince1970)
    }

    public func queryAssociatedPhrasesAsGrams(
      _: (keyArray: [String], value: String),
      anterior _: String?,
      filterType _: VanguardTrie.Trie.EntryType
    )
      -> [Homa.Gram]? {
      // 關聯詞語不由本來源供給：它是另一種語義（「這個詞後面接什麼」），
      // 與「這個讀音對應什麼詞」無關。
      nil
    }
  }
}
