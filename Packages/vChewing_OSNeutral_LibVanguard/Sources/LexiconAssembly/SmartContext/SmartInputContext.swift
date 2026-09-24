// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - LXAssembly.SmartInputContext

extension LXAssembly {
  /// SmartContextScorer 的輸入語境。
  ///
  /// 這是一份**當拍快照**：由 `LibVanguard` 在每次組句之前就地組裝，不持有任何
  /// 會被別處改動的參照。它刻意保持 OS-neutral——`appCategory` 是已經正規化過的
  /// 粗類別，portable 這一側不認得 bundle identifier，也不該認得。
  public struct SmartInputContext: Sendable, Hashable {
    // MARK: Lifecycle

    public init(
      precedingValues: [String] = [],
      currentReading: [String] = [],
      appCategory: SmartAppCategory = .other,
      recentSelections: [String] = [],
      recentCorrections: [SmartCorrection] = [],
      sessionVocabulary: Set<String> = []
    ) {
      self.precedingValues = precedingValues
      self.currentReading = currentReading
      self.appCategory = appCategory
      self.recentSelections = recentSelections
      self.recentCorrections = recentCorrections
      self.sessionVocabulary = sessionVocabulary
    }

    // MARK: Public

    /// 語境詞的保留上限。
    ///
    /// 取 4 的理由：既有的 n-gram 只看到 `previous` / `anterior`（2 階），再往前的詞
    /// 對「這個位置該選哪個同音詞」的資訊量衰減得很快，而語境越長、每次組句前壓平
    /// boost 表的成本就越高。4 讓 deterministic scorer 能看見「執行 … 程式」這種
    /// 隔一兩個詞的搭配，又不至於讓一整句話都變成語境。
    public static let maxPrecedingValues = 4

    /// 已定詞值，**由近而遠**（`[0]` 是緊鄰游標的前一個詞），至多 `maxPrecedingValues` 筆。
    public let precedingValues: [String]
    /// 當前待決位置的讀音索引鍵陣列。
    public let currentReading: [String]
    /// 前景 app 的粗類別；`app_aware_learning_enabled` 關閉時恆為 `.other`。
    public let appCategory: SmartAppCategory
    /// 本次 session 內最近被顯式選中的詞，由近而遠。
    public let recentSelections: [String]
    /// 本次 session 內最近發生的「A 改成 B」。
    public let recentCorrections: [SmartCorrection]
    /// Session-local 詞彙：本次 session 內出現過、值得短期加權的詞。
    public let sessionVocabulary: Set<String>

    /// 空語境。`smart_context_enabled` 關閉時即為此值。
    public static let empty = SmartInputContext()

    /// 游標之前的語境文字（由遠而近拼成）。
    ///
    /// 刻意是 computed 而非 stored：`SmartInputContext` 每有語境變動就要重建一次，
    /// 而把整個組字區 `joined()` 成字串是個每次都要付的配置——實測光是這一項就讓
    /// per-keystroke p95 多出約 4%。需要整句視野的實作自己呼叫它，不需要的就不付錢。
    public var precedingText: String {
      precedingValues.reversed().joined()
    }

    /// 是否完全沒有可用的語境訊號——此時任何 scorer 都應直接回 0，省下壓表的成本。
    public var isBarren: Bool {
      precedingValues.isEmpty
        && recentSelections.isEmpty
        && recentCorrections.isEmpty
        && sessionVocabulary.isEmpty
        && appCategory == .other
    }
  }

  /// 一次「把 A 改成 B」的紀錄。
  public struct SmartCorrection: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(from rejected: String, to accepted: String) {
      self.rejected = rejected
      self.accepted = accepted
    }

    // MARK: Public

    /// 被使用者換掉的那個詞。
    public let rejected: String
    /// 使用者改選的那個詞。
    public let accepted: String
  }
}
