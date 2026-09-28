// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
@testable import LexiconAssembly
import Testing

// MARK: - TypingJournalTests

/// 打字日誌（Phase 7）的測試。
///
/// 這裡測的重點不是「錄得全不全」，而是**什麼時候絕對不錄**。這份東西留的是使用者
/// 打過的原文，所以每一條「不錄」的規則都得有一個會失敗的測試守著它。
@Suite("TypingJournalTests", .serialized)
struct TypingJournalTests {
  // MARK: Internal

  /// 預設什麼都不錄。
  @Test("A fresh journal records nothing at all")
  func defaultsToRecordingNothing() {
    let journal = LXAssembly.TypingJournal()
    #expect(!journal.isRecording(now: Self.t0))
    journal.record(
      readings: ["ㄘˋ", "ㄕˋ"], committed: "測試",
      precedingContext: [], appCategory: .editor, timestamp: Self.t0
    )
    #expect(journal.count == 0, "沒有啟用就不會學習")
  }

  /// **允許清單為空時，就算「啟用」了也還是不錄。**
  ///
  /// 這條是給「使用者把開關打開、但一個類別都沒勾」那個狀態用的：它必須表現為
  /// 什麼都不錄，而不是表現為「都錄」。
  @Test("Activating with an empty allowlist still records nothing")
  func emptyAllowlistIsInert() {
    let journal = LXAssembly.TypingJournal()
    journal.activate(allowedAppCategories: [], now: Self.t0)
    #expect(!journal.isRecording(now: Self.t0))
    journal.record(
      readings: ["ㄘˋ"], committed: "測",
      precedingContext: [], appCategory: .editor, timestamp: Self.t0
    )
    #expect(journal.count == 0)
  }

  /// 只錄勾選過的類別。
  @Test("Only allowed app categories are recorded")
  func allowlistIsHonoured() {
    let journal = LXAssembly.TypingJournal()
    journal.activate(allowedAppCategories: [.editor], now: Self.t0)
    journal.record(
      readings: ["ㄅ"], committed: "編",
      precedingContext: [], appCategory: .editor, timestamp: Self.t0
    )
    journal.record(
      readings: ["ㄌ"], committed: "聊",
      precedingContext: [], appCategory: .chat, timestamp: Self.t0
    )
    #expect(journal.snapshot().map(\.committed) == ["編"])
  }

  /// 超過硬性時限即自動失效，不必使用者記得關。
  @Test("Recording expires on its own after the hard session limit")
  func expiresAfterTheHardLimit() {
    let journal = LXAssembly.TypingJournal()
    journal.activate(allowedAppCategories: [.editor], now: Self.t0)
    let justInside = Self.t0 + LXAssembly.TypingJournal.sessionLimitHours * 3_600 - 1
    let justOutside = Self.t0 + LXAssembly.TypingJournal.sessionLimitHours * 3_600 + 1
    #expect(journal.isRecording(now: justInside))
    #expect(!journal.isRecording(now: justOutside))
    journal.record(
      readings: ["ㄅ"], committed: "晚",
      precedingContext: [], appCategory: .editor, timestamp: justOutside
    )
    #expect(journal.count == 0, "逾時之後不該還在錄")
  }

  /// 停止錄製不會順手清掉已錄的內容。
  @Test("Deactivating keeps what was already recorded")
  func deactivationKeepsRecords() {
    let journal = LXAssembly.TypingJournal()
    journal.activate(allowedAppCategories: [.editor], now: Self.t0)
    journal.record(
      readings: ["ㄅ"], committed: "編",
      precedingContext: [], appCategory: .editor, timestamp: Self.t0
    )
    journal.deactivate()
    #expect(!journal.isRecording(now: Self.t0))
    #expect(journal.count == 1, "「停止」與「清除」是兩件事")
  }

  /// 清除就是真的清空。
  @Test("clearAll wipes everything")
  func clearAllWipes() {
    let journal = LXAssembly.TypingJournal()
    journal.activate(allowedAppCategories: [.editor], now: Self.t0)
    journal.record(
      readings: ["ㄅ"], committed: "編",
      precedingContext: [], appCategory: .editor, timestamp: Self.t0
    )
    journal.clearAll()
    #expect(journal.count == 0)
  }

  /// 有界：滿了淘汰最舊者。
  @Test("The journal is bounded and drops the oldest entries")
  func capacityIsBounded() {
    let journal = LXAssembly.TypingJournal()
    journal.activate(allowedAppCategories: [.editor], now: Self.t0)
    let overflow = LXAssembly.TypingJournal.capacity + 5
    for index in 0 ..< overflow {
      journal.record(
        readings: ["ㄅ"], committed: "字\(index)",
        precedingContext: [], appCategory: .editor, timestamp: Self.t0 + Double(index)
      )
    }
    #expect(journal.count == LXAssembly.TypingJournal.capacity)
    #expect(journal.snapshot().first?.committed == "字5", "被丟掉的必須是最舊的那幾筆")
  }

  /// 前文只取時間窗內、同類 app 的上一句。
  @Test("Preceding context stops at the time window and at an app switch")
  func recentCommittedRespectsWindowAndApp() {
    let journal = LXAssembly.TypingJournal()
    journal.activate(allowedAppCategories: [.editor, .chat], now: Self.t0)
    journal.record(
      readings: ["ㄅ"], committed: "很久以前",
      precedingContext: [], appCategory: .editor, timestamp: Self.t0
    )
    journal.record(
      readings: ["ㄅ"], committed: "剛剛",
      precedingContext: [], appCategory: .editor, timestamp: Self.t0 + 1_000
    )
    let now = Self.t0 + 1_010
    #expect(
      journal.recentCommitted(limit: 2, within: 120, now: now, appCategory: .editor) == ["剛剛"],
      "十幾分鐘前的那一句不算前文"
    )
    #expect(
      journal.recentCommitted(limit: 2, within: 120, now: now, appCategory: .chat).isEmpty,
      "別類 app 的內容不得成為前文"
    )
  }

  /// 匯出是 JSONL，每行一筆、可解析。
  @Test("Export produces one parsable JSON object per line")
  func exportIsJSONL() throws {
    let journal = LXAssembly.TypingJournal()
    journal.activate(allowedAppCategories: [.editor], now: Self.t0)
    journal.record(
      readings: ["ㄘˋ", "ㄕˋ"], committed: "測試",
      precedingContext: ["前文"], appCategory: .editor, timestamp: Self.t0
    )
    journal.record(
      readings: ["ㄗ"], committed: "字",
      precedingContext: [], appCategory: .editor, timestamp: Self.t0 + 1
    )
    let lines = journal.exportAsJSONL().split(separator: "\n").map(String.init)
    #expect(lines.count == 2)
    let decoder = JSONDecoder()
    for line in lines {
      let data = try #require(line.data(using: .utf8))
      _ = try decoder.decode(LXAssembly.TypingJournalRecord.self, from: data)
    }
    #expect(!journal.exportAsJSONL().contains("bundle"), "匯出內容不得帶 bundle identifier")
  }

  /// 存檔與載入來回一致，而且**載入不會讓錄製自行恢復**。
  @Test("A round trip through disk preserves records but not the recording state")
  func persistenceRoundTripDoesNotResumeRecording() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("vChewingTest-journal-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let source = LXAssembly.TypingJournal(dataURL: url)
    source.activate(allowedAppCategories: [.editor], now: Self.t0)
    source.record(
      readings: ["ㄘˋ", "ㄕˋ"], committed: "測試",
      precedingContext: [], appCategory: .editor, timestamp: Self.t0
    )
    source.saveToDisk()

    let restored = LXAssembly.TypingJournal(dataURL: url)
    restored.loadFromDisk()
    #expect(restored.snapshot().map(\.committed) == ["測試"])
    #expect(
      !restored.isRecording(now: Self.t0),
      "重新載入不得讓錄製在使用者不知情的狀況下繼續"
    )
  }

  /// 版本不符的存檔一律丟棄。
  @Test("An archive with an unknown schemaVersion is discarded")
  func unknownArchiveVersionIsDiscarded() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("vChewingTest-journal-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let payload = #"{"schemaVersion":999,"savedAt":0,"records":[]}"#
    try payload.write(to: url, atomically: true, encoding: .utf8)
    let journal = LXAssembly.TypingJournal(dataURL: url)
    journal.loadFromDisk()
    #expect(journal.count == 0)
  }

  // MARK: Private

  private static let t0: Double = 1_800_000_000
}
