/// Reads OpenCode's SQLite session store.
///
/// OpenCode is the one tool that keeps a structured index of its own sessions —
/// id, directory, title, model and timestamps — so it needs no transcript
/// parsing and no hook (ADR-0004). Everything here is read-only; the database
/// belongs to OpenCode and we are a guest in it.

import Foundation
import SQLite3

struct OpenCodeSessionRow: Sendable {
  let id: String
  let directory: String?
  let title: String?
  let model: String?
  let updated: Date
}

enum OpenCodeStore {
  static let databaseURL = FileManager.default
    .homeDirectoryForCurrentUser
    .appending(path: ".local/share/opencode/opencode.db")

  /// Root, unarchived sessions, newest first.
  ///
  /// Sub-sessions (`parent_id` set) are OpenCode's sub-agents: they belong to a
  /// parent session's turn rather than being something the user starts or
  /// returns to, so surfacing them would multiply one session into many cards.
  static func sessions(from url: URL = databaseURL, limit: Int = 100) -> [OpenCodeSessionRow] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    guard let db = open(url) else { return [] }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT id, directory, title, model, time_updated
      FROM session
      WHERE parent_id IS NULL AND time_archived IS NULL
      ORDER BY time_updated DESC
      LIMIT \(limit)
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }

    var rows: [OpenCodeSessionRow] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let id = text(statement, 0) else { continue }
      let millis = sqlite3_column_int64(statement, 4)
      rows.append(
        OpenCodeSessionRow(
          id: id,
          directory: text(statement, 1),
          title: displayTitle(text(statement, 2)),
          model: modelName(from: text(statement, 3)),
          updated: Date(timeIntervalSince1970: Double(millis) / 1000)
        )
      )
    }
    return rows
  }

  // MARK: - Connection

  /// Opens the store read-only.
  ///
  /// The database runs in WAL mode, where a reader needs the `-shm` index to
  /// see anything not yet checkpointed. Plain read-only opens map it and get
  /// current data. When that fails — no `-shm` present and no permission to
  /// create one — `immutable` still reads the main database file, at the cost
  /// of missing whatever is sitting in the WAL.
  private static func open(_ url: URL) -> OpaquePointer? {
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
    for uri in ["file:\(url.path)?mode=ro", "file:\(url.path)?mode=ro&immutable=1"] {
      var handle: OpaquePointer?
      guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let db = handle else {
        if handle != nil { sqlite3_close(handle) }
        continue
      }
      // SQLite connects lazily, so a connection that cannot actually read the
      // database still opens cleanly and only fails on its first statement.
      // Probe before accepting one — otherwise the fallback below is
      // unreachable, and the store silently reads as empty whenever OpenCode
      // has checkpointed its WAL away.
      if sqlite3_exec(db, "SELECT 1 FROM sqlite_schema LIMIT 1", nil, nil, nil) == SQLITE_OK {
        sqlite3_busy_timeout(db, 200)
        return db
      }
      sqlite3_close(db)
    }
    return nil
  }

  // MARK: - Column helpers

  private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, index) else { return nil }
    let value = String(cString: cString)
    return value.isEmpty ? nil : value
  }

  /// OpenCode names an untitled session after its creation timestamp, which
  /// tells the reader nothing they cannot see from the elapsed-time field.
  private static func displayTitle(_ title: String?) -> String? {
    guard let title, !title.hasPrefix("New session - ") else { return nil }
    return truncate(title)
  }

  /// `model` is stored as JSON: `{"id":"deepseek-v4-pro","providerID":"Eden"}`.
  private static func modelName(from json: String?) -> String? {
    guard let data = json?.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["id"] as? String
  }
}
