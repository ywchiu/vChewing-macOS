// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - LXAssembly.TypingJournalRecord

extension LXAssembly {
  /// 打字日誌的一筆紀錄。
  public struct TypingJournalRecord: Codable, Sendable, Hashable, Identifiable {
    // MARK: Lifecycle

    public init(
      id: UUID = UUID(),
      timestamp: Double,
      readings: [String],
      committed: String,
      precedingContext: [String],
      appCategory: SmartAppCategory
    ) {
      self.id = id
      self.timestamp = timestamp
      self.readings = readings
      self.committed = committed
      self.precedingContext = precedingContext
      self.appCategory = appCategory
    }

    // MARK: Public

    public let id: UUID
    public let timestamp: Double
    /// 該段文字的讀音索引鍵，逐音節。
    public let readings: [String]
    /// 實際上屏的文字。
    public let committed: String
    /// 前文（至多數個詞），供 AI 判讀語境。
    public let precedingContext: [String]
    /// 當下所處的 app 粗類別。**只存類別，不存 bundle identifier。**
    public let appCategory: SmartAppCategory
  }
}

// MARK: - LXAssembly.TypingJournal

extension LXAssembly {
  /// 「學習階段」的打字日誌（Phase 7）。
  ///
  /// ## 這東西錄的是使用者打的每一個字
  ///
  /// 這一點必須講在最前面，因為它決定了本類別的每一個設計決定：**上屏的文字包含
  /// 使用者打的一切**——打在非安全欄位裡的密碼、私訊、病歷、金流資訊。所以本類別的
  /// 主體不是「怎麼錄」，而是「什麼時候絕對不錄」：
  ///
  /// 1. **預設一個 app 都不錄。** 允許清單是 opt-in 的（`allowedAppCategories` 預設為空）。
  ///    「預設全錄、不想要再排除」對這種資料是錯的預設——使用者忘了排除的代價，
  ///    遠大於他忘了加入的代價。
  /// 2. **安全輸入一律不錄。** 呼叫端負責在 `IsSecureEventInputEnabled` 為真、或客體為
  ///    `com.apple.SecurityAgent` 時完全不呼叫本類別（本倉已有 `SecurityAgentHelper`
  ///    與 `silentMode` 可用）。
  /// 3. **硬性時限。** 開啟後超過 `sessionLimitHours` 即自動失效，不必使用者記得關。
  ///    「不小心開著就忘了」不該演變成一份無限長的生活紀錄。
  /// 4. **有界。** 筆數上限，滿了淘汰最舊者。
  /// 5. **永不自動上傳。** 本類別沒有任何網路能力；匯出是一個產生檔案的動作，
  ///    把檔案交給誰是使用者自己的事。
  public final class TypingJournal {
    // MARK: Lifecycle

    public init(dataURL: URL? = nil) {
      self.dataURL = dataURL
    }

    // MARK: Public

    /// 錄製階段的硬性時限（小時）。
    public static let sessionLimitHours: Double = 8
    /// 筆數上限。
    public static let capacity = 5_000

    public var dataURL: URL?

    /// 允許錄製的 app 粗類別。**預設為空，也就是什麼都不錄。**
    public private(set) var allowedAppCategories: Set<SmartAppCategory> = []
    /// 錄製階段的開始時間；`nil` 代表未啟用。
    public private(set) var activatedAt: Double?

    public var count: Int { lock.withLock { records.count } }

    /// 目前是否真的在錄。
    ///
    /// 「偏好設定打開了」不等於「正在錄」——還要有允許清單、而且沒有超過時限。
    public func isRecording(now: Double) -> Bool {
      lock.withLock { isRecordingLocked(now: now) }
    }

    /// 啟用錄製階段。
    /// - Parameter allowedAppCategories: 允許錄製的 app 粗類別；傳空集合等同於不錄。
    public func activate(allowedAppCategories: Set<SmartAppCategory>, now: Double) {
      lock.withLock {
        self.allowedAppCategories = allowedAppCategories
        activatedAt = allowedAppCategories.isEmpty ? nil : now
      }
    }

    /// 停止錄製。已錄的內容**不會**被一併清掉——清除是另一個獨立的動作，
    /// 使用者可能只是想先停下來、稍後再匯出。
    public func deactivate() {
      lock.withLock {
        activatedAt = nil
        allowedAppCategories = []
      }
    }

    /// 距離自動失效還剩多久（秒）。未啟用時為 nil。
    public func remainingTime(now: Double) -> TimeInterval? {
      lock.withLock {
        guard let activatedAt else { return nil }
        let deadline = activatedAt + Self.sessionLimitHours * 3_600
        return Swift.max(0, deadline - now)
      }
    }

    /// 記錄一筆。不在錄製狀態、或該 app 類別不在允許清單內時是個早退。
    public func record(
      readings: [String],
      committed: String,
      precedingContext: [String],
      appCategory: SmartAppCategory,
      timestamp: Double
    ) {
      guard !readings.isEmpty, !committed.isEmpty else { return }
      lock.withLock {
        guard isRecordingLocked(now: timestamp) else { return }
        guard allowedAppCategories.contains(appCategory) else { return }
        records.append(
          .init(
            timestamp: timestamp,
            readings: readings,
            committed: committed,
            precedingContext: precedingContext,
            appCategory: appCategory
          )
        )
        if records.count > Self.capacity {
          records.removeFirst(records.count - Self.capacity)
        }
        isDirty = true
      }
    }

    /// 全部紀錄的快照。
    public func snapshot() -> [TypingJournalRecord] {
      lock.withLock { records }
    }

    /// 最近幾則、且仍在時間窗內的同類 app 上屏內容，由遠而近。
    ///
    /// 供新一筆紀錄填 `precedingContext` 用。之所以讓日誌自己回答這件事，是因為它
    /// 本來就照時序存著這些東西——再叫呼叫端另外維護一份前文環狀緩衝，只會多出
    /// 一份會不一致的狀態。掃描長度以 `limit` 為界，與日誌總長無關。
    public func recentCommitted(
      limit: Int,
      within window: Double,
      now: Double,
      appCategory: SmartAppCategory
    )
      -> [String] {
      guard limit > 0 else { return [] }
      return lock.withLock {
        var collected: [String] = []
        for record in records.reversed() {
          guard collected.count < limit else { break }
          guard now - record.timestamp <= window else { break }
          guard record.appCategory == appCategory else { break }
          collected.append(record.committed)
        }
        return collected.reversed()
      }
    }

    /// 清除全部紀錄（記憶體與磁碟）。
    public func clearAll() {
      lock.withLock {
        records.removeAll()
        isDirty = true
      }
      if let dataURL { try? FileManager.default.removeItem(at: dataURL) }
    }

    /// 匯出成 JSONL（每行一筆 JSON）。
    ///
    /// 選 JSONL 而非單一 JSON 陣列，是為了讓使用者可以直接把檔案（或其中一段）
    /// 貼給任何一個 AI，也方便他先用肉眼掃過、把不想外流的行自己刪掉——
    /// **這份東西要交給誰、交出去多少，是使用者的決定，不是程式的。**
    public func exportAsJSONL() -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return snapshot().compactMap { record in
        guard let data = try? encoder.encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
      }.joined(separator: "\n")
    }

    /// 把匯出內容寫到指定位置。
    @discardableResult
    public func exportToFile(at url: URL) -> Bool {
      let payload = exportAsJSONL()
      guard !payload.isEmpty else { return false }
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try payload.write(to: url, atomically: true, encoding: .utf8)
        return true
      } catch {
        vCLMLog("TypingJournal: export failed: \(error)")
        return false
      }
    }

    // MARK: Internal

    var records: [TypingJournalRecord] = []
    var isDirty = false

    func lockedSnapshot() -> [TypingJournalRecord] { lock.withLock { records } }

    func lockedIngest(_ incoming: [TypingJournalRecord]) {
      lock.withLock {
        records = incoming
        if records.count > Self.capacity {
          records.removeFirst(records.count - Self.capacity)
        }
      }
    }

    func lockedIsDirty() -> Bool { lock.withLock { isDirty } }

    func lockedSetDirty(_ newValue: Bool) { lock.withLock { isDirty = newValue } }

    // MARK: Private

    private let lock = NSLock()

    /// 取鎖狀態下的錄製判定。
    private func isRecordingLocked(now: Double) -> Bool {
      guard let activatedAt else { return false }
      guard !allowedAppCategories.isEmpty else { return false }
      return now - activatedAt < Self.sessionLimitHours * 3_600
    }
  }
}
