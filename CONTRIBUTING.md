# Contributing to CodexIsland oc

Thanks for taking a look. This fork is intentionally small: it keeps the
original CodexIsland native macOS foundation, but focuses the visible product
on Codex only.

## Reporting Bugs

Open an issue and include:

- macOS version from `sw_vers`.
- Whether the Mac has a physical notch and how many displays are connected.
- A screenshot if the island, expanded panel, or settings layout looks wrong.
- Output of `defaults read com.weiweidounai0131.CodexIslandOC` for settings-related
  bugs, with anything sensitive removed.
- Whether Codex data is populated or the panel reports `no codex auth`.

## Building Locally

```sh
./build.sh
open "build/CodexIsland oc.app"
```

Smoke test:

```sh
./scripts/verify.sh
```

There is no Xcode project and no SwiftPM package. The app is compiled directly
with `swiftc` over `Sources/**/*.swift`.

## Code Style

- Keep commits small and focused.
- Use direct commit messages such as `fix: align compact notch content`.
- Each code change should pass `./scripts/verify.sh`.
- Match the existing Swift style and keep comments for non-obvious constraints.

## Code Of Conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
