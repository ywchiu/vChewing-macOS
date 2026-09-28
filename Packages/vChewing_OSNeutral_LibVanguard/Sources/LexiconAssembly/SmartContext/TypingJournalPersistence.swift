// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - LXAssembly.TypingJournal + Persistence

extension LXAssembly.TypingJournal {
  /// 存檔的外層封裝。
  struct Archive: Codable, Sendable {
    static let currentVersion = 1

    var schemaVersion: Int = Archive.currentVersion
    var savedAt: Double = 0
    var records: [LXAssembly.TypingJournalRecord] = []
  }

  /// 從磁碟載入。
  ///
  /// 版本不符即整份丟棄——與 `SmartPreferenceStore` 同一套理由，而且這裡更沒有搶救的
  /// 必要：一份讀不懂的打字日誌本來就該消失，而不是被猜著讀進來。
  ///
  /// 載入**不會**讓錄製重新開始：`activatedAt` 不在存檔裡。重開機之後得再按一次
  /// 「開始錄製」，這是刻意的——一個能在使用者沒察覺時自己恢復錄製的機制，
  /// 不該存在。
  public func loadFromDisk(url overrideURL: URL? = nil) {
    guard let url = overrideURL ?? dataURL else { return }
    guard let data = try? Data(contentsOf: url) else { return }
    guard let archive = try? JSONDecoder().decode(Archive.self, from: data) else {
      vCLMLog("TypingJournal: archive is unreadable; starting empty.")
      return
    }
    guard archive.schemaVersion == Archive.currentVersion else {
      vCLMLog(
        "TypingJournal: archive schemaVersion \(archive.schemaVersion) "
          + "!= \(Archive.currentVersion); discarding it."
      )
      return
    }
    lockedIngest(archive.records)
  }

  /// 寫回磁碟（無異動時為早退）。
  public func saveToDisk(url overrideURL: URL? = nil, force: Bool = false) {
    guard force || lockedIsDirty() else { return }
    guard let url = overrideURL ?? dataURL else { return }
    let archive = Archive(
      schemaVersion: Archive.currentVersion,
      savedAt: Date().timeIntervalSince1970,
      records: lockedSnapshot()
    )
    guard let data = try? JSONEncoder().encode(archive) else { return }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: url, options: [.atomic])
      lockedSetDirty(false)
    } catch {
      vCLMLog("TypingJournal: failed to write \(url.lastPathComponent): \(error)")
    }
  }
}
