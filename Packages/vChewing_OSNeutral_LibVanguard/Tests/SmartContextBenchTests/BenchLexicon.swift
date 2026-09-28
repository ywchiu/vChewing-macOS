// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import LexiconAssembly
import LXAssemblyMaterials4Tests

// MARK: - BenchLexiconSource

/// benchmark 所使用的辭典來源。
///
/// 兩軌的理由（見 `spec/SmartContext_Plan.md` §0）：
/// - `.factory`：真實原廠辭典，accuracy 的**絕對值**只在這一軌有意義；但它是建置產物、
///   不在版控內，故 CI runner 上必然缺席。
/// - `.miniature`：測試靶內建的小辭典（995 entries）。CI 唯一跑得到的一軌，
///   守的是「排序邏輯有無退步」與「延遲有無退化」，不是準確率絕對值。
public enum BenchLexiconSource: Sendable {
  /// 真實原廠辭典（由 `VCHEWING_BENCH_TEXTMAP` 指向的 `*.txtMap`）。
  case factory(path: String)
  /// 測試靶內建的小辭典。
  case miniature

  // MARK: Public

  /// 依環境決定本次要用哪一軌。
  ///
  /// `VCHEWING_BENCH_TEXTMAP` 未設、或所指檔案不存在／schema 不合時，一律降級為
  /// `.miniature` 並在報表中標明——**不得**因此讓 benchmark 失敗，否則 CI 永遠是紅的。
  public static func resolveFromEnvironment() -> BenchLexiconSource {
    guard let path = ProcessInfo.processInfo.environment["VCHEWING_BENCH_TEXTMAP"],
          !path.isEmpty,
          FileManager.default.fileExists(atPath: path)
    else { return .miniature }
    let validation = LXAssembly.LXFacade.validateFactoryTextMapFile(at: path)
    guard validation.isValid else { return .miniature }
    return .factory(path: path)
  }

  /// 報表用的簡短描述。
  public var label: String {
    switch self {
    case let .factory(path): "factory (\(URL(fileURLWithPath: path).lastPathComponent))"
    case .miniature: "miniature (bundled test fixture, 995 entries)"
    }
  }

  /// accuracy 的絕對值在這一軌是否可信。
  public var yieldsMeaningfulAccuracy: Bool {
    switch self {
    case .factory: true
    case .miniature: false
    }
  }

  /// 把本來源掛上 `LXFacade` 的全域原廠辭典槽位。
  ///
  /// - Important: `LXFacade.factoryTrie` 是**行程內全域狀態**，故呼叫端必須確保
  ///   benchmark 與其它測試靶不並行（本靶以單一 `.serialized` 根 suite 保證，
  ///   CLI 側則靠 `--no-parallel`）。
  @discardableResult
  public func connect() -> Bool {
    LXAssembly.LXFacade.disconnectFactoryDictionary()
    switch self {
    case let .factory(path):
      // 必須同步載入：`connectFactoryDictionary` 的 completionHandler 標了 `@Sendable`，
      // 非同步分支會把結果丟到別的 queue 上——benchmark 需要「回來時辭典已經在位」的
      // 確定性，故先把 `asyncLoadingUserData` 壓成 false，再以全域槽位是否落定來判定成敗。
      let wasAsync = LXAssembly.LXFacade.asyncLoadingUserData
      LXAssembly.LXFacade.asyncLoadingUserData = false
      defer { LXAssembly.LXFacade.asyncLoadingUserData = wasAsync }
      LXAssembly.LXFacade.connectFactoryDictionary(textMapPath: path)
      return LXAssembly.LXFacade.isFactoryDictionaryLoaded
    case .miniature:
      return LXAssembly.LXFacade.connectToTestFactoryDictionary(
        textMapData: LXATestsData.textMapTestCoreLXData
      )
    }
  }
}
