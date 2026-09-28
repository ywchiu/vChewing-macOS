// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LexiconAssembly
import Shared

// MARK: - InputHandlerProtocol + Typing journal (Phase 7)

extension InputHandlerProtocol {
  /// 允許錄製的 app 粗類別，來自偏好設定。
  ///
  /// 偏好裡存的是 rawValue 字串；認不得的字串一律丟掉，不做任何猜測——
  /// 一個拼錯的類別名應該表現為「那一類不錄」，而不是「錄了但歸錯類」。
  public var typingJournalAllowedCategories: Set<LXAssembly.SmartAppCategory> {
    Set(prefs.typingJournalAllowedAppCategories.compactMap {
      LXAssembly.SmartAppCategory(rawValue: $0)
    })
  }

  /// 打字日誌是否生效。
  ///
  /// ## 三道關，缺一不可
  ///
  /// 1. `typingJournalEnabled` 為真（使用者自己打開的開關）。
  /// 2. 允許清單非空（使用者自己勾的類別）。
  /// 3. 當下不在安全輸入狀態。
  ///
  /// 注意它**不**掛在 `smartContextEnabled` 底下。這是刻意的：其餘功能改的是排序，
  /// 這一個留的是使用者打過的原文，兩者的風險不同級，不該由同一個開關代表。
  /// 使用者打開 SmartContext 時不該順便開始被錄音。
  public var isTypingJournalEffective: Bool {
    guard prefs.typingJournalEnabled else { return false }
    guard !typingJournalAllowedCategories.isEmpty else { return false }
    guard !SessionHost.shared.isSecureInputActive() else { return false }
    return true
  }

  /// 打字日誌所用的 app 粗類別。
  ///
  /// 與 `currentAppCategory` 分開算：後者在 app-aware 學習關閉時恆為 `.other`，
  /// 那對排序是對的（不做區分），對日誌卻是錯的——使用者勾的是「只錄編輯器」，
  /// 若這裡回 `.other`，他要嘛什麼都錄不到、要嘛把聊天室的內容也錄進來。
  /// 允許清單是一道隔離牆，牆的判準必須是真實的類別。
  public var typingJournalAppCategory: LXAssembly.SmartAppCategory {
    if let override = smartContextConfig.appCategoryOverride { return override }
    return .categorize(bundleID: session?.clientBundleIdentifier)
  }

  /// 取得（必要時就地建立、自磁碟載入並依偏好啟用）打字日誌。
  ///
  /// 關閉時回傳 nil 且**完全不碰磁碟**——「沒有啟用就不會學習」這句話，在實作上
  /// 就是這一行早退。
  @discardableResult
  public func ensureTypingJournal() -> LXAssembly.TypingJournal? {
    guard isTypingJournalEffective else { return nil }
    let allowed = typingJournalAllowedCategories
    if let existing = currentLM.typingJournal {
      // 偏好可能在 session 中途被改動，故每次都把允許清單重新交待一次。
      // `activate` 同時會在清單由空轉非空時重新計時。
      if !existing.isRecording(now: Date().timeIntervalSince1970) {
        existing.activate(allowedAppCategories: allowed, now: Date().timeIntervalSince1970)
      }
      return existing
    }
    let journal = LXAssembly.TypingJournal(
      dataURL: SessionHost.shared.typingJournalDataURL(currentInputModeForSmartContext)
    )
    journal.loadFromDisk()
    journal.activate(allowedAppCategories: allowed, now: Date().timeIntervalSince1970)
    currentLM.typingJournal = journal
    return journal
  }

  /// 把這一次遞交記進打字日誌。
  ///
  /// 呼叫點與 `observeSmartPhrases()` 相同（`committableDisplayText`），理由也相同：
  /// 那是所有遞交路徑的匯流處，而中斷不會走到那裡。差別在於本函式記的是**原文**，
  /// 所以它比詞組觀察多了一整組前置條件，見 `isTypingJournalEffective`。
  public func recordTypingJournalEntry() {
    guard isTypingJournalEffective else { return }
    guard let journal = ensureTypingJournal() else { return }
    let assembled = assembler.assembledSentence
    guard !assembled.isEmpty else { return }

    var readings: [String] = []
    var committed = ""
    for gram in assembled {
      // 標點與符號不記：它們對「使用者到底想打哪個詞」這個問題沒有資訊量，
      // 卻會讓匯出的日誌變得難讀。
      if gram.keyArray.contains(where: { $0.hasPrefix("_") }) { continue }
      readings.append(contentsOf: gram.keyArray)
      committed += gram.value
    }
    guard !readings.isEmpty, !committed.isEmpty else { return }

    let now = Date().timeIntervalSince1970
    let appCategory = typingJournalAppCategory
    journal.record(
      readings: readings,
      committed: committed,
      precedingContext: journal.recentCommitted(
        limit: 2,
        within: Self.typingJournalContextWindow,
        now: now,
        appCategory: appCategory
      ),
      appCategory: appCategory,
      timestamp: now
    )
  }

  /// 前文取樣的時間窗（秒）。
  ///
  /// 超過這段時間的上一句不算前文——使用者離開去做別的事再回來打字，那是新的一句話，
  /// 把十分鐘前的句子當成它的前文只會給判讀的一方錯誤的線索。
  public static var typingJournalContextWindow: Double { 120 }
}
