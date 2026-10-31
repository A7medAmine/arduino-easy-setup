# Arduino Easy Setup

One tool that installs everything a beginner needs to start with Arduino, then checks the
board connection and fixes the common problems automatically.

## Quick start (one line)

**Windows** — press `Win + X`, open **Terminal** or **PowerShell**, paste:

```powershell
irm https://raw.githubusercontent.com/A7medAmine/arduino-easy-setup/main/install.ps1 | iex
```

**macOS / Linux** — open **Terminal**, paste:

```bash
curl -fsSL https://raw.githubusercontent.com/A7medAmine/arduino-easy-setup/main/setup-mac-linux.sh | bash
```

This always runs the latest version from GitHub. No download, no unzip.

## Run from a downloaded copy

**Windows** — double-click `setup-windows.bat`.
Windows may show "Windows protected your PC": click *More info* → *Run anyway*.
It asks for administrator permission only when installing drivers or enabling long paths.

**macOS / Linux** — open a terminal in this folder and run:

```bash
bash setup-mac-linux.sh
```

It asks for your password only for system fixes (Linux serial permissions, udev rules).

Then pick **1) Full setup**. When it finishes, it offers to test your board.

## Menu

| Option | What it does |
|---|---|
| 1. Full setup | Installs Arduino IDE 2, board packages (Uno/Nano/Mega, optional ESP32/ESP8266), drivers, beginner libraries, and applies all fixes |
| 2. Test my board | Asks you to unplug/replug the board, detects the USB chip, fixes the driver, checks the connection is stable, uploads a Blink test, and checks Serial |
| 3. Diagnose and fix | Checks every item below and fixes what is wrong |
| 4. Install beginner libraries | Pick from Servo, DHT, LCD I2C, OLED, NeoPixel, ultrasonic, IR, keypad, RFID, DS18B20, RTC - or all of them |
| 5. Explain an error message | Reads the error you copied in the IDE and explains it in plain English, and offers to install a missing library |
| 6. Board hardware check | Guided test for boards that will not upload: power LED, bootloader blink, RX/TX loopback test of the USB chip, and how to burn a new bootloader |
| 7. Repair board manager | Clears broken downloads and the board index cache, reinstalls Arduino AVR boards |
| 8. Reinstall USB drivers (Windows) | Installs CH340 and CP210x drivers again |

### Error explainer

In the Arduino IDE click **Copy error messages**, then choose option 5. It recognizes:
missing `;`, `}` or `)`, unknown names (with spelling/capital-letter hints), missing libraries
(and installs them), WiFi code on a board without WiFi, `Serial1` on a Uno, smart quotes copied
from websites, duplicate `setup()`, sketch too big, low RAM, upload `not in sync`, busy port,
ESP32 boot mode, and more. Upload failures in "Test my board" are explained automatically.

### Board hardware check

Finds out *why* a board will not upload:

| Result | Meaning |
|---|---|
| Power LED off | No power: cable, USB port, or damaged board |
| Board disconnects by itself | Short circuit in the wiring, or servos/motors drawing too much power |
| RX/TX loopback fails | The USB-to-serial chip or the cable is bad |
| Loopback works, no bootloader blink | Bootloader missing: shows how to burn it with a second Arduino |
| Everything works | Wrong board/processor selected, or something on pins 0/1 |
| Counterfeit FTDI chip (PID 0000) | Explains how to restore it (Linux: re-enables it automatically) |

Non-interactive: `setup-windows.bat -Auto -Esp32 -Esp8266` or `bash setup-mac-linux.sh --auto --esp32 --esp8266`.

## Problems it detects and fixes

| Problem | Fix |
|---|---|
| Clone board (CH340) or ESP board (CP210x) has no COM port on Windows | Downloads and installs the official WCH / Silicon Labs driver |
| Board not detected at all | Plug-in detection; tells you to try a data cable (charge-only cables are the #1 cause) |
| Nano clone upload fails with `not in sync` | Retries with the **ATmega328P (Old Bootloader)** setting |
| ESP32 upload fails with `Failed to connect` | Guides you to hold the BOOT button and retries |
| Port busy / `Access is denied` | Tells you to close Serial Monitor or other serial programs |
| User name or Documents path has emoji, accents, apostrophes, or OneDrive | Moves the Arduino data and sketch folders to a safe path (ESP toolchains break otherwise) |
| ESP32 build fails with "file name too long" (Windows) | Enables Windows long paths |
| Board manager stuck or "Error downloading index" | Clears `staging` and index caches, re-downloads |
| Linux: `Permission denied` on `/dev/ttyUSB0` | Adds you to `dialout`/`uucp`, installs udev rules so it works without logging out |
| Linux: CH340 port appears then disappears (Ubuntu) | Removes `brltty`, which grabs CH340 chips |
| Linux: ModemManager interferes with uploads | udev rule tells ModemManager to ignore Arduino boards |
| Linux: IDE does not start ("SUID sandbox helper") | Fixes `chrome-sandbox` permissions (or adds `--no-sandbox`) |
| Linux: AppImage needs FUSE | Installs the `.zip` build of the IDE instead, with a menu entry |
| macOS: "App is damaged / can't be opened" | Removes the quarantine flag |
| macOS 10.x: clone boards not detected | Opens the CH340 driver download page |

## Where things go

| | Windows | macOS | Linux |
|---|---|---|---|
| Tool files and logs | `%LOCALAPPDATA%\ArduinoEasySetup` | `~/.local/share/arduino-easy-setup` | `~/.local/share/arduino-easy-setup` |
| Arduino IDE | `%LOCALAPPDATA%\Programs\Arduino IDE` | `/Applications/Arduino IDE.app` | `~/.local/share/arduino-ide` |
| Board packages | `%LOCALAPPDATA%\Arduino15` | `~/Library/Arduino15` | `~/.arduino15` |

The tool uses its own copy of `arduino-cli` and writes the same board manager URLs and folders
into the IDE's config (`~/.arduinoIDE/arduino-cli.yaml`), so the IDE sees everything it installed.

Every run writes a log file to the `logs` folder. Send it along when asking for help.
