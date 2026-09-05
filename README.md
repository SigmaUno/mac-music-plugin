# Mac Music Plugin

A macOS menu bar music player that streams from four source types — **local files**,
**HTTPS**, **SSH**, and **local‑network** hosts — with a multi‑playlist library, cover art,
metadata import, directory scanning, autoplay / shuffle / repeat, a play queue, and
per‑track editing.

It is the macOS counterpart of the
[Omarchy Leecher plugin](https://github.com/SigmaUno/omarchy-leecher-plugin): same feature
set and the same on‑disk library format, rebuilt as a native SwiftUI `MenuBarExtra` app
with an AVFoundation player (no Homebrew dependencies).

> Status: under construction. See [`docs`](#milestones) below for what works today.

## Requirements

- macOS 14 (Sonoma) or newer.
- Swift toolchain (Xcode or the Command Line Tools) to build.
- `ssh` (ships with macOS) for SSH and local‑network sources.

## Build & install

```bash
scripts/install.sh
```

This builds a release binary, assembles `MacMusicPlugin.app`, ad‑hoc signs it, installs it
to `~/Applications`, and launches it. A `music.note` icon appears in the menu bar.

To build without installing:

```bash
swift build          # debug binary at .build/debug/MacMusicPlugin
scripts/bundle.sh    # dist/MacMusicPlugin.app
```

On first use of an HTTPS or local‑network source macOS will show a one‑time permission
prompt; allow it for streaming to work.

## Library location

Playlists live in `~/Library/Application Support/MacMusicPlugin/library/`, one
`<playlist>.json` file each, in the same schema the Omarchy plugin uses. To migrate an
existing library, copy that plugin's `library/` directory contents into this folder.

## Milestones

1. **Scaffold** — menu bar app shell, paths, bundling. ← current
2. Library store (JSON playlists, add/edit/remove).
3. Local‑file playback engine.
4. Remote sources (HTTPS, SSH, local network).
5. Metadata + cover art.
6. Full player panel UI.
7. Directory scanning.
8. Polish, Open‑at‑Login, docs.

## License

[MIT](LICENSE)
