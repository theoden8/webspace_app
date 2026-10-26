# Magnet link support

## Why

A `magnet:` link already reaches the external-scheme prompt (EXT-004), which
offers to hand it to another app, and the prompt already says so when no app
on the device takes it. What it does not do is show what is being opened: the
raw URI a page writes can run to hundreds of characters of trackers. Nor is a
magnet refused as a site URL, or kept from loading when typed into the URL
bar.

The first draft of this change (PR #200, April 2026) specified the handoff as
a new path of its own. That path now exists for every scheme the webview
cannot render, so this rewrite is a delta on `external-scheme-handling`
rather than a second owner of the same job.

## What changes

| Piece | Where it lives | Joins |
|---|---|---|
| What the prompt shows | a pure magnet parser; the prompt's magnet case | name and shortened hash in place of the raw URI (EXT-010) |
| Site URLs | the URL validation shared by Add Site, editing, QR and backup import | external schemes refused, with a reason (EXT-011) |
| The URL bar | its submit path | an external scheme goes to the prompt (EXT-011) |
| Trackers and seeds | nowhere: never fetched | (EXT-012) |

## Out of scope

- Downloading torrents in the app.
- `ed2k:`, `thunder:` and other download schemes: they take the generic
  prompt as they do today.

## Prior work

The April draft's parser and its tests sit at `81cd9c1` on this branch's old
history, and can seed EXT-010's parser.
