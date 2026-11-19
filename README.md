# Switchboard

Switchboard is a macOS terminal for people who run many AI coding sessions at the same time
(Claude Code, Codex, Grok). It is a fork of [Ghostty](https://github.com/ghostty-org/ghostty).

## What it adds to Ghostty

- **One window for every session.** Each session is its own group of tabs. A sidebar lists all
  sessions with an icon and a word for the state (needs you, working, done), the login, the folder,
  and the next step the agent wants from you.
- **Finds sessions that run elsewhere.** A Claude Code session that runs in another terminal shows
  in the sidebar, and one click moves it into Switchboard.
- **Park, Done and Archive.** Close a session and reopen it later with its conversation.
- **Several Claude logins.** Each session shows which login it uses and that login's plan usage.
- **A panel above each session.** What the session works on and what is still open in it (a
  model reads the conversation when the agent stops), and the pages it gave you by title: dev
  pages, Simplero Docs and claude.ai artifacts, with the login that published each artifact.
- **Updates keep programs running.** For an update, the app hands every terminal to a small holder
  process (`macos/switchboard-holder.c`), and the new app takes them back.
- **iPhone link.** A WebSocket on port 4480 lets a phone read and drive the sessions. It accepts
  only Tailscale devices of the Mac's own Tailscale login, and it checks a Simplero sign-in. The
  iPhone app is not in this repository.
- **Link Router** (`link-router/`): a small app that opens each link in the right browser profile
  (dev pages in Chrome, artifacts and Docs in the matching Arc Space). Links clicked in Switchboard
  go through it when it is installed, also when it is not the default browser.

The code for these is mostly in `macos/Sources/Features/Sessions/`.

## Status

Switchboard is built for one person's setup. Some things are fixed in the code, for example the
three Claude login folders (`~/.claude`, `~/.claude-ccl`, `~/.claude-ccm`). Expect rough edges.

## Build and install

You need macOS, Xcode and Zig 0.17.1.

```sh
zig build -Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast
cd macos
env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
  xcodebuild -project Ghostty.xcodeproj -scheme Ghostty -configuration ReleaseLocal \
  SYMROOT=$PWD/build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
cd ..
./install-sessions-app.sh
```

This installs `/Applications/Switchboard.app` next to a normal Ghostty. The build number is the
number of commits that upstream Ghostty does not have, so add Ghostty as the `upstream` remote:

```sh
git remote add upstream https://github.com/ghostty-org/ghostty.git
git fetch upstream
```

## Ghostty

Everything else is Ghostty. See [Ghostty's README](https://github.com/ghostty-org/ghostty#readme)
and [documentation](https://ghostty.org/docs).

## License

MIT, the same as Ghostty. See [LICENSE](LICENSE).
