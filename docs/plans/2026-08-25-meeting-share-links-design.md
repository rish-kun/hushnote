# Share links: publishing a meeting to the web

*2026-08-25. New subsystem. Introduces a second codebase (`web/`), a network
boundary, and a change to what Hushnote promises.*

## What this changes about the product

The README opens with "local-first". `AGENTS.md` states "Everything runs locally
except explicitly chosen cloud summarizers." A share link means a transcript
leaves the machine and is stored, readable, in a hosted database.

That is a deliberate product decision, not a side effect, and the app must say
so at the moment it happens — the way the Ask tab already declares `OFF DEVICE`
before sending a transcript to a provider. Both documents are updated as part of
this work; a share feature that contradicts the front page of the README is a
bug in the README.

## Decisions already taken

Each of these was chosen by the project owner after the trade-off was stated.
They are settled; this document builds on them rather than reopening them.

| Decision | Chosen | Accepted cost |
|---|---|---|
| Server can read shared content | **Yes** — plaintext, password is an access check | A database breach exposes every shared transcript. No end-to-end encryption. |
| Payload | Transcript, notes, summary — **selected per share** | — |
| Audio | **Never uploaded** | — |
| Accounts | **None.** The Mac app is the owner | Losing the Keychain loses the ability to revoke existing links |
| Freshness | **Live** — the link always reflects the current meeting | Content typed later is published without a further confirmation |

The live-sync choice is the sharpest of these. Two things mitigate it, and both
are requirements rather than polish:

- **The content toggles are the real control.** Content not included in a share
  never leaves the machine, whatever is typed into it afterwards. A share
  without Notes is the only safe way to keep taking candid notes on a published
  meeting.
- **A shared meeting is visibly shared.** Its workspace header carries a
  persistent badge. Nobody should ever be typing into a published document
  without knowing it.

## Architecture

    Hushnote.app                          web/  (Vercel)
    ┌───────────────────────┐             ┌──────────────────────────┐
    │ ShareSyncService      │  PUT /api   │ Next.js App Router       │
    │  debounce, coalesce   │ ──────────▶ │  Node runtime            │
    │  bearer: device token │             │   ├ POST /api/shares     │
    │                       │             │   ├ PUT  /api/shares/:id │
    │ SharePublishing       │             │   ├ DEL  /api/shares/:id │
    │  (protocol; tests     │             │   └ POST /api/s/:id/open │
    │   never hit network)  │             │                          │
    │                       │             │ /s/:id  → rendered page  │
    │ v9_meeting_shares     │             │ Postgres (Neon)          │
    └───────────────────────┘             └──────────────────────────┘

**One repository.** `web/` lives in this repo and Vercel deploys from that
subdirectory. The payload shape is defined by the Swift side; two repositories
would drift the first time a field is added. A checked-in `payload.schema.json`
is the contract, and the TypeScript type is generated from it.

**Node runtime, not Edge**, for every route that touches a password — argon2 is
not available on Edge.

## Data

### Server

One row per share. Deliberately no segments table: a 30-minute transcript is
roughly 50KB of JSON, is always rendered whole, and is never queried by segment.

```sql
CREATE TABLE shares (
  id             text PRIMARY KEY,        -- 10 chars base58 (~4.3e17 space)
  owner_hash     text NOT NULL,           -- sha256(device token)
  includes       jsonb NOT NULL,          -- {transcript,notes,summary}: bool
  payload        jsonb,                   -- NULL once revoked
  password_hash  text,                    -- argon2id; NULL means no password
  revoked_at     timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  view_count     integer NOT NULL DEFAULT 0
);
CREATE INDEX shares_owner ON shares (owner_hash) WHERE revoked_at IS NULL;
```

**Revocation deletes the payload** and keeps the row as a tombstone, so the id
is never reissued and the owner can still see that the share existed. A revoked
id answers `410 Gone`, not `404` — the distinction is what tells a recipient the
link was withdrawn rather than mistyped.

### Local

Migration `v9_meeting_shares`:

```sql
CREATE TABLE meetingShare (
  meetingID      TEXT PRIMARY KEY REFERENCES meeting(id) ON DELETE CASCADE,
  shareID        TEXT NOT NULL UNIQUE,
  includesTranscript INTEGER NOT NULL,
  includesNotes      INTEGER NOT NULL,
  includesSummary    INTEGER NOT NULL,
  hasPassword    INTEGER NOT NULL,
  createdAt      TEXT NOT NULL,
  lastSyncedAt   TEXT,
  lastError      TEXT
);
```

Writing this table must **not** touch `meeting.updatedAt` — the library is
ordered by it, and sharing a meeting is not a reason to move it to the top. The
same rule `MeetingStore.deleteMeetingFolder` already follows.

## Identity without accounts

A 32-byte random token, generated on first share, stored in the data-protection
Keychain through the existing `CredentialStore`, and sent as
`Authorization: Bearer`. The server stores only `sha256(token)`; possession of
the token is the sole proof of ownership, and only the owner may update or
revoke.

`ProviderCredential` is the wrong home for it — it enumerates model-provider API
keys. A sibling `ShareCredential` case set reuses the same keychain machinery
without overloading that meaning.

The token is shown in Settings so it can be saved. This is the only recovery
path: **reinstalling without a Keychain restore permanently orphans existing
links**, which will still render and can no longer be revoked. Stated in the UI,
not buried here.

## Password, and the rate limit that makes it mean anything

`argon2id` server-side. The Mac sets and changes it; the server sees the
plaintext only in the set and verify requests, over TLS.

**Rate limiting is part of this feature, not a follow-up.** A public URL plus an
unthrottled verify endpoint means a six-character password falls in minutes, and
the password is the only thing standing between a link and a readable
transcript. Upstash/Vercel KV sliding window:

- 5 failed attempts per (share, IP) per 15 minutes, then a 15-minute lockout
- 50 failed attempts per share per hour across all IPs
- a uniform response delay whether or not the share exists, so timing does not
  reveal which ids are real

### Indexing and link previews

- `X-Robots-Tag: noindex, nofollow` on every share route, plus a `robots.txt`
  disallowing `/s/`. A transcript arriving in a search index is the failure
  mode people will not forgive.
- **A password-protected share exposes no title in its OpenGraph tags** — it
  unfurls as "A shared Hushnote meeting". Unfurling the real title in a Slack
  channel would leak the thing the password exists to protect. A share without a
  password unfurls its title, because nothing is protected in that case.

## Live sync

`ShareSyncService` mirrors `queueMeetingNotes`: a per-meeting debounced task
that coalesces edits and PUTs the whole payload. Debounce is 2s rather than
notes' 350ms — this is a network round trip, not a local write.

It must observe every source of shared content: transcript corrections, notes,
summary and its versions, and the meeting title. And it must flush on quit
through the same path notes now use — `TerminationDecision.flushPendingNotes`
generalises to `flushPendingWrites`, or the last edit before ⌘Q never leaves.

Failure is shown, never silent: `lastError` surfaces in the share sheet and the
`Shared` list as "Not synced — retry". A failed sync leaves the previous version
published; it never blanks the page.

**Deleting a meeting revokes its share.** Permanent deletion
(`purgeDeletedMeetings`, and the immediate permanent delete) revokes before
removing the local row, and a revoke that fails blocks the purge so the meeting
stays recoverable for a retry — the same ordering
`MeetingStore` already uses for audio files. Moving a meeting to Recently
Deleted warns that its link is still live and offers to revoke.

## The Mac app's surface

- **Share sheet**, from the existing meeting-header share button: three content
  toggles, an optional password, and the disclosure — reusing
  `AskDisclosurePolicy`'s established three-tier vocabulary, since "this leaves
  your Mac" is a sentence this app already knows how to say.
- **After creation**: the link, a copy button, a `LIVE` badge, revoke.
- **A persistent badge in the workspace header of any shared meeting.** Required
  by the live-sync decision.
- **A `Shared` sidebar destination** listing every share with its included
  content, sync state, and revoke — the only place shares can be managed, since
  there is no web dashboard.

## The web app's surface

One route. It renders the same reading spread the Mac app does — apparatus
margin, 704pt measure, chapter index — because a shared transcript that looks
nothing like the app it came from is a different product. Paper/ink palette,
serif reading type, light and dark via `prefers-color-scheme`. No navigation, no
account prompts, no "Made with" badge.

## Deployment and configuration

The Vercel project is the owner's; nothing here creates or logs into one.

| Variable | Purpose |
|---|---|
| `DATABASE_URL` | Neon/Vercel Postgres connection string |
| `KV_REST_API_URL`, `KV_REST_API_TOKEN` | Upstash/Vercel KV, for the rate limiter |
| `SHARE_ORIGIN` | The public origin the Mac app embeds in links |

`SHARE_ORIGIN` is also compiled into the Mac app as the API base, read from a
build setting rather than hardcoded, so a local Postgres and a
`localhost:3000` web app can serve phase 1 before any deployment exists. The
custom domain is set on the Vercel project; changing it later changes only this
one value, and **existing links keep the old origin** — they are absolute URLs
already in other people's hands.

## Error handling

| Case | Behaviour |
|---|---|
| Share id unknown | 404, uniform delay |
| Share revoked | 410 with "This link was withdrawn" |
| Wrong password | 401, attempt counted |
| Rate limited | 429 with the retry time |
| Sync fails | Previous version stays published; app shows "Not synced" |
| Token missing/invalid | 401; app offers to re-pair by generating a new token, orphaning old links, and says so |

## Testing

Pure policies beside their views, per house convention, each with a suite:

- `SharePayloadBuilder` — what the toggles produce, including the empty case
  (no content selected is not a share) and control-token stripping via
  `WhisperSpecialToken`, since shared text is exported text.
- `ShareSyncPolicy` — when a push is owed, coalescing, and what a failure
  retains.
- `ShareLinkPolicy` — id validation, URL construction, the revoked/unknown
  distinction.
- `SharePublishing` protocol so no test performs a network call, the same seam
  as `AgentProcessRunner` and `SpeechModelDownloading`.

Web: route tests for the password gate, revocation, ownership enforcement, and
the rate limiter. The limiter is tested — an untested rate limiter is an absent
one.

## Phases

Each ships independently and is separately reviewable.

1. **`web/` + database + render.** Fed by hand-posted JSON. Proves the stack,
   the schema, and the reading spread in a browser. No password, no Mac changes.
2. **Share from the Mac.** Device token, `v9` migration, share sheet, create and
   revoke, `Shared` sidebar destination.
3. **Password + rate limiting + indexing rules.**
4. **Live sync.** Observation, debounce, quit-flush, the shared badge, and
   delete-revokes-share.

## Non-goals

- Audio. Not now, and the decision to exclude it should be revisited only
  deliberately: voices are biometric and cannot be redacted after the fact.
- Web accounts, dashboards, email, password reset.
- Comments, reactions, or any reader-side write path.
- Analytics beyond `view_count`.
- Editing a shared meeting from the browser.

## Risks accepted

1. **Plaintext at rest.** A breach of the database exposes every shared
   transcript. Chosen knowingly; the mitigation is that only explicitly shared
   meetings are ever uploaded.
2. **Keychain loss orphans links.** No recovery without the token. Surfaced in
   Settings.
3. **Live sync publishes later edits.** Mitigated by per-share content
   selection and the persistent badge, not eliminated.
4. **A forwarded link is a public link** unless a password is set. The app
   should say this once, at creation, without nagging.
