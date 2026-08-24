# Folders and Responsive Redesign Design

## Summary

Hushnote will reorganize meeting navigation around a responsive sidebar and a
flat, optional folder system. Folders make it possible to group meetings
without changing a meeting's lifecycle, transcript, search, or recording
behavior. The app remains useful at compact window sizes: navigation condenses
without hiding the current meeting or turning the workspace into a modal flow.

## Information architecture

- The sidebar has first-class destinations for All Meetings, Unfiled, folders,
  Recently Deleted, Models, Storage, and Settings.
- A folder is a flat collection. It has no nesting, color, manual ordering, or
  other presentation metadata. Folders are shown alphabetically.
- A meeting belongs to zero or one folder. Unfiled is the explicit name for
  meetings without a folder.
- Search is global: it filters matching meeting title, excerpt, and transcript
  content irrespective of the selected folder.
- Creating a meeting while a folder is selected assigns that folder. Meetings
  created from any other destination start Unfiled.

## Durable model and persistence

- `Meeting` gains an optional `folderID`; `MeetingFolder` has an identifier,
  display name, creation/update timestamps, and optional deletion timestamp.
- Migration v8 creates `meetingFolders`, adds nullable `meetings.folderID`,
  uses a foreign key with `ON DELETE SET NULL`, and indexes both the meeting
  folder column and the active-folder listing path. Existing meetings stay
  Unfiled.
- Folder names are trimmed, 1–80 characters, and unique under case- and
  diacritic-insensitive comparison. The database retains a normalized key to
  make the uniqueness guarantee durable across process boundaries.
- Deleting a folder is a durable soft delete. Its meetings are unfiled, never
  deleted. Restoring a soft-deleted meeting retains its folder assignment when
  that folder still exists; if a folder was deleted, its members were already
  unfiled.
- Folder counts include active meetings only and exclude deleted meetings.

## State and coordinator behavior

- `SidebarDestination` adds `.allMeetings`, `.unfiled`, `.folder(UUID)`, and
  `.recentlyDeleted` while preserving existing destinations during the UI
  transition. Persisted selection serializes folders as `folder:<UUID>`.
- Startup validates persisted folder selection against active folders; a stale
  or deleted folder falls back to All Meetings and rewrites the preference.
- App state keeps the active folders, per-folder counts, and each list item's
  optional folder. Coordinator APIs perform create, rename, delete, move, and
  reload work, then refresh the minimal affected list state.
- Moving a meeting is allowed while it is recording and intentionally updates
  only `folderID`, not `updatedAt`, so chronological meeting ordering does not
  jump during organization.

## Responsive presentation

- Wide windows present the persistent sidebar and contextual folder controls.
  Compact windows use an accessible navigation affordance while keeping the
  selected meeting workspace primary.
- Folder management uses concise create/rename dialogs and contextual move
  controls. Counts and selection remain readable at every supported size.
- Empty states distinguish an empty folder, Unfiled, and global search with a
  direct next action.

## Verification

- Migration tests cover v7-to-v8 schema upgrade, legacy Unfiled meetings,
  indexes, and foreign-key unfiling behavior.
- Persistence tests cover normalized name validation, duplicate rejection,
  sorting, bulk queries/counts, soft deletion, restore, targeted moves, and
  meeting lifecycle interactions.
- State/preference tests cover folder destinations, serialized selection,
  stale-selection fallback, and selected-folder inheritance for new meetings.
- UI tests cover destination routing, global search behavior, and compact and
  wide-window navigation treatment.
