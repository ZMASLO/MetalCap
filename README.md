# MetalCap

<img src="Resources/AppIcon.png" width="128" alt="MetalCap icon">

[Polski](README.pl.md)

Frame time capture for games on macOS - the macOS counterpart of CapFrameX.

## Where the measurements come from

Frame data comes from the Metal Performance HUD, Apple's official performance tool built into macOS. MetalCap does not measure frames itself - it collects what the HUD reports, calculates the metrics and presents them.

## Features

- AVG, P1, 1% Low and 0.1% Low (Average or Integral), named and calculated the same way as in CapFrameX
- Start and stop with a global shortcut, with a sound for each
- Frame time chart and system metrics: GPU load, CPU and GPU temperature, power, clocks, fan, memory
- Hardware, game window and Game Mode saved with every result
- Comments, renaming and sorting of results
- Export to JSON and CSV
- English and Polish

## Requirements

Mac with Apple silicon, macOS 14 or later (tested on macOS 27).

## Installation

Download `MetalCap-<version>.zip` from Releases and move `MetalCap.app` to Applications. The app is not notarized, so open it the first time with right-click - Open.

## Usage

1. Turn on Metal HUD with the switch in MetalCap, then restart the game and its launcher (Steam, CrossOver). Alternatively, start the game with "Launch game..." in MetalCap.
2. For games started from Steam or CrossOver, install the logging profile MetalCap offers at first launch (System Settings - General - Device Management). Without it macOS hides frame times of other apps.
3. In the game, press the shortcut (default Control-Option-R) to start and again to stop. The Metal HUD must stay visible.
4. The result appears in the list. Changes to the overlay settings take effect after the game is restarted.

## Metrics

- AVG - number of frames divided by the total time.
- P1, P5, median and other percentiles - R-8 percentiles of the frame rate, as in CapFrameX.
- 1% Low Average - mean of the slowest 1% of frames.
- 1% Low Integral - the frame at which the slowest frames add up to 1% of the time (as in MSI Afterburner). Which of the two is shown is set in settings.
- CPU power is an estimate from per-cluster power histograms, because macOS does not expose the CPU energy counter.

## Security and limitations

- The logging profile reveals only Metal HUD messages (frame numbers and frame times). It applies to the whole system and stays after MetalCap is deleted; remove it in System Settings - General - Device Management.
- Metal HUD turned on in MetalCap applies to every Metal app launched afterwards, also after MetalCap is closed, until you turn the switch off or log out.
- Hiding the overlay with Shift-F9 makes macOS report wrong frame times. Keep it visible while measuring.
- The app runs without a sandbox, because it reads hardware sensors and the system log, and it is not notarized.
- Power, clocks, temperatures and the HUD log format come from undocumented Apple sources and may stop working after a macOS update. If a source disappears, MetalCap keeps running without that data.

## Building

```sh
swift test             # unit tests
Scripts/e2e.sh         # end-to-end tests, need an unlocked Mac with the display on
Scripts/make-app.sh    # builds build/MetalCap.app
```

## License

MIT - see [LICENSE](LICENSE).
