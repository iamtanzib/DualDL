# Contributing

Thanks for helping! DualDL is small on purpose: a SwiftUI app, a few dependency-free Python engines and a Chrome extension.

## Setup

```bash
xcode-select --install          # Swift compiler + Python 3
git clone https://github.com/iamtanzib/DualDL.git && cd DualDL
tests/run.sh                    # should end with ALL TESTS PASSED
./build.sh                      # builds and installs DualDL.app
```

Optional for the full suite: ffmpeg (video conversion tests) and the app's video tools (Deno runs the extension tests): **Settings → Video → Install**, or `python3 engine/tools.py --install`.

## Ground rules

- **Run `tests/run.sh` before every pull request**, and add a test for what you change. The suite never touches a real install (see the test hooks in [docs/architecture.md](docs/architecture.md#test-hooks-environment-variables)).
- **Keep the engines dependency-free:** standard library only, Python 3.9 compatible (the macOS system Python).
- **Never break the saved list:** new fields in `DownloadItem` must decode with a default (see its `init(from:)`).
- **Keep it light:** engines run at `.utility` priority; avoid work on every progress tick in the UI.
- **Be careful with data:** cancel deletes only DualDL's own partial files; anything else goes to the Trash.
- Match the surrounding style: short comments that explain *why*, not *what*.

## Where things are

See [docs/architecture.md](docs/architecture.md) for the map and [docs/customizing.md](docs/customizing.md) for the knobs.

## Reporting a bug

Include your macOS version, the kind of link (Drive file/folder, video site, plain URL), what the row said, and, if you can, the output of the matching engine command with `--json` (see [docs/command-line.md](docs/command-line.md)). Remove private links and cookies first.
