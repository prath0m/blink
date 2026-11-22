# blink

**Flash any message in Morse code on your MacBook's keyboard backlight.**

```console
$ blink "HELLO WORLD"
Blinking "HELLO WORLD" on the keyboard backlight at 8 WPM (16.6 s per pass)

  H  ....
  E  .
  L  .-..
  L  .-..
  O  ---
     /
  W  .--
  O  ---
  R  .-.
  L  .-..
  D  -..

Done.
```

The whole keyboard lights up: a short flash is a dot and a long flash is a dash.
Each letter appears in the terminal as it is sent, so you can follow along.

## Features

- **Any message**: letters, digits and common punctuation (`. , ? ' ! / ( ) & : ; = + - _ " $ @`)
- **Standard Morse timing** with adjustable speed and brightness
- **Loop mode** to repeat the message until you stop it
- **Leaves your Mac as it found it**: brightness, auto-brightness and idle dimming are restored when it finishes or when you press Ctrl+C
- **Dry-run mode** to preview the code without touching the light
- **One small file** with no dependencies beyond the Xcode Command Line Tools

## Requirements

- A Mac with a backlit keyboard (MacBook Air or MacBook Pro)
- Xcode Command Line Tools: `xcode-select --install`

Tested on macOS 27.2 with an M4 MacBook Air. Other recent macOS versions should
work too. If the backlight API isn't available, blink prints an error and exits.

## Install

Clone this repository, then:

```sh
cd blink
make                  # builds ./blink
sudo make install     # optional: copies it to /usr/local/bin
```

To install somewhere without `sudo`, set a prefix, for example
`make install PREFIX=~/.local`. `make uninstall` removes it again.

## Usage

```text
blink [options] "your message"
echo "your message" | blink [options]
```

| Option | Default | Description |
| --- | --- | --- |
| `-w`, `--wpm N` | `8` | Speed in words per minute (1–60) |
| `-b`, `--brightness N` | `100` | Brightness of each flash, in percent (1–100) |
| `-r`, `--repeat N` | `1` | Play the message N times; `0` repeats until Ctrl+C |
| `-n`, `--dry-run` | | Print the Morse code without flashing the backlight |
| `-V`, `--version` | | Print the version |
| `-h`, `--help` | | Show help |

### Examples

```sh
blink "HELLO WORLD"
blink -w 5 "SOS"              # slower, easier to read by eye
blink -r 0 -b 50 "CQ CQ"      # half brightness, repeat until Ctrl+C
date +%H:%M | blink           # flash the current time
blink -n "Hi there"           # preview only
```

The flashes are much easier to see in a dim room.

## How it works

### Morse timing

blink uses the standard "PARIS" timing, where one unit is 1200 ms ÷ WPM
(150 ms at the default 8 WPM):

| Element | Length |
| --- | --- |
| Dot | 1 unit on |
| Dash | 3 units on |
| Gap between the dots and dashes of a letter | 1 unit off |
| Gap between letters | 3 units off |
| Gap between words | 7 units off |

### Controlling the backlight

macOS has no public API for the keyboard backlight. blink loads Apple's private
CoreBrightness framework at runtime and uses its `KeyboardBrightnessClient` class.
For every backlit keyboard it finds, blink:

1. records the current brightness, auto-brightness and idle-dimming settings
2. turns off auto-brightness and pauses idle dimming, so the light sensor and the
   inactivity timer don't interfere with the message
3. switches the backlight between your chosen brightness and off, with no fade
4. restores everything it changed when the message ends or you press Ctrl+C

## Limitations

- **The whole keyboard lights at once.** A MacBook keyboard has one backlight for
  all its keys, so a single key can't be lit on its own.
- **It relies on a private API.** Apple doesn't document CoreBrightness and can
  change it in any macOS update. If that happens, blink exits with an error
  instead of crashing.

## Troubleshooting

**`error: no keyboard with a backlight was found`**
macOS isn't reporting a backlit keyboard. This happens on desktop Macs and with
external keyboards that have no backlight.

**Nothing seems to light up**
Try a darker room, a higher `--brightness`, or a slower `--wpm`. Make sure the
lid is open and the display is awake.

**My backlight settings changed after blink was force-quit**
blink restores your settings on normal exit, Ctrl+C and `kill`, but nothing can
clean up after `kill -9`. Open **System Settings > Keyboard** and turn
**Adjust keyboard brightness in low light** back on, then set the brightness and
the **Turn keyboard backlight off after inactivity** option the way you like.

## Development

```sh
make          # build
make test     # run the test suite
make clean    # remove the binary
```

The tests only use `--dry-run` and invalid arguments, so they never touch the
backlight and run on machines without one. GitHub Actions builds with
`-Werror` and runs the tests on macOS for every push and pull request.

## License

[MIT](LICENSE) © 2026 Prathamesh Kale
