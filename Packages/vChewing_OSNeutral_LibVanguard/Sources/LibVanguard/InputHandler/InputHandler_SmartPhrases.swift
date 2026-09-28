// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LexiconAssembly
import Shared

// MARK: - InputHandlerProtocol + Smart phrase observation

extension InputHandlerProtocol {
  /// 詞組學習是否生效。
  ///
  /// 掛在 `personal_learning_v2_enabled` 底下，而不是另開一個開關：它與個人用字偏好
  /// 是同一件事的兩種粒度（一個記「這個讀音你偏好哪個詞」，一個記「這串讀音你偏好
  /// 哪個詞組」），拆成兩個開關只會讓使用者猜不出差別。
  public var isSmartPhraseLearningEffective: Bool {
    isPersonalLearningV2Effective
  }

  /// 取得（必要時就地建立、載入並掛載）詞組學習儲存體。
  ///
  /// 掛載走的是本倉既有的多來源機制（`LXFacade.mountGramSupplier`），因此升格後的詞組
  /// 會自然出現在候選窗與組句裡，不必在查詢管線上另外開洞。
  @discardableResult
  public func ensureSmartPhraseStore() -> LXAssembly.SmartPhraseStore? {
    guard isSmartPhraseLearningEffective else { return nil }
    if let existing = currentLM.smartPhraseStore { return existing }
    let store = LXAssembly.SmartPhraseStore(
      dataURL: SessionHost.shared.smartPhraseDataURL(currentInputModeForSmartContext)
    )
    store.loadFromDisk()
    currentLM.smartPhraseStore = store
    currentLM.mountGramSupplier(LXAssembly.SmartPhraseSupplier(store: store))
    return store
  }

  /// 觀察「使用者逐字手動組出來的詞組」。
  ///
  /// ## 觀察的是什麼
  ///
  /// 組句結果裡每個 `GramInPath` 都帶 `isExplicit`——它為真，代表這一格是使用者**親手
  /// 從候選窗選的**，不是引擎猜的。於是「一串連續的 explicit 單字」就正好是
  /// 「使用者逐字手動拼出來的一個詞」，也就是需求書說的 manual confirmation。
  ///
  /// 只收單字格（`segLength == 1`）組成的連續段：若其中某一格本來就是辭典裡的詞，
  /// 那這串東西就不是「使用者自己拼出來的新詞」，而是既有詞的組合，沒有學的必要。
  ///
  /// ## 為什麼在遞交時觀察，而不是每次選字時
  ///
  /// 每選一次字就記一次的話，「王大明」會連帶把「王大」也記進去——使用者從來沒想過
  /// 要「王大」這個詞，它只是中途狀態。等到遞交才看，拿到的才是他真正要的那一串。
  public func observeSmartPhrases() {
    guard isSmartPhraseLearningEffective else { return }
    guard let store = ensureSmartPhraseStore() else { return }
    let runs = explicitSingleCharacterRuns(in: assembler.assembledSentence)
    guard !runs.isEmpty else { return }
    let timestamp = Date().timeIntervalSince1970
    for run in runs {
      // 歧義度由辭典現況決定：該讀音底下本來就有一堆同長度的詞，就別學了——
      // 使用者手動組出某個組合多半只是這一次要這麼打。
      let ambiguity = currentLM.lxQuerier.countKeyValuePairs(
        keyArray: run.keyArray,
        factoryDictionaryOnly: true
      )
      store.observe(
        keyArray: run.keyArray,
        value: run.value,
        ambiguity: ambiguity,
        timestamp: timestamp
      )
    }
    currentLM.saveSmartPhraseData()
  }

  /// 找出組句結果裡所有「連續的、使用者親手選定的單字」段落。
  ///
  /// - Returns: 每段的讀音索引鍵陣列與其拼成的字串。
  func explicitSingleCharacterRuns(
    in assembled: [Homa.GramInPath]
  )
    -> [(keyArray: [String], value: String)] {
    var results: [(keyArray: [String], value: String)] = []
    var runKeys: [String] = []
    var runValue = ""

    func flush() {
      defer {
        runKeys.removeAll(keepingCapacity: true)
        runValue.removeAll(keepingCapacity: true)
      }
      guard LXAssembly.SmartPhraseStore.lengthRange.contains(runKeys.count) else { return }
      results.append((runKeys, runValue))
    }

    for gram in assembled {
      let isLoneExplicitKanji = gram.isExplicit
        && gram.keyArray.count == 1
        && gram.value.count == 1
        && !gram.keyArray.contains { $0.hasPrefix("_") } // 標點／符號不參與
      guard isLoneExplicitKanji, let key = gram.keyArray.first else {
        flush()
        continue
      }
      runKeys.append(key)
      runValue += gram.value
    }
    flush()
    return results
  }
}
