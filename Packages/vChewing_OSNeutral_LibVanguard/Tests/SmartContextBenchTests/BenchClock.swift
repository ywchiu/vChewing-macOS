// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - BenchLatencySamples

/// 一組延遲取樣，單位為毫秒。
///
/// - Remark: 刻意只保留原始取樣、在取值時才排序——benchmark 的樣本數是千的量級，
///   排序成本相對於量測本身可以忽略，而保留原始序列讓「事後想換個百分位」不必重跑。
public struct BenchLatencySamples: Sendable {
  // MARK: Lifecycle

  public init(label: String) {
    self.label = label
  }

  // MARK: Public

  public let label: String
  public private(set) var milliseconds: [Double] = []

  public var count: Int { milliseconds.count }

  public var mean: Double {
    guard !milliseconds.isEmpty else { return 0 }
    return milliseconds.reduce(0, +) / Double(milliseconds.count)
  }

  public var p50: Double { percentile(0.50) }
  public var p95: Double { percentile(0.95) }
  public var p99: Double { percentile(0.99) }
  public var max: Double { milliseconds.max() ?? 0 }

  public mutating func reserveCapacity(_ capacity: Int) {
    milliseconds.reserveCapacity(capacity)
  }

  public mutating func record(_ value: Double) {
    milliseconds.append(value)
  }

  /// 量測一段同步工作並記錄其耗時，同時原樣回傳該工作的結果。
  @discardableResult
  public mutating func measure<T>(_ body: () -> T) -> T {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = body()
    let end = DispatchTime.now().uptimeNanoseconds
    record(Double(end &- start) / 1_000_000.0)
    return result
  }

  /// 線性插值百分位（與多數 benchmark 工具的慣例一致）。
  public func percentile(_ ratio: Double) -> Double {
    guard !milliseconds.isEmpty else { return 0 }
    let sorted = milliseconds.sorted()
    guard sorted.count > 1 else { return sorted[0] }
    let position = Swift.max(0, Swift.min(1, ratio)) * Double(sorted.count - 1)
    let lowerIndex = Int(position.rounded(.down))
    let upperIndex = Swift.min(lowerIndex + 1, sorted.count - 1)
    let fraction = position - Double(lowerIndex)
    return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
  }
}

// MARK: - BenchWarmup

public enum BenchWarmup {
  /// 每個量測區段之前先跑幾輪不記錄的暖身。
  ///
  /// 沒有暖身的話首批取樣會被「辭典 LRU 冷啟＋首次 trie VALUES 解析」污染，
  /// 在 13 MB 的真實辭典上首筆可達數十毫秒，p95 會被單筆離群值整個拉歪。
  public static let iterations = 3
}
