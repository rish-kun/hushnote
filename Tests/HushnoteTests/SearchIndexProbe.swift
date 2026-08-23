import Foundation
import GRDB
@testable import Hushnote

/// Reaches into `transcriptSegmentFTS` from a second connection so a test can
/// tell whether a write actually reached a row.
///
/// The v5 trigger is the only thing that rebuilds an FTS row, and it fires on
/// an UPDATE naming `text` or `speakerName`. Deleting the row and then searching
/// for it is therefore a direct readout of whether such an UPDATE was issued —
/// `MeetingStore` exposes no connection of its own to count changes on.
///
/// This lives apart from `PersistenceTests` because importing GRDB there makes
/// `PersistenceError` ambiguous against GRDB's deprecated typealias.
enum SearchIndexProbe {
    static func removeRow(forSegment segmentID: String, at databaseURL: URL) throws {
        let connection = try DatabaseQueue(path: databaseURL.path)
        try connection.write { db in
            try db.execute(
                sql: "DELETE FROM transcriptSegmentFTS WHERE segmentID = ?",
                arguments: [segmentID]
            )
        }
    }
}
