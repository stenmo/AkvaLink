# Contributing to AquaLink

Thanks for your interest! AquaLink is a battery-powered, single-SoC Matter
pool/aquatic temperature sensor on the u-blox NORA-W40 (ESP32-C6). It
deliberately does **one thing well**, so contributions are very welcome —
as long as they keep that focus.

## Before you start

- **Open an issue first** for anything non-trivial. A quick "here's what I want
  to do" saves everyone time and avoids PRs that don't fit the project's scope.
- **Read [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)** and [TODO.md](TODO.md) —
  the TODO's *Future ideas* section is the parking lot of things we already
  want; the *Now* section is what's actually in flight.

## Project philosophy (KISS)

AquaLink is intentionally small. When contributing, please:

- **Implement one thing at a time.** No bonus features or drive-by refactors
  bundled into an unrelated change.
- **Prefer the smallest viable diff.** Extend an existing file over adding a
  new one; a Kconfig flag over a new abstraction layer.
- **Respect the battery.** This is a multi-year-battery product. No busy-wait
  `vTaskDelay` loops, no periodic Matter sends, no leaving peripherals powered.
  Measure before optimising — include a before/after number if you claim a
  power win.
- **No cloud.** Connectivity stays local (Matter, or the planned local BLE /
  Wi-Fi paths). PRs adding cloud dependencies won't be merged.

## Building and testing

The firmware builds in **WSL** (Ubuntu-24.04) with ESP-IDF v5.4.1 and
esp-matter release/v1.5. See [GETTING_STARTED.md](GETTING_STARTED.md) for the
full toolchain setup.

```powershell
# Default (Thread, direct-GPIO DS18B20)
.\launch-aqualink-wsl.cmd --rebuild
.\launch-aqualink-wsl.cmd --flash --log

# Wi-Fi variant
.\launch-aqualink-wsl.cmd --wifi --rebuild
```

Please confirm your change **builds cleanly** and, where you can, test it on
real hardware (EVK-NORA-W40 + a DS18B20). Note in the PR what you tested on —
"builds only" is fine to say, it just tells reviewers what still needs a check.

## Code conventions

- Logging via ESP-IDF `ESP_LOGI/W/E(TAG, ...)`, not `printf`.
- Short lowercase tags: `ds2482`, `ds18b20`, `app`, `pm`.
- 4-space indent; `snake_case` for C, `camelCase` for C++ classes.
- Comments explain **why**, not what.
- Windows `.cmd`/`.bat` files must stay **CRLF** (enforced by `.gitattributes`).

## Pull requests

- Keep PRs focused and reasonably small; describe the *why*.
- Reference the issue it addresses.
- Make sure the working tree is clean of build artifacts — `build/`,
  `managed_components/`, and `sdkconfig` are gitignored; don't force them in.

## License

By contributing, you agree that your contributions are licensed under the
project's [Apache-2.0 License](LICENSE).
