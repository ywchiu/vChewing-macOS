// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - LXAssembly.SmartPreferenceEntry

extension LXAssembly {
  /// 一筆個人用字偏好。
  ///
  /// 欄位對應需求書列出的那一組（reading / candidate / previous / anterior /
  /// frequency / correction count / last used / app / confidence）。其中
  /// `confidence` 刻意**不存**、而是每次讀取時依當下時間重算——它會隨時間衰減，
  /// 存下來的那一刻就過期了。
  public struct SmartPreferenceEntry: Codable, Sendable, Hashable {
    // MARK: Lifecycle

    public init(
      reading: String,
      candidate: String,
      previous: String,
      anterior: String,
      appCategory: SmartAppCategory
    ) {
      self.reading = reading
      self.candidate = candidate
      self.previous = previous
      self.anterior = anterior
      self.appCategory = appCategory
    }

    // MARK: Public

    /// 該候選的讀音索引鍵（以組字器分隔符連接）。供清除與診斷使用。
    public var reading: String
    /// 候選詞本身。
    public var candidate: String
    /// 前一個詞；無前文時為空字串。
    public var previous: String
    /// 再往前一個詞；無則為空字串。
    public var anterior: String
    /// 記錄當下所處的 app 粗類別。
    public var appCategory: SmartAppCategory

    /// 被顯式選中的次數。
    public var frequency: Int = 0
    /// 作為「使用者把別的詞改成它」的次數。這是比 `frequency` 強得多的訊號。
    public var correctionCount: Int = 0
    /// 作為「使用者把它改成別的詞」的次數——也就是被退掉幾次。
    public var demotionCount: Int = 0
    /// 最近一次被選中的時間（Unix 時間）。
    public var lastUsed: Double = 0
    /// 最早被記錄的時間。僅供診斷。
    public var firstSeen: Double = 0

    // MARK: - Derived

    /// 年齡因子：與 POM 同款的「線性核 ＋ 硬截止」，而非半衰期。
    ///
    /// 與 `LXPerceptor.calculateWeight` 保持同一種衰減形狀是刻意的：兩套記憶若用
    /// 不同的遺忘曲線，使用者會感覺到「有些詞忘得快、有些忘得慢」卻說不出所以然。
    /// 壽命取 30 天（POM 是 8 天）——POM 記的是「這一陣子的打字慣性」，本表記的是
    /// 「這個人的用字偏好」，後者本來就該活得久一些。
    public func ageFactor(now: Double, lifespanDays: Double = SmartPreferenceStore.lifespanDays) -> Double {
      guard lastUsed > 0, lifespanDays > 0 else { return 0 }
      guard now > lastUsed else { return 1 }
      let ageDays = (now - lastUsed) / 86_400
      guard ageDays < lifespanDays else { return 0 }
      let normalized = 1 - (ageDays / lifespanDays)
      return normalized * normalized
    }

    /// 信心度，落在 [0, 1]。
    ///
    /// 修正（correction）的權重刻意遠高於單純選字（frequency）：使用者特地把 A 改成 B，
    /// 是比「B 剛好排第一所以按了空格」強得多的證據。
    ///
    /// 低於 `SmartPreferenceStore.confidenceThreshold` 的紀錄**完全不參與評分**——
    /// 這就是「偶爾選過一次特殊詞不會永久污染一般輸入」那條要求的實作：單次選字的
    /// 信心度約 0.15，要跨過門檻得累積到兩三次修正、或更多次的重複使用。
    public func confidence(now: Double) -> Double {
      let evidence = 0.18 * log1p(Double(frequency)) + 0.45 * log1p(Double(correctionCount))
      return Swift.min(1, evidence) * ageFactor(now: now)
    }
  }
}

// MARK: - LXAssembly.SmartPreferenceStore

extension LXAssembly {
  /// 個人用字偏好的跨 session 儲存體（Personal Learning v2）。
  ///
  /// ## 與 POM 的關係：**擴充，不取代**
  ///
  /// `LXPerceptor`（POM）繼續做它原本的事——它的記憶仍然以 n-gram 的形式直接餵進
  /// Homa 的組句、它的檔案格式一個位元組都沒動、它的既有測試全數照跑。本表是**另一個
  /// 檔案、另一條管道**，補的是 POM 結構上表達不了的兩件事：
  ///
  /// 1. **負向訊號**。POM 只有「記住」與「硬刪」（`bleachSpecifiedSuggestions`）兩種
  ///    操作，沒有「這個詞被退掉過，請稍微往後排」這種中間態。
  /// 2. **App 維度**。POM 的 ngramKey 裡沒有這一格，加進去會動到既有檔案格式。
  ///
  /// ## 防污染
  ///
  /// - 未跨過 `confidenceThreshold` 的紀錄不參與評分（單次選字跨不過去）。
  /// - 負向訊號有獨立且**很小**的上限（`demotionCap`），且與正向訊號一樣會衰減——
  ///   使用者改過一次 A→B 之後，A 只是稍微往後，不會被永久打死，停用一陣子就回來了。
  /// - 每個 app 桶與全表都有筆數上限，滿了以 `lastUsed` 最舊者淘汰。
  public final class SmartPreferenceStore {
    // MARK: Lifecycle

    public init(dataURL: URL? = nil) {
      self.dataURL = dataURL
    }

    // MARK: Public

    /// 紀錄的壽命（天）。超過即完全失效。
    public static let lifespanDays: Double = 30
    /// 參與評分所需的最低信心度。
    ///
    /// 0.35 的來由：單次選字的信心度約 `0.18 * ln(2) ≈ 0.125`，兩次約 0.20，
    /// 一次修正約 `0.45 * ln(2) ≈ 0.31`，兩次修正約 0.49。也就是說——**重複的修正
    /// 兩次就能生效，而單純選過幾次不行**。這正是需求書要的那條線。
    public static let confidenceThreshold: Double = 0.35
    /// 正向加權的上限。
    public static let promotionCap: Double = 1.1
    /// 負向加權的上限（絕對值）。
    ///
    /// 刻意只有正向的一半不到：退掉一個詞的意思是「這次不要它」，不是「永遠別再給我」。
    /// 0.5 足以在同音競爭中把它壓到第二位，卻遠不足以把它擠出候選窗。
    public static let demotionCap: Double = 0.5
    /// 全表筆數上限。
    public static let totalCapacity = 2_000
    /// 每個 app 粗類別的筆數上限。
    public static let perAppCapacity = 256

    /// 存檔位置。
    public var dataURL: URL?

    /// 目前的紀錄筆數。
    public var count: Int { lock.withLock { entries.count } }

    /// 記錄一次顯式選字。
    ///
    /// - Parameters:
    ///   - displaced: 這次選字換掉的是哪個詞（沒換掉任何東西時為 nil）。
    ///     非 nil 即構成一次「修正」，正負訊號一併寫入。
    public func note(
      reading: String,
      candidate: String,
      previous: String,
      anterior: String,
      appCategory: SmartAppCategory,
      displaced: String?,
      timestamp: Double
    ) {
      guard !candidate.isEmpty else { return }
      lock.withLock {
        let isCorrection = displaced.map { !$0.isEmpty && $0 != candidate } ?? false
        upsert(
          key: .init(candidate: candidate, previous: previous, appCategory: appCategory),
          timestamp: timestamp
        ) { entry in
          entry.reading = reading
          entry.anterior = anterior
          entry.frequency += 1
          if isCorrection { entry.correctionCount += 1 }
        }
        // 負向訊號：被換掉的那個詞，在**同一個語境下**稍微往後排。
        // 刻意不做成全域性的——使用者在「一家」後面不要「函式」，不代表他在
        // 「呼叫」後面也不要。
        if isCorrection, let displaced {
          upsert(
            key: .init(candidate: displaced, previous: previous, appCategory: appCategory),
            timestamp: timestamp
          ) { entry in
            entry.demotionCount += 1
          }
        }
        evictIfNeeded()
        isDirty = true
      }
    }

    /// 依語境取出可用的加權項。
    ///
    /// - Returns: 候選詞 → 加權值。已篩掉信心度不足者，數值已夾在上下限內。
    public func adjustments(
      previous: String,
      appCategory: SmartAppCategory,
      timestamp: Double
    )
      -> [String: Double] {
      lock.withLock {
        var result = [String: Double]()
        // 語境相符者（含「無前文」那一桶）與 app 相符者都納入，取較強的一邊。
        for bucket in [previous, ""] {
          guard let candidates = indexByPrevious[bucket] else { continue }
          for key in candidates {
            guard let entry = entries[key] else { continue }
            // App 維度：只採計「同一個 app 類別」或「不分 app」的紀錄。
            guard key.appCategory == appCategory || key.appCategory == .other else { continue }
            let value = score(of: entry, now: timestamp)
            guard value != 0 else { continue }
            let existing = result[entry.candidate] ?? 0
            result[entry.candidate] = abs(value) > abs(existing) ? value : existing
          }
        }
        return result
      }
    }

    /// 這個 (語境, 候選) 組合是否**只**在別的 app 類別底下被學過。
    ///
    /// ## 這個查詢是為了什麼
    ///
    /// POM 的記憶鍵裡沒有 app 這一格，所以「在聊天室裡教會的詞」到了編輯器裡照樣會被
    /// 餵進組句。而 POM 餵進去的是 **contextual gram**，其權重落在 (−0.115, 0)，
    /// 對上 unigram 基線的 −5 上下——足足贏五個數量級的分。SmartContext 的加權上限
    /// 是 ±1.5，**結構上不可能**把它壓回去。
    ///
    /// 也就是說，跨 app 污染這件事沒辦法在加權層解決，只能在 POM 的注入端攔。
    /// 本查詢即為那道攔截提供依據，判準刻意收得很窄：**只有在「這個組合在別處學過、
    /// 而且在這裡從沒學過」時才回 true**。只要使用者在當前 app 裡也用過一次，
    /// 攔截立刻失效——寧可漏攔，不可誤攔。
    public func wasLearnedOnlyElsewhere(
      candidate: String,
      previous: String,
      currentAppCategory: SmartAppCategory,
      timestamp: Double
    )
      -> Bool {
      guard !candidate.isEmpty else { return false }
      return lock.withLock {
        let here = Key(candidate: candidate, previous: previous, appCategory: currentAppCategory)
        // 在當前 app 類別底下有過紀錄（哪怕只有一次）就不攔。
        if let entry = entries[here], entry.frequency > 0 || entry.correctionCount > 0 {
          return false
        }
        // 不分 app 的那一桶同理。
        let neutral = Key(candidate: candidate, previous: previous, appCategory: .other)
        if currentAppCategory != .other, let entry = entries[neutral],
           entry.frequency > 0 || entry.correctionCount > 0 {
          return false
        }
        // 別處學過、且該紀錄尚未過期。
        guard let siblings = indexByPrevious[previous] else { return false }
        return siblings.contains { key in
          guard key.candidate == candidate, key.appCategory != currentAppCategory else { return false }
          guard let entry = entries[key] else { return false }
          return entry.confidence(now: timestamp) >= Self.confidenceThreshold
        }
      }
    }

    /// 清除全部學習資料（記憶體與磁碟）。
    public func clearAll() {
      lock.withLock {
        entries.removeAll()
        indexByPrevious.removeAll()
        isDirty = true
      }
      if let dataURL { try? FileManager.default.removeItem(at: dataURL) }
    }

    /// 只清除某個 app 粗類別底下的紀錄。
    public func resetAppSpecificLearning(_ appCategory: SmartAppCategory) {
      lock.withLock {
        let doomed = entries.keys.filter { $0.appCategory == appCategory }
        doomed.forEach { remove($0) }
        isDirty = true
      }
    }

    /// 清除指定候選詞的所有紀錄。
    public func forget(candidates: Set<String>) {
      guard !candidates.isEmpty else { return }
      lock.withLock {
        let doomed = entries.keys.filter { candidates.contains($0.candidate) }
        doomed.forEach { remove($0) }
        isDirty = true
      }
    }

    /// 供診斷／設定介面列出目前學到的東西。
    public func snapshot(timestamp: Double) -> [(entry: SmartPreferenceEntry, confidence: Double)] {
      lock.withLock {
        entries.values
          .map { ($0, $0.confidence(now: timestamp)) }
          .sorted { $0.1 > $1.1 }
      }
    }

    // MARK: Internal

    /// 索引鍵。
    ///
    /// `anterior` 刻意**不進索引鍵**：三層語境會把資料切得太碎，每一格都湊不到足夠的
    /// 次數去跨過信心門檻。它仍然存在 entry 裡供日後需要時使用。
    struct Key: Hashable, Codable, Sendable {
      let candidate: String
      let previous: String
      let appCategory: SmartAppCategory
    }

    // 下述三項一律由 `lock` 把守。持久化層位於另一個檔案，**不得**直接碰它們——
    // 一律經由本節末尾那幾個已經取過鎖的內部存取器。
    var entries: [Key: SmartPreferenceEntry] = [:]
    var indexByPrevious: [String: Set<Key>] = [:]
    /// 自上次存檔以來是否有異動。
    var isDirty = false

    // MARK: - 供持久化層使用的上鎖存取器

    /// 取出全部紀錄的快照（依最近使用時間降冪）。
    func lockedEntriesSnapshot() -> [SmartPreferenceEntry] {
      lock.withLock { entries.values.sorted { $0.lastUsed > $1.lastUsed } }
    }

    /// 把一批紀錄收進表內並重建索引。
    func lockedIngest(_ incoming: [SmartPreferenceEntry]) {
      lock.withLock {
        for entry in incoming {
          let key = Key(
            candidate: entry.candidate,
            previous: entry.previous,
            appCategory: entry.appCategory
          )
          entries[key] = entry
          indexByPrevious[key.previous, default: []].insert(key)
        }
        evictIfNeeded()
      }
    }

    func lockedIsDirty() -> Bool {
      lock.withLock { isDirty }
    }

    func lockedSetDirty(_ newValue: Bool) {
      lock.withLock { isDirty = newValue }
    }

    /// 單筆紀錄的加權值。正為提升、負為壓低。
    func score(of entry: SmartPreferenceEntry, now: Double) -> Double {
      let age = entry.ageFactor(now: now)
      guard age > 0 else { return 0 }
      // 負向訊號**不受信心門檻把守**：它本來就小（上限 0.5），而且「使用者剛把它改掉」
      // 這件事本身就是即時而明確的意思表示，不需要累積到有信心才承認。
      let demotion = entry.demotionCount > 0
        ? Swift.min(Self.demotionCap, 0.30 * log1p(Double(entry.demotionCount))) * age
        : 0
      let confidence = entry.confidence(now: now)
      let promotion = confidence >= Self.confidenceThreshold
        ? Swift.min(Self.promotionCap, confidence * Self.promotionCap)
        : 0
      return promotion - demotion
    }

    // MARK: Private

    private let lock = NSLock()

    private func upsert(key: Key, timestamp: Double, _ mutate: (inout SmartPreferenceEntry) -> ()) {
      var entry = entries[key] ?? .init(
        reading: "",
        candidate: key.candidate,
        previous: key.previous,
        anterior: "",
        appCategory: key.appCategory
      )
      if entry.firstSeen == 0 { entry.firstSeen = timestamp }
      entry.lastUsed = timestamp
      mutate(&entry)
      entries[key] = entry
      indexByPrevious[key.previous, default: []].insert(key)
    }

    private func remove(_ key: Key) {
      entries.removeValue(forKey: key)
      indexByPrevious[key.previous]?.remove(key)
      if indexByPrevious[key.previous]?.isEmpty == true {
        indexByPrevious.removeValue(forKey: key.previous)
      }
    }

    /// 容量控制：先修剪過胖的 app 桶，再修剪全表。一律淘汰 `lastUsed` 最舊者。
    private func evictIfNeeded() {
      var byApp = [SmartAppCategory: [Key]]()
      for key in entries.keys { byApp[key.appCategory, default: []].append(key) }
      for (_, keys) in byApp where keys.count > Self.perAppCapacity {
        let doomed = keys
          .sorted { (entries[$0]?.lastUsed ?? 0) < (entries[$1]?.lastUsed ?? 0) }
          .prefix(keys.count - Self.perAppCapacity)
        doomed.forEach { remove($0) }
      }
      guard entries.count > Self.totalCapacity else { return }
      let doomed = entries.keys
        .sorted { (entries[$0]?.lastUsed ?? 0) < (entries[$1]?.lastUsed ?? 0) }
        .prefix(entries.count - Self.totalCapacity)
      doomed.forEach { remove($0) }
    }
  }
}
