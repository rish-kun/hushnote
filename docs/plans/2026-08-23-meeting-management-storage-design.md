# Meeting Management and Storage Design

## Summary

Hushnote adds explicit summary editing with immutable version history, meeting
renaming, recoverable deletion, a storage dashboard, and a configurable speech
model cache. Generated summaries are candidates: regeneration never silently
replaces the summary the user has selected or authored.

## Durable model

- `Meeting` gains `activeSummaryVersionID` and `deletedAt`. Normal meeting lists
  exclude deleted rows; Recently Deleted retains them for 30 days.
- `SummaryVersion` stores immutable manual or generated text. Generated versions
  reference their source insight snapshot; provider and structured insight data
  remain authoritative in that snapshot.
- Saving provider output atomically creates its generated version. It activates
  only when the meeting has no active summary. A user can explicitly activate
  any candidate or historical version.
- The migration backfills one generated version per existing insight snapshot
  and selects the newest for each meeting.

## Meeting and storage behavior

- Rename writes only `title` and `updatedAt`; blank titles are rejected.
- Deletion first moves a meeting to Recently Deleted. Restore clears the marker.
  Permanent deletion and automatic expiry remove retained audio before deleting
  the cascading relational graph, keeping retry information if file removal
  fails.
- The model cache setting applies to Whisper model download and load paths. A
  directory change is blocked during recording, finalization, or download and
  does not automatically copy multi-gigabyte existing caches.
- Storage accounting reports database, recovery audio, model cache, and local
  GGUF usage without traversing directories on SwiftUI render paths.

## Acceptance checks

- Manual summary whitespace round-trips, blank-only summaries fail, history is
  paginated, and regeneration leaves the active manual version unchanged.
- Existing insight history is backfilled without losing the current summary.
- Rename preserves unrelated meeting fields.
- Soft-deleted meetings disappear from normal lists, restore cleanly, and purge
  cascades metadata only after audio cleanup succeeds.
- Model-directory preferences persist, reset to the default, and are threaded
  through download, live, and final transcription configurations.
