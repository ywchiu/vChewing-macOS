// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LexiconAssembly
@testable import LibVanguard
import Shared
import Tekkon

// MARK: - BenchCaseOutcome

/// 單一案例的量測結果。
public struct BenchCaseOutcome: Sendable {
  // MARK: Lifecycle

  public init(
    id: String,
    tags: [String],
    expected: String,
    isTop1: Bool,
    isTop3: Bool,
    isSentenceCorrect: Bool,
    correctionCount: Int,
    rankOfExpected: Int?,
    producedSentence: String,
    topCandidates: [String],
    competitorRanks: [(value: String, rank: Int?)],
    skippedReason: String? = nil
  ) {
    self.id = id
    self.tags = tags
    self.expected = expected
    self.isTop1 = isTop1
    self.isTop3 = isTop3
    self.isSentenceCorrect = isSentenceCorrect
    self.correctionCount = correctionCount
    self.rankOfExpected = rankOfExpected
    self.producedSentence = producedSentence
    self.topCandidates = topCandidates
    self.competitorRanks = competitorRanks
    self.skippedReason = skippedReason
  }

  // MARK: Public

  public let id: String
  public let tags: [String]
  public let expected: String
  public let isTop1: Bool
  public let isTop3: Bool
  /// 組句結果（非候選窗）是否已經直接給出期望詞。這是「使用者根本不必開選字窗」的指標。
  public let isSentenceCorrect: Bool
  /// 模擬的手動修正次數：期望詞在候選清單中的 0-based 名次。
  /// 期望詞根本不在清單裡時記為 `BenchScoring.missingCandidatePenalty`。
  public let correctionCount: Int
  /// 期望詞的 0-based 名次；不在清單內時為 nil。
  public let rankOfExpected: Int?
  public let producedSentence: String
  public let topCandidates: [String]
  public let competitorRanks: [(value: String, rank: Int?)]
  /// 非 nil 表示本案例在當前辭典下不可測（例如小辭典缺該讀音），已自統計中剔除。
  public let skippedReason: String?

  public var isSkipped: Bool { skippedReason != nil }
}

// MARK: - BenchScoring

public enum BenchScoring {
  /// 期望詞完全不在候選清單內時所記的修正成本。
  ///
  /// 取一個「明顯比任何合理名次都大、但又不會讓平均值爆掉」的常數：使用者真遇到這種情況
  /// 得改用其它輸入手段（拆字、造詞），成本遠大於翻幾頁，但把它記成無限大會讓 correction
  /// count 這個指標失去比較意義。
  public static let missingCandidatePenalty = 20
}

// MARK: - BenchDriver

/// 以**生產端的 `InputHandler`** 驅動 benchmark。
///
/// 刻意不經 `triageInput(event:)`／`InputSession`：
/// - `triageInput` 需要一個 session（`guard let session = session else { return false }`），
///   而 session 與 IMK 狀態機所花的時間**不是** smart scoring 會動到的部分，
///   把它算進 p50／p95 只會稀釋我們真正想守住的訊號。
/// - 本 driver 直接走「注拼槽 → `assembler.insertKey` →（自動）`assemble` →
///   `generateArrayOfCandidates`」這條 scoring 熱路徑，也就是 SmartContextScorer
///   未來唯一會加重的路徑。
///
/// `InputHandler.session` 保持 nil 是安全的：`InputHandler_CoreProtocol` 內所有 session
/// 取用處（`announce`、`previewCurrentCandidateAtCompositionBuffer`、
/// `commitOverflownComposition`）皆以 `guard let session` 把守。
@MainActor
public final class BenchDriver {
  // MARK: Lifecycle

  /// - Parameters:
  ///   - prefs: 偏好設定來源。
  ///   - pomDataURL: POM 的存檔位置。給它一個真實（暫存）路徑而非 nil，是為了讓
  ///     `clearPOMData()` 與 `saveData()` 走完整路徑——POM 在 URL 為 nil 時會把每一次
  ///     清除與存檔都記成錯誤，既淹沒測試輸出，也讓「修正學習」量到的不是生產端行為。
  public init(prefs: PrefMgrProtocol, pomDataURL: URL?) {
    self.prefs = prefs
    self.lx = LXAssembly.LXFacade(isCHS: false, pomDataURL: pomDataURL)
    self.handler = InputHandler(lx: lx, pref: prefs)
  }

  // MARK: Public

  public private(set) var typingLatency = BenchLatencySamples(label: "per-keystroke (composer + insertKey + assemble)")
  public private(set) var assembleLatency = BenchLatencySamples(label: "assemble() only")
  public private(set) var candidateLatency = BenchLatencySamples(label: "generateArrayOfCandidates()")

  /// 跑完一筆案例。
  public func run(_ benchCase: BenchCase) -> BenchCaseOutcome {
    switch benchCase.kind {
    case .ranking: runRanking(benchCase)
    case .correctionLearning: runCorrectionLearning(benchCase)
    case .appSwitching: runAppSwitching(benchCase)
    }
  }

  /// 指定當前所處的 app 粗類別。
  public func setAppCategory(_ category: LXAssembly.SmartAppCategory?) {
    handler.smartContextConfig.appCategoryOverride = category
  }

  /// 清空組字器、注拼槽、POM 記憶與 SmartContext 的 session-local 狀態，
  /// 讓下一筆案例自乾淨狀態開始。
  public func resetAll() {
    handler.clear()
    handler.clearSmartContextState()
    lx.clearPOMData()
  }

  /// 僅供診斷測試取用內部 handler。
  public var handlerForDiag: InputHandler { handler }

  // MARK: Internal

  let prefs: PrefMgrProtocol
  let lx: LXAssembly.LXFacade
  let handler: InputHandler

  // MARK: Private

  /// 把一個注音音節（如 `"ㄏㄢˊ"`）逐符號餵進注拼槽，湊滿之後插進組字器。
  ///
  /// 逐符號是刻意的：一個注音符號 ≈ 一次實體按鍵，故這裡的每一次取樣就是
  /// 使用者體感上的「一次敲鍵」。
  /// - Returns: 該音節是否成功進入組字器。
  @discardableResult
  private func typeSyllable(_ syllable: String, measured: Bool) -> Bool {
    var inserted = false

    /// 一次「按鍵」：把一個注音符號（或代表第一聲的空格）餵進注拼槽，
    /// 湊滿聲調之後就把讀音插進組字器。
    ///
    /// - Important: 一律走 `receiveKey(fromPhonabet:)` 而非 `receiveKey(fromString:)`。
    ///   後者會先過 `translate(key:)`（鍵盤佈局映射），而資料集裡寫的是**注音符號本身**、
    ///   不是大千佈局上的按鍵字母，走 fromString 會整串被丟掉。
    func strike(_ key: Unicode.Scalar) {
      let body: () -> () = { [self] in
        // 與生產端 `triageInput(event:)` 的順序一致：每一拍按鍵先重編 SmartContext 的
        // 加權表，再讓注拼槽收鍵。**這一步的成本刻意算進 per-keystroke 延遲**——
        // 它本來就是使用者要付的錢。
        handler.refreshSmartContextAdjuster()
        _ = handler.composer.receiveKey(fromPhonabet: key)
        guard handler.composer.hasIntonation() else { return }
        guard let readingKey = handler.composer.phonabetKeyForQuery(pronounceableOnly: true) else { return }
        handler.composer.clear()
        // insertKey 內含 assignNodes → assemble，故這一格就是整條組句熱路徑。
        let assembleStart = DispatchTime.now().uptimeNanoseconds
        let didInsert = (try? handler.assembler.insertKey(readingKey)) != nil
        let assembleEnd = DispatchTime.now().uptimeNanoseconds
        if measured, didInsert {
          assembleLatency.record(Double(assembleEnd &- assembleStart) / 1_000_000.0)
        }
        inserted = didInsert
      }
      if measured {
        typingLatency.measure(body)
      } else {
        body()
      }
    }

    for scalar in syllable.unicodeScalars {
      strike(scalar)
    }
    // 第一聲在注音讀音字串上**不帶任何記號**（生＝`ㄕㄥ`），但使用者仍得實際按一下空格
    // 才算把音節敲完——`Tekkon.allowedIntonations` 的第一個元素就是 `" "`。少了這一下，
    // `hasIntonation()` 永遠是 false、音節根本不會進組字器（本 driver 的第一版因此把
    // 近三分之一的案例誤報成「辭典缺料」）。
    if !inserted, !handler.composer.isEmpty {
      strike(" ")
    }
    // 湊不滿聲調的殘留（資料集寫錯讀音時會發生）不得留在注拼槽裡污染下一筆。
    handler.composer.clear()
    return inserted
  }

  /// 敲入一整串音節。
  /// - Returns: 是否每一個音節都成功進入組字器。
  @discardableResult
  private func typeSyllables(_ syllables: [String], measured: Bool) -> Bool {
    var allInserted = true
    for syllable in syllables {
      if !typeSyllable(syllable, measured: measured) { allInserted = false }
    }
    return allInserted
  }

  /// 取當前游標處的候選清單。
  private func currentCandidates(measured: Bool) -> [CandidateInState] {
    let body: () -> [CandidateInState] = { [self] in
      handler.generateArrayOfCandidates(fixOrder: false)
    }
    return measured ? candidateLatency.measure(body) : body()
  }

  private func runRanking(_ benchCase: BenchCase) -> BenchCaseOutcome {
    resetAll()
    setAppCategory(benchCase.appCategory)
    typeSyllables(benchCase.precedingReadings, measured: true)
    let targetInserted = typeSyllables(benchCase.readings, measured: true)
    guard targetInserted else {
      return makeSkipped(benchCase, reason: "reading not present in the active lexicon")
    }
    let candidates = currentCandidates(measured: true)
    return makeOutcome(benchCase, candidates: candidates)
  }

  /// 修正學習：重複「敲字 → 顯式選中期望詞」若干輪，最後**另起一輪乾淨的敲字**才計分。
  ///
  /// 之所以最後那一輪要重新敲：我們要測的是「學到的東西能不能在下一次自動浮上來」，
  /// 而不是「剛剛選過的那一次還在不在」。
  private func runCorrectionLearning(_ benchCase: BenchCase) -> BenchCaseOutcome {
    resetAll()
    setAppCategory(benchCase.appCategory)
    let rounds = Swift.max(1, benchCase.repeatCount)
    for _ in 0 ..< rounds {
      handler.clear()
      typeSyllables(benchCase.precedingReadings, measured: false)
      guard typeSyllables(benchCase.readings, measured: false) else {
        return makeSkipped(benchCase, reason: "reading not present in the active lexicon")
      }
      let candidates = currentCandidates(measured: false)
      guard let target = candidates.first(where: { $0.value == benchCase.expected }) else {
        return makeSkipped(benchCase, reason: "expected value '\(benchCase.expected)' absent from candidates")
      }
      // 這一步就是使用者按下選字鍵：走生產端的 consolidateNode，POM 觀測與記憶寫入
      // 全部照生產端流程發生。
      handler.consolidateNode(candidate: target, explicitlyChosen: true)
    }
    handler.clear()
    typeSyllables(benchCase.precedingReadings, measured: true)
    guard typeSyllables(benchCase.readings, measured: true) else {
      return makeSkipped(benchCase, reason: "reading not present in the active lexicon")
    }
    return makeOutcome(benchCase, candidates: currentCandidates(measured: true))
  }

  /// App 切換：在 `trainAppCategory` 下反覆選 `trainExpected`，然後在 `appCategory` 下
  /// 檢查 `expected` 有沒有被前者污染。
  ///
  /// - Note: Phase 0 尚無 app 維度，故本 kind 目前量到的是**基線行為**——它會誠實地
  ///   顯示「現在 A app 學的東西確實會污染 B app」。Phase 4 之後同一份資料集才會轉綠。
  private func runAppSwitching(_ benchCase: BenchCase) -> BenchCaseOutcome {
    resetAll()
    guard let trainExpected = benchCase.trainExpected else {
      return makeSkipped(benchCase, reason: "appSwitching case lacks trainExpected")
    }
    setAppCategory(benchCase.trainAppCategory)
    let rounds = Swift.max(1, benchCase.repeatCount)
    for _ in 0 ..< rounds {
      handler.clear()
      typeSyllables(benchCase.precedingReadings, measured: false)
      guard typeSyllables(benchCase.readings, measured: false) else {
        return makeSkipped(benchCase, reason: "reading not present in the active lexicon")
      }
      let candidates = currentCandidates(measured: false)
      guard let target = candidates.first(where: { $0.value == trainExpected }) else {
        return makeSkipped(benchCase, reason: "trainExpected '\(trainExpected)' absent from candidates")
      }
      handler.consolidateNode(candidate: target, explicitlyChosen: true)
    }
    // 訓練完畢，切換到「另一個 app」再量。這一行就是整個 app-switching 案例的要點。
    setAppCategory(benchCase.appCategory)
    handler.clear()
    typeSyllables(benchCase.precedingReadings, measured: true)
    guard typeSyllables(benchCase.readings, measured: true) else {
      return makeSkipped(benchCase, reason: "reading not present in the active lexicon")
    }
    return makeOutcome(benchCase, candidates: currentCandidates(measured: true))
  }

  private func makeOutcome(
    _ benchCase: BenchCase,
    candidates: [CandidateInState]
  )
    -> BenchCaseOutcome {
    // 只拿「幅節長度與目標一致」的候選來排名：長度不同的候選（單字、更長的詞）
    // 與目標不在同一個競爭層級上，把它們算進名次會讓 correction count 失真。
    let comparable = candidates.filter { $0.keyArray.count == benchCase.syllableCount }
    let values = comparable.map(\.value)
    let rank = values.firstIndex(of: benchCase.expected)
    let sentence = handler.assembler.assembledSentence.values.joined()
    return BenchCaseOutcome(
      id: benchCase.id,
      tags: benchCase.tags,
      expected: benchCase.expected,
      isTop1: rank == 0,
      isTop3: (rank ?? Int.max) < 3,
      isSentenceCorrect: sentence.hasSuffix(benchCase.expected),
      correctionCount: rank ?? BenchScoring.missingCandidatePenalty,
      rankOfExpected: rank,
      producedSentence: sentence,
      topCandidates: Array(values.prefix(5)),
      competitorRanks: benchCase.competitors.map { ($0, values.firstIndex(of: $0)) }
    )
  }

  private func makeSkipped(_ benchCase: BenchCase, reason: String) -> BenchCaseOutcome {
    BenchCaseOutcome(
      id: benchCase.id,
      tags: benchCase.tags,
      expected: benchCase.expected,
      isTop1: false,
      isTop3: false,
      isSentenceCorrect: false,
      correctionCount: 0,
      rankOfExpected: nil,
      producedSentence: "",
      topCandidates: [],
      competitorRanks: [],
      skippedReason: reason
    )
  }
}
