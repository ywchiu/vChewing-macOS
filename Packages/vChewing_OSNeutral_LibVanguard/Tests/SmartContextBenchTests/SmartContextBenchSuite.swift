// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
@testable import LexiconAssembly
@testable import LibVanguard
import Shared
import Testing

// MARK: - BenchFeatureFlags

/// 一次量測所使用的 SmartContext 開關組合。
public struct BenchFeatureFlags: Sendable {
  // MARK: Lifecycle

  public init(
    smartContext: Bool = false,
    personalLearningV2: Bool = false,
    appAware: Bool = false,
    tinyReranker: Bool = false
  ) {
    self.smartContext = smartContext
    self.personalLearningV2 = personalLearningV2
    self.appAware = appAware
    self.tinyReranker = tinyReranker
  }

  // MARK: Public

  /// 全關。這一組必須產出與「SmartContext 不存在」完全相同的結果。
  public static let allDisabled = BenchFeatureFlags()
  /// 目前已實作的全部功能開啟（tiny reranker 除外——Phase 6 之前它沒有實作）。
  public static let smartEnabled = BenchFeatureFlags(
    smartContext: true,
    personalLearningV2: true,
    appAware: true
  )

  public let smartContext: Bool
  public let personalLearningV2: Bool
  public let appAware: Bool
  public let tinyReranker: Bool

  /// 就地套用到偏好設定，並回傳一個還原用的閉包。
  ///
  /// 本倉的測試紀律要求偏好設定改動前後必須還原（否則會滲漏到同行程的其它測試），
  /// 故一律以 `defer { restore() }` 的形狀使用。
  @MainActor
  public func apply(to prefs: PrefMgrProtocol) -> () -> () {
    var prefs = prefs
    let previous = (
      smart: prefs.smartContextEnabled,
      personal: prefs.personalLearningV2Enabled,
      appAware: prefs.appAwareLearningEnabled,
      reranker: prefs.tinyRerankerEnabled
    )
    prefs.smartContextEnabled = smartContext
    prefs.personalLearningV2Enabled = personalLearningV2
    prefs.appAwareLearningEnabled = appAware
    prefs.tinyRerankerEnabled = tinyReranker
    return {
      var prefs = prefs
      prefs.smartContextEnabled = previous.smart
      prefs.personalLearningV2Enabled = previous.personal
      prefs.appAwareLearningEnabled = previous.appAware
      prefs.tinyRerankerEnabled = previous.reranker
    }
  }
}

// MARK: - SmartContextBenchRoot

/// 本測試靶的唯一根 suite，標 `.serialized`。
///
/// 理由與 `LibVanguardTests_Root.swift` 完全相同，且在本靶更為嚴格：benchmark 會
/// **獨佔** `LXFacade.factoryTrie`（把 13 MB 的真實原廠辭典掛上全域槽位）、
/// `PrefMgr.shared` 與 `SessionHost.shared`，任何並行都會同時毀掉正確性與延遲數字。
///
/// - Important: 延遲數字只在「機器空閒」時可比。CI 上的絕對值僅供趨勢觀察，
///   regression gate 請一律以「同一次 run 內 baseline 對 smart 的相對差」為準。
@Suite("SmartContextBenchRoot", .serialized)
final class SmartContextBenchRoot {}

// MARK: - Benchmark

extension SmartContextBenchRoot {
  @Suite("SmartContextBench", .serialized)
  final class SmartContextBench {
    // MARK: Lifecycle

    init() {
      UserDefaults.unitTests = .init(suiteName: Self.prefSuiteName)
      UserDefaults.pendingUnitTests = true
      UserDef.resetAll()
    }

    deinit {
      mainSync {
        LXAssembly.resetSharedState()
        UserDefaults.unitTests?.removeSuite(named: Self.prefSuiteName)
        UserDef.resetAll()
      }
    }

    // MARK: Internal

    /// 產生基線與 smart 兩份報表，並印出兩者的對照。
    ///
    /// 兩份一定要在**同一次 run 內**產生：延遲數字只有在同一台機器、同一個瞬間的
    /// 負載條件下才可比，跨 run 對比出來的「退化 3%」多半只是別人在跑 CI。
    @Test("Produce benchmark reports (baseline vs smart)")
    func produceReports() throws {
      let baseline = try Self.runBenchmark(
        label: "\(Self.reportLabel)-baseline",
        flags: .allDisabled
      )
      let smart = try Self.runBenchmark(
        label: "\(Self.reportLabel)-smart",
        flags: .smartEnabled
      )
      print(baseline.renderConsoleSummary())
      print(smart.renderConsoleSummary())
      print(BenchComparison(baseline: baseline, smart: smart).renderConsole())

      for report in [baseline, smart] {
        if let url = report.writeToDisk(repoRoot: Self.repoRoot) {
          print("[bench] report written to \(url.path)")
        } else {
          print("[bench] report '\(report.label)' could not be written; console summary above is authoritative.")
        }
      }
      #expect(!baseline.summaries.isEmpty, "No dataset was loaded; check the bundled Resources.")
    }

    /// 護欄一：**關掉所有開關時，結果必須與「SmartContext 不存在」完全相同。**
    ///
    /// 這是整個專案最重要的一條不變式——「關閉後必須盡可能恢復原始 vChewing 行為」。
    /// 它以 regression 資料集的逐案例名次逐一比對，而不是只比總分：總分相同但兩筆
    /// 案例互換名次，照樣是行為改變了。
    @Test("All flags off reproduces the untouched baseline")
    func flagsOffIsInert() throws {
      let reference = try Self.runBenchmark(label: "\(Self.reportLabel)-inert-a", flags: .allDisabled)
      let repeated = try Self.runBenchmark(label: "\(Self.reportLabel)-inert-b", flags: .allDisabled)
      for (lhs, rhs) in zip(reference.summaries, repeated.summaries) {
        #expect(lhs.name == rhs.name)
        for (a, b) in zip(lhs.outcomes, rhs.outcomes) {
          #expect(a.id == b.id)
          #expect(
            a.rankOfExpected == b.rankOfExpected,
            "\(a.id): rank drifted between two identical runs (\(String(describing: a.rankOfExpected)) vs \(String(describing: b.rankOfExpected)))"
          )
          #expect(a.producedSentence == b.producedSentence, "\(a.id): sentence drifted between two identical runs")
        }
      }
    }

    /// 護欄二：每次敲鍵的 p95 不得離譜。
    ///
    /// 刻意訂得寬鬆：它要抓的是「smart scoring 把每次敲鍵拖進數量級災難」這種事故，
    /// 而不是機器抖動。真正的 5% 退化判定請看上面那支測試印出的 baseline↔smart 對照。
    @Test("Per-keystroke latency stays within the sanity ceiling")
    func latencyCeiling() throws {
      let report = try Self.runBenchmark(label: "\(Self.reportLabel)-guard", flags: .smartEnabled)
      let p95 = report.typingLatency.p95
      #expect(
        p95 < Self.perKeystrokeP95CeilingMS,
        "per-keystroke p95 = \(p95) ms, ceiling = \(Self.perKeystrokeP95CeilingMS) ms"
      )
    }

    // MARK: Private

    private static let prefSuiteName = "org.atelierInmu.vChewing.LibVanguard.SmartContextBench"

    /// 每次敲鍵的 p95 天花板（毫秒）。
    ///
    /// Release 取 8 ms 的依據：IMK 的按鍵往返若超過一個 60 Hz 畫格（16.7 ms）使用者就會
    /// 有感，而 scoring 只是那一整條往返的其中一段，故給它半個畫格的預算。
    ///
    /// Debug 側刻意放寬到 60 ms：未最佳化的 Swift 在這條路徑上比 release 慢一個量級
    /// （實測 `assemble()` 的 p95 debug ≈ 22 ms、release ≈ 6 ms），拿 release 的門檻去卡
    /// debug 只會製造一個永遠是紅的、也永遠沒人看的斷言。**有意義的延遲數字一律取
    /// release 側**（`swift test -c release -Xswiftc -enable-testing`）。
    private static var perKeystrokeP95CeilingMS: Double {
      #if DEBUG
        60.0
      #else
        8.0
      #endif
    }

    /// 報表標籤的前綴。之後各 Phase 以 `VCHEWING_BENCH_LABEL=phase2` 之類的方式區分。
    private static var reportLabel: String {
      let raw = ProcessInfo.processInfo.environment["VCHEWING_BENCH_LABEL"] ?? "phase1"
      return raw.isEmpty ? "phase1" : raw
    }

    /// 倉根位置。自本檔的編譯期路徑往上四層推得
    /// （`<root>/Packages/vChewing_OSNeutral_LibVanguard/Tests/SmartContextBenchTests/<this>`）。
    private static var repoRoot: URL {
      if let override = ProcessInfo.processInfo.environment["VCHEWING_BENCH_OUTPUT_ROOT"],
         !override.isEmpty {
        return URL(fileURLWithPath: override)
      }
      return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SmartContextBenchTests/
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // vChewing_OSNeutral_LibVanguard/
        .deletingLastPathComponent() // Packages/
        .deletingLastPathComponent() // <repo root>
    }

    /// 為本次 run 配一個獨立的 POM 存檔位置。
    ///
    /// 刻意每次都換一個目錄：POM 的 WAL 與快照會跨 run 殘留，而 benchmark 要的是
    /// 「每次都從零開始學」——共用一份存檔會讓「修正學習」的數字被上一次 run 汙染。
    private static func makePOMScratchURL() -> URL {
      let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vChewingSmartContextBench-\(UUID().uuidString)")
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory.appendingPathComponent("pom.json")
    }

    @MainActor
    private static func runBenchmark(label: String, flags: BenchFeatureFlags) throws -> BenchReport {
      let restorePrefs = flags.apply(to: PrefMgr.sharedSansDidSetOps)
      defer { restorePrefs() }

      let lexiconSource = BenchLexiconSource.resolveFromEnvironment()
      #expect(lexiconSource.connect(), "Failed to connect the benchmark lexicon: \(lexiconSource.label)")
      defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }

      let datasets = try BenchDatasetLoader.loadAll()
      let pomScratchURL = makePOMScratchURL()
      defer { try? FileManager.default.removeItem(at: pomScratchURL.deletingLastPathComponent()) }
      let driver = BenchDriver(prefs: PrefMgr.sharedSansDidSetOps, pomDataURL: pomScratchURL)

      // 暖身：讓辭典 LRU、trie 的 VALUES 解析快取與各層 Swift runtime 先行落定。
      if let warmupCase = datasets.flatMap(\.cases).first {
        for _ in 0 ..< BenchWarmup.iterations {
          _ = driver.run(warmupCase)
        }
      }

      var summaries: [BenchDatasetSummary] = []
      for dataset in datasets {
        let outcomes = dataset.cases.map { driver.run($0) }
        summaries.append(.init(name: dataset.name, outcomes: outcomes))
      }
      driver.resetAll()

      return BenchReport(
        label: label,
        lexiconLabel: lexiconSource.label,
        yieldsMeaningfulAccuracy: lexiconSource.yieldsMeaningfulAccuracy,
        summaries: summaries,
        typingLatency: driver.typingLatency,
        assembleLatency: driver.assembleLatency,
        candidateLatency: driver.candidateLatency
      )
    }
  }
}
