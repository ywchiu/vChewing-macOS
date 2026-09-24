// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - LXAssembly.SmartPhraseStore + Persistence

extension LXAssembly.SmartPhraseStore {
  /// 存檔的外層封裝。版本策略與 `SmartPreferenceStore.Archive` 相同。
  struct Archive: Codable, Sendable {
    static let currentVersion = 1

    var schemaVersion: Int = Archive.currentVersion
    var savedAt: Double = 0
    var candidates: [LXAssembly.SmartPhraseCandidate] = []
  }

  /// 自磁碟載入。版本不符即整份丟棄，理由見 `SmartPreferenceStore.loadFromDisk`。
  public func loadFromDisk(url overrideURL: URL? = nil) {
    guard let url = overrideURL ?? dataURL else { return }
    guard let data = try? Data(contentsOf: url) else { return }
    guard let archive = try? JSONDecoder().decode(Archive.self, from: data) else {
      vCLMLog("SmartPhraseStore: archive is unreadable; starting empty.")
      return
    }
    guard archive.schemaVersion == Archive.currentVersion else {
      vCLMLog(
        "SmartPhraseStore: archive schemaVersion \(archive.schemaVersion) "
          + "!= \(Archive.currentVersion); discarding it rather than guessing at a migration."
      )
      return
    }
    lockedIngest(archive.candidates)
  }

  /// 寫回磁碟（無異動時為早退）。
  public func saveToDisk(url overrideURL: URL? = nil, force: Bool = false) {
    guard force || lockedIsDirty() else { return }
    guard let url = overrideURL ?? dataURL else { return }
    let archive = Archive(
      schemaVersion: Archive.currentVersion,
      savedAt: Date().timeIntervalSince1970,
      candidates: lockedSnapshotForArchive()
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
      vCLMLog("SmartPhraseStore: failed to write \(url.lastPathComponent): \(error)")
    }
  }
}
