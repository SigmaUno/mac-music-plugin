# Mac Music Plugin

A macOS menu bar music player that streams from four source types — **local
files**, **HTTPS**, **SSH**, and **local‑network** hosts — with a multi‑playlist
library, cover art, metadata import, directory scanning, autoplay / shuffle /
repeat, a play queue, and per‑track editing.

It is the macOS counterpart of the
[Omarchy Leecher plugin](https://github.com/SigmaUno/omarchy-leecher-plugin):
the same feature set and the **same on‑disk library format**, rebuilt as a native
SwiftUI `MenuBarExtra` app with an AVFoundation player. No Homebrew dependencies —
it uses the `ssh` and `curl` that ship with macOS.

## Requirements

- macOS 14 (Sonoma) or newer.
- A Swift toolchain to build (Xcode, or the Command Line Tools — `xcode-select
  --install`).
- For SSH and local‑network sources: key‑based `ssh` access to the host already
  working from Terminal.

## Install

```bash
scripts/install.sh
```

Builds a release binary, assembles `MacMusicPlugin.app`, ad‑hoc signs it,
installs it to `~/Applications`, and launches it. A music‑note icon appears in
the menu bar; click it for the player panel.

Build without installing:

```bash
swift build            # debug binary at .build/debug/MacMusicPlugin
scripts/bundle.sh      # dist/MacMusicPlugin.app (release, ad‑hoc signed)
```

### Permissions macOS will ask for

- **Local Network** — the first time you play a local‑network source. Required
  for streaming from a LAN host; deny it and those sources will not play.
- **Files & Folders** — the first time you add or scan a local file outside your
  home directory.
- **Automation → Terminal** — only if you use **Unlock SSH agent**, which opens
  Terminal to run `ssh-add` for a passphrase‑protected key.

## Using it

- **Playlists** — the tab strip at the top. Click a tab to browse it; the framed
  **+** creates a new one inline. `★ all` is an auto‑collected view of every
  source in every playlist. Playing a track from a tab switches playback to it.
- **Add source** — expand the "Add source" row, pick a kind, fill the fields:
  - *Local* — choose files, or "Scan a folder…".
  - *HTTPS* — an `https://` URL to an audio file. Tags are read from the remote
    file when possible.
  - *SSH / Local network* — user, host/IP, and a remote path. Tick "Scan this
    directory" to stage every audio file under a folder instead.
- **Directory scans** land in a `INCOMING >> <playlist> <<` staging tab (shown in
  orange). Review each row with the ✓ / ✗ hover buttons, or the bulk chips beside
  the filter field. The staging tab disappears once it is empty.
- **Track rows** — click to play. Hover for queue, edit‑tags, and remove.
- **Cover art** — click the artwork in the now‑playing header to search iTunes or
  choose a local JPEG/PNG. Embedded art shows automatically when no cover is set.
- **Open at Login** — toggle in the panel footer.
- Autoplay, shuffle, repeat‑one, volume, mute, and output device persist between
  launches. Playback position is restored on relaunch.

## Library location

Playlists live in `~/Library/Application Support/MacMusicPlugin/library/`, one
`<playlist>.json` file each, in the same schema the Omarchy plugin uses:

```json
{ "version": 1, "tracks": [
  { "title": "…", "artist": "…", "album": "…", "cover": "/path/or/omitted",
    "sources": [
      { "kind": "local|ssh|https|network",
        "PATH": "…", "USERNAME": "…", "URL": "…", "IP": "…" }
    ] } ] }
```

**Migrating from the Omarchy plugin:** copy the contents of that plugin's
`$XDG_DATA_HOME/leecher-media/library/` into the folder above. A single legacy
`library.json` is picked up and migrated to `home.json` on first run.

## How it differs from the Linux plugin

- One SwiftUI process — no headless daemon, no `status.json` / `control` IPC.
- AVFoundation for playback and tag reading (FLAC / Ogg‑Vorbis / Opus containers
  are parsed directly for the tags macOS does not expose); `ssh` + `curl` for
  transport. No `ffmpeg`, `ffprobe`, `mediainfo`, `zenity`, SDL, or libsndfile.
- Uses your existing SSH agent / keychain rather than spawning its own agent.
- Remote track metadata: HTTPS is probed via AVFoundation; SSH sources are staged
  by file name (edit the row to fix tags).
- SSH connections are multiplexed (OpenSSH `ControlMaster`) so back‑to‑back
  tracks from one host skip the handshake; the control sockets live under
  `/tmp/mmp-<uid>/ssh` and are removed on quit.

## Development

- `swift build` — debug build (all targets).
- `swift run MMPTests` — the test suite. It is a plain executable, not XCTest, so
  it runs under the Command Line Tools without full Xcode.
  - `swift run MMPTests --audio <dir>` — real playback integration check.
  - `swift run MMPTests --remote <https-url> [user@host:/path]` — real fetch.
  - `swift run MMPTests --tags <file>…` — dump extracted tags + embedded art.
- `swift scripts/make-icon.swift` — regenerate `Resources/AppIcon.icns`.
- CI (`.github/workflows/ci.yml`) builds, tests, and uploads the `.app` on every
  push.

If `swift` reports *"You have not agreed to the Xcode license agreements"* after
installing full Xcode, run `sudo xcodebuild -license accept` once (or point at
the Command Line Tools: `sudo xcode-select -s /Library/Developer/CommandLineTools`).

## License

[MIT](LICENSE)
