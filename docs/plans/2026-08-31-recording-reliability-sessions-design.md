# Recording Reliability and Session Architecture

## Goal

Make Hushnote dependable as a meeting recorder before expanding its post-meeting
memory features. Capture system audio and an optional microphone independently,
survive source and device interruptions without ending the meeting, and let
finalization run behind a later recording.

The first implementation slice establishes the durable model this requires:
one meeting may contain several recording sessions, each session may contain
several source-specific takes, and processing is represented separately from
capture ownership.

## Durable media model

- A `RecordingSession` belongs to one meeting and carries an ordinal, origin,
  wall-clock start and end, meeting-timeline start, captured duration, and
  lifecycle state.
- A `SessionAudioSource` gives a stable identity to one system, microphone, or
  imported source. It records its semantic role, label, selected device, and
  whether the source was expected.
- An `AudioTake` is one immutable crash-recoverable file produced by a source.
  Device changes, pause/resume, sleep/wake, retries, and microphone toggles close
  the current take and open another rather than rewriting an existing file.
- A `RecordingEvent` records pause, sleep, source recovery, format change,
  dropped audio, and continued-session boundaries without inserting synthetic
  transcript prose.
- A `FinalizationJob` belongs to one session. Capture closes and registers the
  session before a job is queued, so another meeting may start while processing
  continues.

Existing meetings are migrated into a synthetic legacy session. Existing
audio paths and transcript identifiers remain valid. The old one-track-per-
meeting/source uniqueness constraint is removed without touching columns that
fire the expensive transcript FTS update trigger.

## Timeline and source behavior

The authoritative meeting timeline is captured-media time, derived from audio
that has been written successfully. Intentional pauses and sleep gaps do not
become recorded silence; the timeline freezes while a boundary stores the
omitted wall duration. Transcript segments, markers, playback, and appended
sessions address this same clock.

System and microphone capture are independent. A meeting may continue with one
healthy expected source, but the interface must never claim both are recorded
unless both writers are advancing. Microphone audio is always attributed to
the reserved speaker `You`. Leakage detection may suppress duplicate derived
transcript or playback material, but never modifies source originals.

## Processing and retention

A persistent scheduler claims one queued session job at a time. Heavy local
decoding does not begin during capture; in-flight work yields between take and
diarization stages. Stale running jobs return to the queue after relaunch, and
failures retain their audio for retry.

Finalization writes only the session it processed. Continuing a meeting must
not retranscribe or replace earlier sessions. Transcript identifiers therefore
include session and stable source identity, and later insight snapshots are
stamped with the resulting transcript generation.

Audio retention becomes an explicit three-way policy: transcript only,
compressed playback audio, or source originals plus compressed playback audio.
Deletion occurs only after successful transcription and atomic validation of
any promised compressed copy.

## Presentation contract

The compact recording pill remains simple. Detailed evidence belongs in the
active meeting workspace and, on demand, the expanded floating panel. Health is
derived from writer advancement and source telemetry rather than waveform
motion. Only an expected unavailable source is a warning.

High-frequency meter, transcript, clock, confidence, and playback observations
remain leaf views so `ActiveMeetingView.body` never rebuilds the notes editor at
audio or ASR cadence. The transcript keeps its 704-point reading measure,
apparatus margin, hidden scroll indicators, bottom inset, and existing follow
semantics.

## Delivery order

1. Sessions, source manifests, takes, timeline events, append-safe identifiers,
   recovery, and persistent finalization jobs.
2. Independent microphone capture, selection and live toggle, source health,
   leakage handling, device recovery, sleep/wake, and disk protection.
3. Sample-clock markers, global quick notes, expanded floating controls, live
   find, background ETA, and completion notifications.
4. Continue recording, media import, archival conversion, mixed playback/export,
   and synchronized transcript playback.
5. Transcript revisions, review inbox, speaker correction, evidence-preserving
   insight tools, archive search, and the later meeting-memory roadmap.

## Validation

Every slice uses injectable source, clock, disk, job, media, notification, and
playback seams rather than constructing `AppCoordinator` in tests. Required
coverage includes legacy migration, FTS trigger scope, source-specific recovery,
take offsets, pause and sleep boundaries, append-only finalization, identifier
uniqueness, job restart/retry, and retention safety.

Before release, run both Swift test frameworks, force a full Swift recompile to
verify project warnings, build the application bundle, and exercise built-in,
USB, and AirPods microphones plus output changes, sleep/wake, and low-disk
conditions on real hardware.
