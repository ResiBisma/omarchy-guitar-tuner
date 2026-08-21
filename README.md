# Omarchy Guitar Tuner

A live guitar tuner that lives in your [Omarchy](https://github.com/omarchy/omarchy) bar.
It listens to your microphone, detects the played string with high accuracy, and shows
how many cents you are off — green when in tune, yellow when close, red when far.

## Features

- Accurate pitch detection via the **YIN** algorithm (verified to ~1 cent on a
  reference-tuned instrument) — robust to guitar harmonics, attack and decay.
- Native 48 kHz capture (no resampling drift) for exact pitch.
- Per-string reference list, nearest-string matching, and a live cents needle.
- Six tunings: standard, drop-D, drop-C, half-step (Eb), open-G.
- Adjustable concert pitch (A4) and capo fret.
- Optional auto-listen on panel open and auto-stop after silence.

## Requirements

- Linux with PulseAudio (`parec`) — the mic is read via `parec`.
- `python3` with `numpy`.
- The **Material Symbols Outlined** font (used for the bar icon). Install it from
  your distribution or <https://fonts.google.com/icons>.

## Installation

Copy the plugin into your Omarchy user plugins directory:

```sh
mkdir -p ~/.config/omarchy/plugins/icung.guitar-tuner
cp manifest.json Widget.qml tuner.py ~/.config/omarchy/plugins/icung.guitar-tuner/
omarchy restart shell
```

The plugin id must remain `icung.guitar-tuner` (set in `manifest.json`).

## Usage

- **Left-click** the bar icon to start listening, pluck a string, and watch the
  color and needle.
- **Right-click** the icon for settings (tuning, reference pitch, capo, sensitivity,
  auto-listen/auto-stop, display mode).

## Notes

- Tuning, capo and reference-pitch changes take effect the next time listening
  starts (reopen the panel or toggle listening off/on).
- `displayMode: icon-text` also shows the note name and cents in the bar.

## License

MIT — see [LICENSE](./LICENSE).
