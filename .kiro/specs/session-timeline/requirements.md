# Two views of a coding session

A developer may see a live session in the notch and later want to review its sequence of events at the terminal. The Mac app is under apps/Bangs. The second app belongs in apps/SessionTimeline.

- Accept one JSON Lines recording via standard input, with no installation of hooks and no access to private machine history. A short fixture must demonstrate a Kiro session end to end.
- Reuse one small Foundation-only event representation in the GUI's HookEnvelope wire decoder and the CLI. A third application should be able to reuse the template without linking the GUI or BangsCore.
- Preserve older wire envelopes, including the fallback event name in the payload. Decode malformed records and integer extremes without crashing either consumer.
- Print a readable, ordered timeline. Keep prompts and arguments out of the output and escape or suppress terminal controls in printed data. Report malformed input with its line number and return a nonzero status.
- Keep the package buildable on Apple Silicon with macOS 14 or later and the Xcode 26 SDK. Include English usage and regression tests.
