// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - LXAssembly.SmartPreferenceStore + Persistence

extension LXAssembly.SmartPreferenceStore {
  /// 存檔的外層封裝。
  ///
  /// 刻意帶 `schemaVersion`：這份檔案會在使用者的機器上活很久，而它的內容日後多半
  /// 還會再長（Phase 5 的詞組升格、Phase 7 的匯入來源標記都要寫進來）。
  struct Archive: Codable, Sendable {
    /// 目前的 schema 版本。
    static let currentVersion = 1

    var schemaVersion: Int = Archive.currentVersion
    var savedAt: Double = 0
    var entries: [LXAssembly.SmartPreferenceEntry] = []
  }

  /// 從磁碟載入。
  ///
  /// ## 版本不符時**整份丟棄重建**，不嘗試升級
  ///
  /// 這是刻意的保守：本表的資料是「錦上添花」——丟掉它，輸入法只是回到沒學過東西的
  /// 狀態，使用者頂多覺得「最近怎麼變笨了」，過幾天就學回來；而一個寫壞的升級器會把
  /// 錯誤的偏好**永久**寫進去，那是使用者自己再也修不好的。前者可回復，後者不可回復，
  /// 所以選前者。真要做升級，等有足夠多的使用者資料值得搶救時再說，且應該是
  /// 「讀舊版 → 產生新版 → 兩份並存直到確認無誤」的形狀，不是就地改寫。
  public func loadFromDisk(url overrideURL: URL? = nil) {
    guard let url = overrideURL ?? dataURL else { return }
    guard let data = try? Data(contentsOf: url) else { return }
    guard let archive = try? JSONDecoder().decode(Archive.self, from: data) else {
      vCLMLog("SmartPreferenceStore: archive is unreadable; starting empty.")
      return
    }
    guard archive.schemaVersion == Archive.currentVersion else {
      vCLMLog(
        "SmartPreferenceStore: archive schemaVersion \(archive.schemaVersion) "
          + "!= \(Archive.currentVersion); discarding it rather than guessing at a migration."
      )
      return
    }
    lockedIngest(archive.entries)
  }

  /// 寫回磁碟。
  ///
  /// 無異動時是個早退——本函式會被打字流程以 debounce 的方式反覆呼叫，
  /// 不能每次都真的去碰磁碟。
  public func saveToDisk(url overrideURL: URL? = nil, force: Bool = false) {
    guard force || lockedIsDirty() else { return }
    guard let url = overrideURL ?? dataURL else { return }
    let archive = Archive(
      schemaVersion: Archive.currentVersion,
      savedAt: Date().timeIntervalSince1970,
      entries: lockedEntriesSnapshot()
    )
    guard let data = try? JSONEncoder().encode(archive) else { return }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      // 原子寫入：打字中途被強制結束行程（或當機）不得留下一個半截的檔案。
      try data.write(to: url, options: [.atomic])
      lockedSetDirty(false)
    } catch {
      vCLMLog("SmartPreferenceStore: failed to write \(url.lastPathComponent): \(error)")
    }
  }
}
