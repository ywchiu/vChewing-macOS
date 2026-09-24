// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LexiconAssembly
import Shared

// MARK: - SmartContextRuntimeConfig

/// SmartContext 的執行期狀態，掛在每個 `InputHandler` 上。
///
/// 全部是**純記憶體、session-local** 的東西：session 結束即消失，永不落盤，
/// 也永不離開本機。真正需要跨 session 存活的學習資料是另一套（Phase 3 的
/// `SmartPreferenceStore`），與本結構無關。
public struct SmartContextRuntimeConfig {
  // MARK: Lifecycle

  public init() {}

  // MARK: Public

  /// session-local 環狀緩衝的容量。
  ///
  /// 取 16 的理由：這些東西每次語境變動都要被掃一遍以壓成 boost 表，故容量直接
  /// 換算成延遲。16 足以涵蓋「使用者剛剛在這段話裡反覆用到的詞」這個時間尺度，
  /// 而掃 16 筆的成本在 µs 以下。更長的記憶是 POM 與 Phase 3 新表的職責。
  public static let ringCapacity = 16

  /// 本次 session 內最近被顯式選中的詞，由近而遠。
  public private(set) var recentSelections: [String] = []
  /// 本次 session 內最近發生的「A 改成 B」，由近而遠。
  public private(set) var recentCorrections: [LXAssembly.SmartCorrection] = []
  /// Session-local 詞彙。
  public private(set) var sessionVocabulary: Set<String> = []

  /// App 粗類別的覆寫。
  ///
  /// 生產端**恆為 nil**：那裡的唯一來源是 `session.clientBundleIdentifier`。
  /// 這個欄位存在，是因為 SmartContext 的基準測試（`SmartContextBenchTests`）刻意
  /// 不經 `InputSession` 驅動——它要量的是 scoring 熱路徑，不是 IMK 狀態機——
  /// 而沒有 session 就沒有 bundle identifier。與其為了一個字串把整套 session
  /// 機具搬進基準測試，不如留一個具名、有界、而且顯然只有測試會去設的入口。
  public var appCategoryOverride: LXAssembly.SmartAppCategory? {
    didSet { invalidate() }
  }

  /// 目前已編譯、正掛在組字器上的加權表。
  public internal(set) var compiledTable: LXAssembly.SmartBoostTable = .empty
  /// `compiledTable` 是由哪一份語境編出來的。語境未變則不重編。
  public internal(set) var compiledFrom: LXAssembly.SmartInputContext?
  /// 上次編表時的組字器指紋。
  public internal(set) var compiledFingerprint: SmartContextFingerprint?
  /// session-local 環狀緩衝的修訂號；每次寫入遞增，供 O(1) 指紋比對使用。
  public private(set) var ringRevision: UInt64 = 0

  /// 記錄一次顯式選字。
  public mutating func noteSelection(_ value: String) {
    guard !value.isEmpty else { return }
    pushFront(value, into: &recentSelections)
    sessionVocabulary.insert(value)
    // 詞彙集合同樣要有界，否則長時間不關的 session 會無限長大。
    if sessionVocabulary.count > Self.ringCapacity * 4 {
      sessionVocabulary = Set(recentSelections)
    }
    invalidate()
  }

  /// 記錄一次「把 A 改成 B」。
  public mutating func noteCorrection(from rejected: String, to accepted: String) {
    guard !accepted.isEmpty, !rejected.isEmpty, rejected != accepted else { return }
    recentCorrections.insert(.init(from: rejected, to: accepted), at: 0)
    if recentCorrections.count > Self.ringCapacity {
      recentCorrections.removeLast(recentCorrections.count - Self.ringCapacity)
    }
    invalidate()
  }

  /// 清空所有 session-local 狀態。
  public mutating func clear() {
    recentSelections.removeAll(keepingCapacity: true)
    recentCorrections.removeAll(keepingCapacity: true)
    sessionVocabulary.removeAll(keepingCapacity: true)
    invalidate()
  }

  /// 令已編譯的加權表失效，下次組句前重編。
  public mutating func invalidate() {
    compiledTable = .empty
    compiledFrom = nil
    compiledFingerprint = nil
    ringRevision &+= 1
  }

  // MARK: Private

  private func pushFront(_ value: String, into ring: inout [String]) {
    if let existing = ring.firstIndex(of: value) { ring.remove(at: existing) }
    ring.insert(value, at: 0)
    if ring.count > Self.ringCapacity {
      ring.removeLast(ring.count - Self.ringCapacity)
    }
  }
}

// MARK: - SmartContextFingerprint

/// 組字器狀態的 O(1) 指紋，用來判斷「語境有沒有變」。
///
/// ## 為什麼需要它
///
/// 加權表的快取原本是以「編出來的 `SmartInputContext` 是否相等」判定的——但要比對
/// 就得先把語境**建出來**，而建語境要走訪組句結果。於是每一拍按鍵都付一次走訪成本，
/// 哪怕那一拍根本沒有改變任何東西（一個注音音節要敲 2–4 鍵，其中只有最後一鍵會真的
/// 動到組字器）。實測這讓 per-keystroke p95 無謂地多出約 4%。
///
/// 指紋讓常見的那一拍變成幾個整數比較：`mostRecentPathScore` 只要組句結果有任何變動
/// 就會改變，`cursor` / `length` 覆蓋游標移動與增刪，其餘兩項覆蓋 app 切換與
/// session-local 記錄的寫入。
public struct SmartContextFingerprint: Hashable, Sendable {
  public init(
    pathScore: Double,
    cursor: Int,
    length: Int,
    appCategory: LXAssembly.SmartAppCategory,
    ringRevision: UInt64
  ) {
    self.pathScore = pathScore
    self.cursor = cursor
    self.length = length
    self.appCategory = appCategory
    self.ringRevision = ringRevision
  }

  public let pathScore: Double
  public let cursor: Int
  public let length: Int
  public let appCategory: LXAssembly.SmartAppCategory
  public let ringRevision: UInt64
}

// MARK: - InputHandlerProtocol + SmartContext

extension InputHandlerProtocol {
  /// SmartContext 的總閘是否開啟。
  ///
  /// 它為 false 時，`personalLearningV2Enabled` / `appAwareLearningEnabled` /
  /// `tinyRerankerEnabled` 即使為 true 也一律不生效——三個子開關都得先過這一關。
  public var isSmartContextEffective: Bool {
    prefs.smartContextEnabled
  }

  /// App-aware 加權是否生效。
  public var isAppAwareLearningEffective: Bool {
    isSmartContextEffective && prefs.appAwareLearningEnabled
  }

  /// 前景 app 的粗類別；App-aware 關閉時恆為 `.other`。
  ///
  /// 這是本套件唯一碰 bundle identifier 的地方，而且只碰到「正規化成粗類別」為止：
  /// portable 這一側不持有、也不傳遞完整的 bundle ID。
  public var currentAppCategory: LXAssembly.SmartAppCategory {
    guard isAppAwareLearningEffective else { return .other }
    if let override = smartContextConfig.appCategoryOverride { return override }
    return .categorize(bundleID: session?.clientBundleIdentifier)
  }

  /// 取得（必要時就地建立）當前語言模型所用的 SmartContext 計分器。
  ///
  /// 「用哪一種 scorer」是 `LibVanguard` 的政策決定，不是 `LXFacade` 的——後者只提供
  /// 一個掛載槽位，本身不讀偏好、也不認得任何一種 scorer 的實作。
  public func ensureSmartContextScorer() -> (any LXAssembly.SmartContextScorer)? {
    if let existing = currentLM.smartContextScorer { return existing }
    guard isSmartContextEffective else { return nil }
    let scorer = LXAssembly.DeterministicSmartScorer()
    currentLM.smartContextScorer = scorer
    return scorer
  }

  /// 組裝當拍的語境快照。
  ///
  /// - Important: 本函式會走訪 `assembledSentence`，成本與組字區長度成正比，
  ///   故**每次組句之前至多呼叫一次**，絕不可放進 DP 迴圈。
  public func makeSmartInputContext() -> LXAssembly.SmartInputContext {
    guard isSmartContextEffective else { return .empty }
    let assembled = assembler.assembledSentence
    let cursor = actualNodeCursorPosition

    // 取游標之前的已定詞值，由近而遠。`cursorRegionMap` 會把「游標落在某個詞中間」
    // 對應到該詞的索引，故這裡以該索引為界往回取。
    var precedingValues: [String] = []
    let boundaryIndex = assembled.cursorRegionMap[min(cursor, assembled.totalKeyCount)]
      ?? assembled.count
    var walker = min(boundaryIndex, assembled.count) - 1
    while walker >= 0, precedingValues.count < LXAssembly.SmartInputContext.maxPrecedingValues {
      let value = assembled[walker].value
      if !value.isEmpty { precedingValues.append(value) }
      walker -= 1
    }

    return .init(
      precedingValues: precedingValues,
      currentReading: currentSmartContextReading(at: cursor, within: assembled),
      appCategory: currentAppCategory,
      recentSelections: smartContextConfig.recentSelections,
      recentCorrections: smartContextConfig.recentCorrections,
      sessionVocabulary: smartContextConfig.sessionVocabulary
    )
  }

  /// 依當拍語境重新編譯加權表，並把它掛上（或自組字器卸下）。
  ///
  /// 呼叫時機是「組字器結構或語境剛變動、但下一次 `assemble()` 尚未發生」。
  /// 語境與上次相同時直接返回，不重編也不重掛。
  public func refreshSmartContextAdjuster() {
    guard isSmartContextEffective, let scorer = ensureSmartContextScorer() else {
      // 關閉（或未掛 scorer）時必須把鉤子拆乾淨——留著一張舊表會讓「關閉開關」
      // 變成「凍結在關閉當下的行為」，那不是關閉。
      if assembler.contextScoreAdjuster != nil {
        assembler.contextScoreAdjuster = nil
      }
      smartContextConfig.invalidate()
      return
    }
    // O(1) 早退：組字器與 session-local 記錄都沒動過，就沒有任何東西需要重算。
    // 一個注音音節要敲 2–4 鍵、其中只有最後一鍵會動到組字器，故這條早退涵蓋了
    // 大多數的按鍵。
    let fingerprint = SmartContextFingerprint(
      pathScore: assembler.mostRecentPathScore,
      cursor: assembler.cursor,
      length: assembler.length,
      appCategory: currentAppCategory,
      ringRevision: smartContextConfig.ringRevision
    )
    if smartContextConfig.compiledFingerprint == fingerprint { return }

    let context = makeSmartInputContext()
    smartContextConfig.compiledFingerprint = fingerprint
    if smartContextConfig.compiledFrom == context { return }
    let table = context.isBarren ? .empty : scorer.compileBoostTable(context: context)
    smartContextConfig.compiledTable = table
    smartContextConfig.compiledFrom = context
    // 空表時把鉤子整個拆掉，讓 DP 連那一次 Optional 判斷都省下來。
    assembler.contextScoreAdjuster = table.isEmpty ? nil : table.asContextScoreAdjuster()
  }

  /// 清空 SmartContext 的所有 session-local 狀態並拆除鉤子。
  public func clearSmartContextState() {
    smartContextConfig.clear()
    assembler.contextScoreAdjuster = nil
  }

  // MARK: Private

  /// 取當前待決位置的讀音索引鍵陣列。
  private func currentSmartContextReading(
    at cursor: Int,
    within assembled: [Homa.GramInPath]
  )
    -> [String] {
    guard let hit = assembled.findGram(at: cursor) else { return [] }
    return hit.gram.keyArray
  }
}
