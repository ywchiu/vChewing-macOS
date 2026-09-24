// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - LXFacade + SmartContext

/// SmartContext 在 `LXFacade` 上的門面。
///
/// 形狀刻意比照 `LXFacade_POMRepresentable`：宿主（LibVanguard／MainAssembly）只跟
/// `LXFacade` 說話，不直接碰 `SmartPreferenceStore`，這樣日後換掉儲存體的實作時，
/// 呼叫端一行都不用改。
extension LXAssembly.LXFacade {
  /// 造一個「這筆 POM 記憶該不該在當前 app 裡生效」的判定閉包。
  ///
  /// 回傳 `nil` 代表**不做 app 區隔**——沒設定當前 app 類別、或沒掛個人偏好表時皆然，
  /// 此時 POM 的注入行為與引入本機制之前逐位元一致。
  ///
  /// 之所以要在 POM 的注入端攔、而不是用加權去壓：POM 餵的是 contextual gram
  /// （權重 −0.115～0），對上 unigram 基線的 −5 上下有五個數量級的優勢，
  /// SmartContext 的 ±1.5 加權**結構上壓不回去**。判準收得很窄，
  /// 見 `SmartPreferenceStore.wasLearnedOnlyElsewhere` 的說明。
  public func makePOMAppPartition(timestamp: Double) -> ((String, String?) -> Bool)? {
    guard let appCategory = currentAppCategory, let store = smartPreferenceStore else {
      return nil
    }
    return { candidate, previous in
      store.wasLearnedOnlyElsewhere(
        candidate: candidate,
        previous: previous ?? "",
        currentAppCategory: appCategory,
        timestamp: timestamp
      )
    }
  }

  /// 記錄一次顯式選字（必要時連同它所構成的修正）。
  ///
  /// - Parameter displaced: 這次選字換掉的是哪個詞；沒換掉任何東西時傳 nil。
  ///   非 nil 即構成一次修正，正負訊號一併寫入。
  public func noteSmartPreference(
    reading: String,
    candidate: String,
    previous: String,
    anterior: String,
    appCategory: LXAssembly.SmartAppCategory,
    displaced: String?,
    timestamp: Double,
    saveCallback: (() -> ())? = nil
  ) {
    guard let store = smartPreferenceStore else { return }
    // 個人偏好表參與 POM 的注入判定（app 區隔），故學到新東西之後，
    // 以 POM 為指紋來源的那份元圖快取必須跟著失效——否則下一次查詢會拿回舊結果。
    Self.pomGeneration &+= 1
    store.note(
      reading: reading,
      candidate: candidate,
      previous: previous,
      anterior: anterior,
      appCategory: appCategory,
      displaced: displaced,
      timestamp: timestamp
    )
    saveCallback?()
  }

  /// 清除全部個人用字偏好。
  public func clearSmartPreferenceData() {
    smartPreferenceStore?.clearAll()
  }

  /// 只清除某個 app 粗類別底下的偏好。
  public func resetSmartPreferenceData(for appCategory: LXAssembly.SmartAppCategory) {
    smartPreferenceStore?.resetAppSpecificLearning(appCategory)
  }

  /// 忘掉指定候選詞的所有偏好紀錄。
  ///
  /// 與 POM 的 `bleachSpecifiedPOMSuggestions(targets:)` 對位：使用者在選字窗裡
  /// 把某個詞加進濾除清單時，兩邊都該一起忘掉，否則被濾掉的詞還留著學習紀錄。
  public func forgetSmartPreferences(candidates: [String]) {
    smartPreferenceStore?.forget(candidates: Set(candidates.filter { !$0.isEmpty }))
  }

  /// 自磁碟載入個人用字偏好。
  public func loadSmartPreferenceData(fromURL fileURL: URL? = nil) {
    smartPreferenceStore?.loadFromDisk(url: fileURL)
  }

  /// 將個人用字偏好寫回磁碟（無異動時為早退）。
  public func saveSmartPreferenceData(toURL fileURL: URL? = nil) {
    smartPreferenceStore?.saveToDisk(url: fileURL)
  }

  /// 目前學到的內容快照，供設定介面與診斷使用。
  public func smartPreferenceSnapshot(
    timestamp: Double = Date().timeIntervalSince1970
  )
    -> [(entry: LXAssembly.SmartPreferenceEntry, confidence: Double)] {
    smartPreferenceStore?.snapshot(timestamp: timestamp) ?? []
  }
}
