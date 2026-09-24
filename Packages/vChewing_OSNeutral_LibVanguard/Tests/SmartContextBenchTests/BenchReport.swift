// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - BenchDatasetSummary

/// 一份資料集的彙總結果。
public struct BenchDatasetSummary: Sendable {
  // MARK: Lifecycle

  public init(name: String, outcomes: [BenchCaseOutcome]) {
    self.name = name
    self.outcomes = outcomes
  }

  // MARK: Public

  public let name: String
  public let outcomes: [BenchCaseOutcome]

  /// 實際計分的案例（排除因辭典缺料而跳過者）。
  public var scored: [BenchCaseOutcome] { outcomes.filter { !$0.isSkipped } }
  public var skipped: [BenchCaseOutcome] { outcomes.filter(\.isSkipped) }

  public var top1Accuracy: Double { ratio(of: \.isTop1) }
  public var top3Recall: Double { ratio(of: \.isTop3) }
  public var sentenceAccuracy: Double { ratio(of: \.isSentenceCorrect) }

  /// 平均手動修正次數。越低越好；0 表示每一筆都一次到位。
  public var meanCorrectionCount: Double {
    let scored = scored
    guard !scored.isEmpty else { return 0 }
    return Double(scored.map(\.correctionCount).reduce(0, +)) / Double(scored.count)
  }

  /// 總手動修正次數。這是「使用者到底要動幾次手」的絕對量，跨版本比較時比平均值直觀。
  public var totalCorrectionCount: Int { scored.map(\.correctionCount).reduce(0, +) }

  // MARK: Private

  private func ratio(of keyPath: KeyPath<BenchCaseOutcome, Bool>) -> Double {
    let scored = scored
    guard !scored.isEmpty else { return 0 }
    return Double(scored.filter { $0[keyPath: keyPath] }.count) / Double(scored.count)
  }
}

// MARK: - BenchReport

/// benchmark 的完整結果與其 Markdown 報表。
public struct BenchReport: Sendable {
  // MARK: Lifecycle

  public init(
    label: String,
    lexiconLabel: String,
    yieldsMeaningfulAccuracy: Bool,
    summaries: [BenchDatasetSummary],
    typingLatency: BenchLatencySamples,
    assembleLatency: BenchLatencySamples,
    candidateLatency: BenchLatencySamples
  ) {
    self.label = label
    self.lexiconLabel = lexiconLabel
    self.yieldsMeaningfulAccuracy = yieldsMeaningfulAccuracy
    self.summaries = summaries
    self.typingLatency = typingLatency
    self.assembleLatency = assembleLatency
    self.candidateLatency = candidateLatency
  }

  // MARK: Public

  /// 本次量測的標籤，例如 `baseline` 或 `smart`。
  public let label: String
  public let lexiconLabel: String
  public let yieldsMeaningfulAccuracy: Bool
  public let summaries: [BenchDatasetSummary]
  public let typingLatency: BenchLatencySamples
  public let assembleLatency: BenchLatencySamples
  public let candidateLatency: BenchLatencySamples

  /// 報表的輸出位置。`Build/Bench/` 已在倉根 `.gitignore` 的 `Build/` 涵蓋範圍內。
  public static func reportURL(label: String, repoRoot: URL) -> URL {
    repoRoot
      .appendingPathComponent("Build")
      .appendingPathComponent("Bench")
      .appendingPathComponent("smart_context_\(label).md")
  }

  public func renderMarkdown() -> String {
    var lines: [String] = []
    lines.append("# SmartContext Benchmark — `\(label)`")
    lines.append("")
    lines.append("- 產生時間：\(Self.timestampFormatter.string(from: Date()))")
    lines.append("- 辭典：\(lexiconLabel)")
    if !yieldsMeaningfulAccuracy {
      lines.append("")
      lines.append(
        "> ⚠️ 本次以**小辭典**執行，準確率的絕對值不具參考意義（只能用於「同辭典下的前後比較」）。"
      )
      lines.append("> 若要真實數字，請設 `VCHEWING_BENCH_TEXTMAP=<path to VanguardFactoryDict4Typing.txtMap>`。")
    }
    lines.append("")
    lines.append("## 準確率")
    lines.append("")
    lines.append("| 資料集 | 計分 | 跳過 | Top-1 | Top-3 | 句子正確 | 平均修正 | 總修正 |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for summary in summaries {
      lines.append(
        "| \(summary.name) | \(summary.scored.count) | \(summary.skipped.count) "
          + "| \(Self.percent(summary.top1Accuracy)) | \(Self.percent(summary.top3Recall)) "
          + "| \(Self.percent(summary.sentenceAccuracy)) "
          + "| \(String(format: "%.2f", summary.meanCorrectionCount)) | \(summary.totalCorrectionCount) |"
      )
    }
    lines.append("")
    lines.append("## 延遲（毫秒）")
    lines.append("")
    lines.append("| 區段 | 取樣數 | mean | p50 | p95 | p99 | max |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for samples in [typingLatency, assembleLatency, candidateLatency] {
      lines.append(
        "| \(samples.label) | \(samples.count) | \(Self.ms(samples.mean)) | \(Self.ms(samples.p50)) "
          + "| \(Self.ms(samples.p95)) | \(Self.ms(samples.p99)) | \(Self.ms(samples.max)) |"
      )
    }
    lines.append("")
    lines.append("## 逐案例明細")
    for summary in summaries {
      lines.append("")
      lines.append("### \(summary.name)")
      lines.append("")
      lines.append("| id | 期望 | 名次 | 句子 | 前五候選 | 競爭者名次 |")
      lines.append("| --- | --- | ---: | --- | --- | --- |")
      for outcome in summary.outcomes {
        if let reason = outcome.skippedReason {
          lines.append("| \(outcome.id) | \(outcome.expected) | — | _skipped_ | — | \(reason) |")
          continue
        }
        let rank = outcome.rankOfExpected.map(\.description) ?? "**MISS**"
        let competitors = outcome.competitorRanks
          .map { "\($0.value)=\($0.rank.map(\.description) ?? "—")" }
          .joined(separator: ", ")
        let sentenceMark = outcome.isSentenceCorrect ? "✅" : "❌"
        lines.append(
          "| \(outcome.id) | \(outcome.expected) | \(rank) | \(sentenceMark) \(outcome.producedSentence) "
            + "| \(outcome.topCandidates.joined(separator: " / ")) | \(competitors) |"
        )
      }
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  /// 供 stdout 使用的精簡摘要。
  public func renderConsoleSummary() -> String {
    var lines: [String] = []
    lines.append("=== SmartContext Benchmark [\(label)] ===")
    lines.append("lexicon: \(lexiconLabel)")
    for summary in summaries {
      lines.append(
        "  \(summary.name.padding(toLength: 18, withPad: " ", startingAt: 0))"
          + " top1=\(Self.percent(summary.top1Accuracy))"
          + " top3=\(Self.percent(summary.top3Recall))"
          + " sentence=\(Self.percent(summary.sentenceAccuracy))"
          + " corrections=\(summary.totalCorrectionCount)"
          + " (scored \(summary.scored.count), skipped \(summary.skipped.count))"
      )
    }
    for samples in [typingLatency, assembleLatency, candidateLatency] {
      lines.append(
        "  \(samples.label): n=\(samples.count)"
          + " p50=\(Self.ms(samples.p50))ms p95=\(Self.ms(samples.p95))ms p99=\(Self.ms(samples.p99))ms"
      )
    }
    return lines.joined(separator: "\n")
  }

  /// 把報表寫進 `Build/Bench/`。寫檔失敗不視為錯誤（沙箱／唯讀掛載下仍應讓 benchmark 跑完）。
  @discardableResult
  public func writeToDisk(repoRoot: URL) -> URL? {
    let url = Self.reportURL(label: label, repoRoot: repoRoot)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try renderMarkdown().write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      return nil
    }
  }

  // MARK: Private

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  private static func percent(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
  }

  private static func ms(_ value: Double) -> String {
    String(format: "%.4f", value)
  }
}

// MARK: - BenchComparison

/// baseline ↔ smart 的對照。
///
/// **這才是判斷「smart 有沒有用、有沒有讓延遲變差」的依據。**兩份報表必須來自同一次
/// run：延遲數字只在同一台機器、同一個瞬間的負載條件下可比，跨 run 對比出來的
/// 「退化 3%」多半只是別人正在跑別的東西。
public struct BenchComparison: Sendable {
  // MARK: Lifecycle

  public init(baseline: BenchReport, smart: BenchReport) {
    self.baseline = baseline
    self.smart = smart
  }

  // MARK: Public

  public let baseline: BenchReport
  public let smart: BenchReport

  /// regression 資料集是否出現退步。這是唯一「不准發生」的事。
  public var hasRegression: Bool {
    guard let before = summary(in: baseline, named: "regression"),
          let after = summary(in: smart, named: "regression")
    else { return false }
    return after.totalCorrectionCount > before.totalCorrectionCount
      || after.top1Accuracy < before.top1Accuracy
  }

  public func renderConsole() -> String {
    var lines: [String] = []
    lines.append("=== baseline → smart ===")
    for after in smart.summaries {
      guard let before = summary(in: baseline, named: after.name) else { continue }
      lines.append(
        "  \(after.name.padding(toLength: 20, withPad: " ", startingAt: 0))"
          + " top1 \(Self.percent(before.top1Accuracy)) → \(Self.percent(after.top1Accuracy))"
          + " \(Self.delta(after.top1Accuracy - before.top1Accuracy))"
          + " | corrections \(before.totalCorrectionCount) → \(after.totalCorrectionCount)"
      )
    }
    // p50 與 mean 一併列出：p95 由少數離群值決定（辭典冷快取、GC、機器抖動），
    // 在 debug 側的 run-to-run 變異可達 ±10%，單看它會把雜訊當成退化。
    // 要判斷「smart 有沒有讓輸入變慢」，p50 才是那個穩定的訊號。
    let pairs: [(String, Double, Double)] = [
      ("per-keystroke p50", baseline.typingLatency.p50, smart.typingLatency.p50),
      ("per-keystroke mean", baseline.typingLatency.mean, smart.typingLatency.mean),
      ("per-keystroke p95", baseline.typingLatency.p95, smart.typingLatency.p95),
      ("assemble() p50", baseline.assembleLatency.p50, smart.assembleLatency.p50),
      ("assemble() p95", baseline.assembleLatency.p95, smart.assembleLatency.p95),
      ("candidates p50", baseline.candidateLatency.p50, smart.candidateLatency.p50),
      ("candidates p95", baseline.candidateLatency.p95, smart.candidateLatency.p95),
    ]
    for (label, before, after) in pairs {
      let ratio = before > 0 ? (after - before) / before : 0
      lines.append(
        "  \(label.padding(toLength: 20, withPad: " ", startingAt: 0))"
          + " \(String(format: "%.4f", before)) → \(String(format: "%.4f", after)) ms"
          + " (\(Self.delta(ratio)))"
      )
    }
    lines.append("  regression: \(hasRegression ? "⚠️ DETECTED" : "none")")
    return lines.joined(separator: "\n")
  }

  // MARK: Private

  private static func percent(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
  }

  private static func delta(_ value: Double) -> String {
    let sign = value >= 0 ? "+" : ""
    return "\(sign)\(String(format: "%.1f", value * 100))%"
  }

  private func summary(in report: BenchReport, named name: String) -> BenchDatasetSummary? {
    report.summaries.first { $0.name == name }
  }
}
