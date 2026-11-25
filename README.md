# Bangs

When an agent's terminal goes quiet, is it still working or waiting for you? Bangs shows the answer beside the MacBook notch. Session Timeline answers a different question after the turn ends: which events happened, and in what order?

This is the source for the **Skeleton Crew** entry in Kiroween 2026. The two apps share a small Swift event format. One consumes a live stream from local coding tools. The other reads a recording from standard input. You can try the terminal example with the supplied fixture before connecting any coding tools.

| Application | Input | What to try |
| --- | --- | --- |
| [Bangs](apps/Bangs) | Live events from supported coding tools | See which session is running, inspect a request, and return to its terminal. |
| [Session Timeline](apps/SessionTimeline) | A newline-delimited JSON recording | Replay an example Kiro session in the terminal. |

## Try the two apps

**Session Timeline.** From the repository root, run the following command. The fixture contains invented events. No Kiro account, API key, running agent or installed hook is needed.

```sh
swift run session-timeline < samples/kiro-session.jsonl
```

**Bangs.** Use an Apple Silicon Mac on macOS 14 or later. Download the arm64 ZIP from [Bangs releases](https://github.com/Wale-Shi/Bangs-releases/releases/latest), unzip it and move Bangs.app into Applications. The downloadable app is locally signed. If macOS prompts on first launch, review it in System Settings under Privacy & Security.

1. Open the app, then click the notch or menu-bar icon. Option–Command–B also opens the panel.
2. To try the panel with no accounts or hooks, select Focus (专注), start a timer and collapse the panel. The countdown stays visible. Stop it after the test.
3. To follow a coding session, open Settings (设置), select Agent and install the hook for a CLI already on your Mac. Start a fresh session and ask the agent to inspect a sample folder. Moving bars indicate activity. A green check marks completion.
4. Click a session to return to its terminal. Kiro handles permission decisions in the terminal. For integrations that support a decision in the notch, the buttons are Deny (拒绝), Handle in terminal (在终端处理), and Allow (允许).

## What the template provides

[SessionEvents](Sources/SessionEvents/SessionEvent.swift) is a single Foundation-only Swift module. A hook record contains the agent's name, its native event name, a process ID and a payload. Older records can carry the event name inside the payload. A client decides how to present the result. Bangs maps it to live session state, while Session Timeline displays each event in input order.

To build a third app, add an executable target that depends on `SessionEvents` and call `SessionEvent.parse(line:)` for one UTF-8 JSON record. The result contains either a decoded event or a typed parse error. The two apps have separate entry points and share the parser directly.

The included fixture produces the following output.

```text
  1  line 1  kiro  SessionStart  session=demo-1  pid=4242
  2  line 2  kiro  UserPromptSubmit  session=demo-1  pid=4242
  3  line 3  kiro  PreToolUse  session=demo-1  tool=fs_read  pid=4242
  4  line 4  kiro  PostToolUse  session=demo-1  tool=fs_read  pid=4242
  5  line 5  kiro  Stop  session=demo-1  pid=4242
  6  line 6  kiro  SessionEnd  session=demo-1  pid=4242
```

## How Kiro contributed

The [requirements](.kiro/specs/session-timeline/requirements.md) gave Kiro IDE a specific compatibility constraint. Existing Bangs hook messages had to keep working after moving decoding into a reusable module. The [steering file](.kiro/steering/product.md) limited the terminal output to event metadata so sample prompts and command arguments would stay out of the display.

In a local Kiro IDE session, Kiro extracted the Swift parser, connected both consumers to it, implemented the terminal app, and wrote tests for older messages, invalid process IDs, malformed input and terminal control characters. Separately, the macOS app supports Kiro CLI as an event source. Kiro IDE was the development tool for this increment, and Kiro CLI is one of the integrations the resulting app can monitor.

## Build from source

Use Apple Silicon, Xcode 26 or later with the macOS SDK, and Swift Package Manager. The app deployment target is macOS 14. Run the following from the repository root.

```sh
swift build
swift test
./scripts/build-app.sh
```

The packaging script writes the app and a ZIP into `build/`. It uses ad-hoc signing when the developer's local signing identity is unavailable. No signing certificate is included in the repository.

## Source and acknowledgments

The first Bangs source commit dates to November 3, 2026, during the submission period. This repository contains the contest source snapshot based on version 0.12.1. The original app is implemented in Swift, AppKit and SwiftUI. The release ZIP cited above contains the macOS app. Build the terminal app from this repository.

The notch shape and click-through design drew on [vibe-notch](https://github.com/farouqaldori/vibe-notch). Third-party CLI marks identify integrations. Their origins and modifications are listed in the [logo notices](apps/Bangs/Logos/README.md), with upstream notices under [licenses](licenses). The project's own code is available under the [MIT License](LICENSE).

The original 16-second [notch demonstration](https://www.youtube.com/watch?v=I5QT7gjqurk&cc_load_policy=1&cc_lang_pref=en) has a published English caption track. Its [timed transcript](media/bangs-demo.en.srt) is also included.
