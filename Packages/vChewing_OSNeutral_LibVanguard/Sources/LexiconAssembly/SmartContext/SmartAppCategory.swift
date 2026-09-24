// (c) 2026 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - LXAssembly.SmartAppCategory

extension LXAssembly {
  /// 前景 app 的粗類別。
  ///
  /// App-aware 學習**只存粗類別、不存完整 bundle identifier**。這既是效果上的取捨
  /// （VS Code／Xcode／Sublime 共用同一個學習桶，樣本才夠密），也是隱私上的降精度措施
  /// ——學習檔內不會留下「這個人用過哪些 app」的完整紀錄。
  ///
  /// - Important: `rawValue` 會被寫進使用者的學習資料檔，**一經發佈即不可更名**；
  ///   新增類別是相容的（舊檔讀不到新類別、新版讀舊檔照舊），刪除或更名則不是。
  public enum SmartAppCategory: String, Codable, Sendable, CaseIterable {
    case editor
    case terminal
    case mail
    case chat
    case browser
    case other

    // MARK: Public

    /// 把 bundle identifier 正規化成粗類別。未知者一律 `.other`。
    ///
    /// 比對一律小寫化後以「關鍵字內含」判定。表刻意保守：**寧可歸 `.other`，
    /// 也不要把一個沒見過的 app 誤塞進某個類別**——誤判的代價是使用者在 A 類 app 裡
    /// 被餵了 B 類的偏好，比「這個 app 暫時學不到東西」難受得多。
    public static func categorize(bundleID: String?) -> SmartAppCategory {
      guard let bundleID, !bundleID.isEmpty else { return .other }
      let lowered = bundleID.lowercased()
      for (category, needles) in knownNeedles {
        if needles.contains(where: { lowered.contains($0) }) { return category }
      }
      return .other
    }

    // MARK: Private

    private static let knownNeedles: [(SmartAppCategory, [String])] = [
      (
        .editor,
        [
          "vscode", "com.apple.dt.xcode", "sublimetext", "jetbrains",
          "com.github.atom", "neovim", "emacs", "com.panic.nova", "zed",
        ]
      ),
      (.terminal, ["com.apple.terminal", "iterm", "warp.", "alacritty", "kitty", "tabby", "ghostty"]),
      (.mail, ["com.apple.mail", "mailmate", "airmail", "sparkmailapp", "com.microsoft.outlook", "thunderbird"]),
      (.chat, ["slack", "discord", "telegram", "com.apple.messages", "line.", "whatsapp", "wechat", "com.hnc.discord"]),
      (.browser, ["safari", "com.google.chrome", "firefox", "com.microsoft.edgemac", "company.thebrowser", "brave"]),
    ]
  }
}
