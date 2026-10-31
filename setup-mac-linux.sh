#!/usr/bin/env bash
# Arduino Easy Setup - macOS and Linux
# Installs Arduino IDE 2 + board packages, fixes serial port permissions and the common
# beginner problems (brltty stealing CH340 boards, ModemManager, sandbox errors, clone Nanos...).
# Works with the bash 3.2 that ships with macOS: no associative arrays, no mapfile.
#
# Usage:  curl -fsSL https://raw.githubusercontent.com/A7medAmine/arduino-easy-setup/main/setup-mac-linux.sh | bash
#         bash setup-mac-linux.sh            (menu)
#         bash setup-mac-linux.sh --auto     (full setup, AVR boards only)
#         bash setup-mac-linux.sh --auto --esp32 --esp8266

set -u

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
TOOL_DIR="$HOME/.local/share/arduino-easy-setup"
CLI_DIR="$TOOL_DIR/cli"
CLI="$CLI_DIR/arduino-cli"
CLI_CONFIG="$TOOL_DIR/arduino-cli.yaml"
IDE_CONFIG="$HOME/.arduinoIDE/arduino-cli.yaml"
DOWNLOAD_DIR="$TOOL_DIR/downloads"
LOG_DIR="$TOOL_DIR/logs"
LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"

ESP32_URL="https://espressif.github.io/arduino-esp32/package_esp32_index.json"
ESP8266_URL="https://arduino.esp8266.com/stable/package_esp8266com_index.json"
UDEV_RULES="/etc/udev/rules.d/99-arduino-easy-setup.rules"

AUTO=0
WANT_ESP32=0
WANT_ESP8266=0
for arg in "$@"; do
    case "$arg" in
        --auto) AUTO=1 ;;
        --esp32) WANT_ESP32=1 ;;
        --esp8266) WANT_ESP8266=1 ;;
    esac
done

if [ "$OS" = "Darwin" ]; then
    IDE_APP="/Applications/Arduino IDE.app"
    DEFAULT_DATA_DIR="$HOME/Library/Arduino15"
    DEFAULT_USER_DIR="$HOME/Documents/Arduino"
else
    IDE_DIR="$HOME/.local/share/arduino-ide"
    IDE_BIN="$IDE_DIR/arduino-ide"
    DEFAULT_DATA_DIR="$HOME/.arduino15"
    DEFAULT_USER_DIR="$HOME/Arduino"
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
    C_GRAY=$'\033[90m'; C_RESET=$'\033[0m'
else
    C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_GRAY=''; C_RESET=''
fi

title() { printf '\n%s=== %s ===%s\n' "$C_CYAN" "$1" "$C_RESET"; }
step()  { printf '  > %s\n' "$1"; }
ok()    { printf '  %s[OK]   %s%s\n' "$C_GREEN" "$1" "$C_RESET"; }
warn()  { printf '  %s[WARN] %s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }
bad()   { printf '  %s[FAIL] %s%s\n' "$C_RED" "$1" "$C_RESET"; }
tip()   { printf '  %s       %s%s\n' "$C_GRAY" "$1" "$C_RESET"; }

# ask_yes_no "question" [default y|n]
ask_yes_no() {
    local default="${2:-y}" hint answer
    if [ "$AUTO" = 1 ]; then [ "$default" = y ]; return; fi
    if [ "$default" = y ]; then hint='[Y/n]'; else hint='[y/N]'; fi
    while true; do
        printf '  ? %s %s ' "$1" "$hint"
        read -r answer </dev/tty || answer=''
        answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
        case "$answer" in
            '') [ "$default" = y ]; return ;;
            y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
    done
}

wait_enter() {
    [ "$AUTO" = 1 ] && return
    printf '  %s (press Enter) ' "$1"
    read -r _ </dev/tty || true
}

need_sudo() {
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}

# ---------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------
# Latest release tag from the GitHub redirect (no API rate limit, no JSON parsing).
latest_tag() {
    curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed 's#.*/tag/##'
}

download() {
    mkdir -p "$(dirname "$2")"
    curl -fL --retry 3 --progress-bar -o "$2" "$1"
}

# ---------------------------------------------------------------------------
# arduino-cli + configuration
# ---------------------------------------------------------------------------
cli() { "$CLI" --config-file "$CLI_CONFIG" "$@"; }

# Runs arduino-cli, shows the output, saves it to $CLI_OUT, returns its exit code.
CLI_OUT="$TOOL_DIR/last-cli-output.txt"
cli_run() {
    "$CLI" --config-file "$CLI_CONFIG" "$@" 2>&1 | tee "$CLI_OUT" | sed 's/^/    /'
    return "${PIPESTATUS[0]}"
}

install_cli() {
    title "Arduino command-line tools"
    if [ -x "$CLI" ] && "$CLI" version >/dev/null 2>&1; then
        ok "arduino-cli already installed ($("$CLI" version))"
        return 0
    fi
    local tag version platform
    tag="$(latest_tag arduino/arduino-cli)"
    version="${tag#v}"
    case "$OS-$ARCH" in
        Darwin-arm64) platform=macOS_ARM64 ;;
        Darwin-*) platform=macOS_64bit ;;
        Linux-x86_64) platform=Linux_64bit ;;
        Linux-aarch64|Linux-arm64) platform=Linux_ARM64 ;;
        Linux-armv7l) platform=Linux_ARMv7 ;;
        Linux-armv6l) platform=Linux_ARMv6 ;;
        Linux-i?86) platform=Linux_32bit ;;
        *) bad "Unsupported system: $OS $ARCH"; return 1 ;;
    esac
    step "Downloading arduino-cli $version..."
    local archive="$DOWNLOAD_DIR/arduino-cli_${version}_${platform}.tar.gz"
    download "https://github.com/arduino/arduino-cli/releases/download/${tag}/arduino-cli_${version}_${platform}.tar.gz" "$archive" || {
        bad "Download failed (check your internet connection)"; return 1; }
    mkdir -p "$CLI_DIR"
    tar -xzf "$archive" -C "$CLI_DIR" arduino-cli
    chmod +x "$CLI"
    ok "arduino-cli installed"
}

current_dir() {   # current_dir data|user
    local value
    value="$(cli config get "directories.$1" 2>/dev/null)"
    if [ -z "$value" ]; then
        if [ "$1" = data ]; then value="$DEFAULT_DATA_DIR"; else value="$DEFAULT_USER_DIR"; fi
    fi
    printf '%s' "$value"
}

# Accents, emoji and quotes in paths break parts of the ESP toolchains.
path_is_safe() {
    case "$1" in *"'"*|*'"'*) return 1 ;; esac
    printf '%s' "$1" | LC_ALL=C grep -q '[^ -~]' && return 1
    return 0
}

init_config() {   # init_config [extra urls...]
    title "Board manager configuration"
    mkdir -p "$TOOL_DIR"
    [ -f "$CLI_CONFIG" ] || "$CLI" config init --dest-file "$CLI_CONFIG" >/dev/null 2>&1
    local url
    for url in "$@"; do
        cli config add board_manager.additional_urls "$url" >/dev/null 2>&1
    done

    local data user
    data="$(current_dir data)"; user="$(current_dir user)"
    if path_is_safe "$data" && path_is_safe "$user"; then
        ok "Arduino folders look fine ($data)"
    else
        warn "Your Arduino folders are in a path with special characters that breaks some compilers:"
        tip "data:      $data"
        tip "sketches:  $user"
        local safe_base="/Users/Shared/ArduinoEasySetup"
        [ "$OS" = Darwin ] || safe_base="/opt/arduino-easy-setup-$(id -u)"
        if ask_yes_no "Use $safe_base instead? (recommended)" y; then
            if [ "$OS" = Linux ] && [ ! -d "$safe_base" ]; then
                need_sudo mkdir -p "$safe_base" && need_sudo chown "$(id -u):$(id -g)" "$safe_base"
            fi
            mkdir -p "$safe_base/data" "$safe_base/sketches"
            cli config set directories.data "$safe_base/data" >/dev/null
            cli config set directories.user "$safe_base/sketches" >/dev/null
            ok "Arduino folders moved to $safe_base"
        fi
    fi
    sync_ide_config
}

# The IDE keeps its own copy of the arduino-cli config; make it use the same URLs and folders.
sync_ide_config() {
    mkdir -p "$(dirname "$IDE_CONFIG")"
    [ -f "$IDE_CONFIG" ] || "$CLI" config init --dest-file "$IDE_CONFIG" >/dev/null 2>&1
    local url key value
    cli config get board_manager.additional_urls 2>/dev/null | sed -n 's/^- //p' | while read -r url; do
        [ -n "$url" ] && "$CLI" --config-file "$IDE_CONFIG" config add board_manager.additional_urls "$url" >/dev/null 2>&1
    done
    for key in data user; do
        value="$(cli config get "directories.$key" 2>/dev/null)"
        [ -n "$value" ] && "$CLI" --config-file "$IDE_CONFIG" config set "directories.$key" "$value" >/dev/null 2>&1
    done
    ok "Arduino IDE uses the same board manager settings"
}

# ---------------------------------------------------------------------------
# Arduino IDE
# ---------------------------------------------------------------------------
ide_installed() {
    if [ "$OS" = Darwin ]; then
        [ -d "$IDE_APP" ] || [ -d "$HOME/Applications/Arduino IDE.app" ]
    else
        [ -x "$IDE_BIN" ] || command -v arduino-ide >/dev/null 2>&1
    fi
}

install_ide_mac() {
    local tag platform zip
    tag="$(latest_tag arduino/arduino-ide)"
    if [ "$ARCH" = arm64 ]; then platform=macOS_arm64; else platform=macOS_64bit; fi
    zip="$DOWNLOAD_DIR/arduino-ide_${tag}_${platform}.zip"
    step "Downloading Arduino IDE $tag (about 200 MB, please wait)..."
    download "https://github.com/arduino/arduino-ide/releases/download/${tag}/arduino-ide_${tag}_${platform}.zip" "$zip" || {
        bad "Download failed"; return 1; }
    step "Installing to /Applications..."
    rm -rf "$DOWNLOAD_DIR/ide-unpacked" && mkdir -p "$DOWNLOAD_DIR/ide-unpacked"
    ditto -x -k "$zip" "$DOWNLOAD_DIR/ide-unpacked"
    local target="/Applications"
    [ -w "$target" ] || target="$HOME/Applications"
    mkdir -p "$target"
    rm -rf "$target/Arduino IDE.app"
    mv "$DOWNLOAD_DIR/ide-unpacked/Arduino IDE.app" "$target/"
    # Remove the "downloaded from the internet" flag so Gatekeeper does not block the first launch
    xattr -dr com.apple.quarantine "$target/Arduino IDE.app" 2>/dev/null || true
    ok "Arduino IDE installed in $target"
}

install_ide_linux() {
    local tag zip
    tag="$(latest_tag arduino/arduino-ide)"
    if [ "$ARCH" != x86_64 ]; then
        bad "Arduino IDE 2 is only published for 64-bit Intel/AMD Linux (you have $ARCH)."
        tip "arduino-cli (installed by this tool) works on your system from the terminal."
        return 1
    fi
    # The .zip build avoids the AppImage/FUSE problems on Ubuntu 22.04+
    zip="$DOWNLOAD_DIR/arduino-ide_${tag}_Linux_64bit.zip"
    step "Downloading Arduino IDE $tag (about 200 MB, please wait)..."
    download "https://github.com/arduino/arduino-ide/releases/download/${tag}/arduino-ide_${tag}_Linux_64bit.zip" "$zip" || {
        bad "Download failed"; return 1; }
    step "Installing to $IDE_DIR..."
    rm -rf "$DOWNLOAD_DIR/ide-unpacked" "$IDE_DIR" && mkdir -p "$DOWNLOAD_DIR/ide-unpacked"
    unzip -q "$zip" -d "$DOWNLOAD_DIR/ide-unpacked"
    mv "$DOWNLOAD_DIR/ide-unpacked"/arduino-ide_* "$IDE_DIR"

    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
    ln -sf "$IDE_BIN" "$HOME/.local/bin/arduino-ide"
    local icon="$IDE_DIR/resources/app/resources/icons/512x512.png"
    [ -f "$icon" ] || icon="$(find "$IDE_DIR" -name '*.png' -path '*icons*' 2>/dev/null | head -n 1)"
    cat > "$HOME/.local/share/applications/arduino-ide.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Arduino IDE
Exec="$IDE_BIN" %U
Icon=$icon
Terminal=false
Categories=Development;Electronics;
EOF
    fix_chrome_sandbox
    ok "Arduino IDE installed (find it in your app menu, or run: arduino-ide)"
}

# Electron needs chrome-sandbox owned by root with the setuid bit, otherwise the IDE
# refuses to start ("The SUID sandbox helper binary was found, but is not configured correctly").
fix_chrome_sandbox() {
    local sandbox="$IDE_DIR/chrome-sandbox"
    [ -f "$sandbox" ] || return 0
    if [ "$(stat -c '%u %a' "$sandbox" 2>/dev/null)" = "0 4755" ]; then return 0; fi
    step "Fixing the IDE sandbox permissions (needs your password)..."
    if need_sudo chown root:root "$sandbox" && need_sudo chmod 4755 "$sandbox"; then
        ok "IDE sandbox fixed"
    else
        warn "Could not fix the sandbox; adding --no-sandbox to the launcher instead"
        sed -i 's#^Exec=.*#Exec="'"$IDE_BIN"'" --no-sandbox %U#' "$HOME/.local/share/applications/arduino-ide.desktop"
    fi
}

install_ide() {
    title "Arduino IDE 2"
    if ide_installed; then ok "Arduino IDE already installed"; return 0; fi
    if [ "$OS" = Darwin ]; then install_ide_mac; else install_ide_linux; fi
}

# ---------------------------------------------------------------------------
# Linux system packages and serial port permissions
# ---------------------------------------------------------------------------
pkg_install() {
    if command -v apt-get >/dev/null 2>&1; then need_sudo apt-get install -y "$@"
    elif command -v dnf >/dev/null 2>&1; then need_sudo dnf install -y "$@"
    elif command -v pacman >/dev/null 2>&1; then need_sudo pacman -S --noconfirm --needed "$@"
    elif command -v zypper >/dev/null 2>&1; then need_sudo zypper install -y "$@"
    else return 1
    fi
}

install_linux_deps() {
    title "System packages"
    local missing=""
    command -v curl >/dev/null 2>&1 || missing="$missing curl"
    command -v unzip >/dev/null 2>&1 || missing="$missing unzip"
    command -v python3 >/dev/null 2>&1 || missing="$missing python3"   # needed by the ESP8266 tools
    if [ -z "$missing" ]; then ok "Required packages present"; return 0; fi
    step "Installing:$missing"
    # shellcheck disable=SC2086
    pkg_install $missing && ok "Packages installed" || warn "Install these yourself:$missing"
}

serial_group() {
    if getent group dialout >/dev/null 2>&1; then echo dialout
    elif getent group uucp >/dev/null 2>&1; then echo uucp     # Arch, Manjaro
    else echo ""
    fi
}

fix_serial_permissions() {
    title "Serial port permissions"
    local group
    group="$(serial_group)"
    if [ -n "$group" ]; then
        if id -nG "$USER" | tr ' ' '\n' | grep -qx "$group"; then
            ok "You are in the '$group' group"
        else
            step "Adding you to the '$group' group (needs your password)..."
            need_sudo usermod -aG "$group" "$USER" && ok "Added to '$group' (fully active after you log out and back in)"
        fi
    fi

    # udev rule: makes boards usable immediately (no logout) and tells ModemManager to leave them alone
    if [ -f "$UDEV_RULES" ]; then ok "Arduino udev rules installed"; else
        step "Installing udev rules for Arduino, CH340, CP210x, FTDI and ESP32 boards..."
        local rules='# Arduino Easy Setup: give users access to common Arduino/ESP serial chips
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2341", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2a03", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="1a86", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="10c4", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0403", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="303a", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1"'
        if printf '%s\n' "$rules" | need_sudo tee "$UDEV_RULES" >/dev/null; then
            need_sudo udevadm control --reload-rules 2>/dev/null
            need_sudo udevadm trigger 2>/dev/null
            ok "udev rules installed"
        else
            bad "Could not install udev rules"
        fi
    fi

    # brltty (braille display service) grabs CH340 boards on Ubuntu/Mint: the port appears and vanishes
    if command -v brltty >/dev/null 2>&1 || [ -e /usr/lib/udev/rules.d/85-brltty.rules ]; then
        warn "brltty is installed. It steals CH340 boards (port /dev/ttyUSB0 disappears)."
        if ask_yes_no "Remove brltty? (only needed if you use a braille display)" y; then
            if command -v apt-get >/dev/null 2>&1; then need_sudo apt-get remove -y brltty
            elif command -v dnf >/dev/null 2>&1; then need_sudo dnf remove -y brltty
            elif command -v pacman >/dev/null 2>&1; then need_sudo pacman -R --noconfirm brltty
            fi
            ok "brltty removed"
        fi
    else
        ok "No brltty conflict"
    fi
}

# ---------------------------------------------------------------------------
# macOS drivers
# ---------------------------------------------------------------------------
check_mac_drivers() {
    title "USB drivers"
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    if [ "$major" -ge 11 ]; then
        ok "macOS $major has built-in drivers for Arduino, CH340, CP210x and FTDI boards"
        tip "If an old CH340 driver (wch.cn) is installed and causes problems, remove it:"
        tip "  System Settings > General > Login Items & Extensions > Driver Extensions"
    else
        warn "macOS $(sw_vers -productVersion) needs extra drivers for clone boards:"
        tip "CH340:  https://www.wch-ic.com/downloads/CH34XSER_MAC_ZIP.html"
        tip "CP210x: https://www.silabs.com/developer-tools/usb-to-uart-bridge-vcp-drivers"
        if ask_yes_no "Open the CH340 driver page now?" y; then
            open "https://www.wch-ic.com/downloads/CH34XSER_MAC_ZIP.html"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Board packages (cores)
# ---------------------------------------------------------------------------
repair_board_manager() {
    step "Clearing broken downloads and board index cache..."
    local data
    data="$(current_dir data)"
    rm -rf "$data/staging"
    rm -f "$data"/package_*index.json* "$data"/library_index.json*
}

install_core() {
    step "Installing board package $1 (can take several minutes)..."
    if cli_run core install "$1"; then ok "$1 installed"; return 0; fi
    warn "Install of $1 failed, repairing and retrying once..."
    repair_board_manager
    cli_run core update-index >/dev/null
    if cli_run core install "$1"; then ok "$1 installed"; return 0; fi
    bad "Could not install $1."
    if grep -qiE 'timeout|connection|dial tcp|no such host|tls' "$CLI_OUT"; then
        tip "Network problem: check your internet, disable VPN/proxy, or try another network."
    fi
    if grep -qiE 'no space left' "$CLI_OUT"; then
        tip "Your disk is full. ESP32 needs about 2 GB of free space."
    fi
    return 1
}

install_cores() {
    title "Board packages"
    step "Updating board index..."
    if ! cli_run core update-index; then
        repair_board_manager
        cli_run core update-index || { bad "Could not download the board index (check your internet)."; return 1; }
    fi
    local installed core
    installed="$(cli core list 2>/dev/null)"
    for core in "$@"; do
        if printf '%s' "$installed" | grep -q "^$core "; then ok "$core already installed"; continue; fi
        install_core "$core"
    done
}

# ---------------------------------------------------------------------------
# USB device detection
# ---------------------------------------------------------------------------
list_ports() {
    if [ "$OS" = Darwin ]; then
        ls /dev/cu.usbserial* /dev/cu.usbmodem* /dev/cu.wchusbserial* /dev/cu.SLAB_USBtoUART* 2>/dev/null
    else
        ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
    fi
}

# Prints the USB vendor ID (lowercase hex) of a serial port, or nothing.
port_vid() {
    if [ "$OS" = Darwin ]; then
        # macOS port names do not carry the VID; guess from the name and ioreg
        case "$1" in
            *wchusbserial*) echo 1a86; return ;;
            *SLAB_USBtoUART*) echo 10c4; return ;;
        esac
        ioreg -p IOUSB -l -w0 2>/dev/null | sed -n 's/.*"idVendor" = \([0-9]*\).*/\1/p' | while read -r v; do
            case "$(printf '%04x' "$v")" in 2341|2a03|1a86|10c4|0403|303a) printf '%04x\n' "$v"; break ;; esac
        done
    else
        udevadm info -q property -n "$1" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p'
    fi
}

chip_name() {
    case "$1" in
        2341|2a03) echo "Genuine Arduino" ;;
        1a86) echo "CH340/CH341 (clone boards)" ;;
        10c4) echo "CP210x (many ESP32/ESP8266)" ;;
        0403) echo "FTDI" ;;
        303a) echo "ESP32-S2/S3/C3 native USB" ;;
        *) echo "Unknown chip" ;;
    esac
}

FOUND_PORT=""
FOUND_VID=""
wait_for_new_board() {
    FOUND_PORT=""; FOUND_VID=""
    step "Unplug your board from the computer."
    wait_enter "When the board is unplugged"
    local before now p i
    before="$(list_ports)"
    step "Now plug your board in... (waiting up to 30 seconds)"
    i=0
    while [ $i -lt 30 ]; do
        sleep 1
        now="$(list_ports)"
        for p in $now; do
            if ! printf '%s\n' "$before" | grep -qx "$p"; then
                FOUND_PORT="$p"
                sleep 2
                FOUND_VID="$(port_vid "$p")"
                ok "Detected: $(chip_name "$FOUND_VID") on $FOUND_PORT"
                return 0
            fi
        done
        i=$((i + 1))
    done

    bad "No board detected."
    tip "1. Many USB cables are 'charge only' - try a different cable (the #1 beginner problem)."
    tip "2. Try a different USB port, directly on the computer (not a hub)."
    tip "3. Check that a power LED on the board lights up."
    if [ "$OS" = Linux ]; then
        if dmesg 2>/dev/null | tail -n 30 | grep -qi brltty; then
            tip "4. brltty grabbed your board! Run option 3 (Diagnose and fix) to remove it."
        fi
        tip "Kernel log (last USB messages):"
        dmesg 2>/dev/null | grep -iE 'usb|tty' | tail -n 5 | sed 's/^/         /'
    fi
    return 1
}

fix_port_access() {
    [ "$OS" = Linux ] || return 0
    if [ -r "$1" ] && [ -w "$1" ]; then return 0; fi
    warn "No permission to use $1."
    fix_serial_permissions
    sleep 2
    if [ -r "$1" ] && [ -w "$1" ]; then ok "Port access fixed"; return 0; fi
    step "Granting access to $1 for this session..."
    need_sudo chmod a+rw "$1" && ok "Port access granted"
}

# ---------------------------------------------------------------------------
# Test sketch: compile, upload, read serial
# ---------------------------------------------------------------------------
BOARD_NAME=""; BOARD_FQBN=""; BOARD_CORE=""
set_board() {
    case "$1" in
        1) BOARD_NAME="Arduino Uno (or Uno clone)";      BOARD_FQBN="arduino:avr:uno";                BOARD_CORE="arduino:avr" ;;
        2) BOARD_NAME="Arduino Nano (or Nano clone)";    BOARD_FQBN="arduino:avr:nano:cpu=atmega328"; BOARD_CORE="arduino:avr" ;;
        3) BOARD_NAME="Arduino Mega 2560";               BOARD_FQBN="arduino:avr:mega";               BOARD_CORE="arduino:avr" ;;
        4) BOARD_NAME="ESP32 Dev Module";                BOARD_FQBN="esp32:esp32:esp32";              BOARD_CORE="esp32:esp32" ;;
        5) BOARD_NAME="ESP8266 NodeMCU / Wemos D1 mini"; BOARD_FQBN="esp8266:esp8266:nodemcuv2";      BOARD_CORE="esp8266:esp8266" ;;
        *) return 1 ;;
    esac
}

select_board() {
    if [ "$FOUND_VID" = 2341 ] || [ "$FOUND_VID" = 2a03 ]; then
        local fqbn
        fqbn="$(cli board list 2>/dev/null | grep "^$FOUND_PORT " | grep -oE 'arduino:avr:[a-z0-9]+' | head -n 1)"
        case "$fqbn" in
            arduino:avr:uno) set_board 1 ;;
            arduino:avr:nano) set_board 2 ;;
            arduino:avr:mega) set_board 3 ;;
        esac
        if [ -n "$BOARD_FQBN" ]; then ok "Board identified automatically: $BOARD_NAME"; return; fi
    fi
    echo
    echo "  Which board do you have?"
    echo "    1) Arduino Uno (or Uno clone)"
    echo "    2) Arduino Nano (or Nano clone)"
    echo "    3) Arduino Mega 2560"
    echo "    4) ESP32 Dev Module"
    echo "    5) ESP8266 NodeMCU / Wemos D1 mini"
    [ "$FOUND_VID" = 10c4 ] && tip "Hint: CP210x chips are usually on ESP32 or ESP8266 boards."
    [ "$FOUND_VID" = 303a ] && tip "Hint: this is an ESP32 board with native USB."
    local choice
    while true; do
        printf '  Number: '
        read -r choice </dev/tty || choice=''
        set_board "$choice" && return
    done
}

make_test_sketch() {
    local dir
    dir="$(current_dir user)/EasySetupBlink"
    mkdir -p "$dir"
    cat > "$dir/EasySetupBlink.ino" <<'EOF'
// Arduino Easy Setup test sketch: blinks the on-board LED and prints to Serial.
#ifndef LED_BUILTIN
#define LED_BUILTIN 2
#endif

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  Serial.begin(115200);
}

void loop() {
  Serial.println("EASY-SETUP-OK");
  digitalWrite(LED_BUILTIN, HIGH);
  delay(500);
  digitalWrite(LED_BUILTIN, LOW);
  delay(500);
}
EOF
    printf '%s' "$dir"
}

upload_advice() {
    if grep -qiE 'permission denied|could not open port|busy|resource temporarily' "$CLI_OUT"; then
        tip "The port is used by another program or not accessible: close Serial Monitor and other IDEs."
        [ "$OS" = Linux ] && tip "On Linux, log out and back in once so the '$(serial_group)' group applies."
    fi
    if grep -qiE 'not in sync|programmer is not responding' "$CLI_OUT"; then
        tip "The board did not answer. Check the selected board type and port."
        tip "Something connected to pins 0/1 (RX/TX) blocks uploads - disconnect it."
    fi
    if grep -qiE 'Failed to connect to ESP|Wrong boot mode|No serial data received' "$CLI_OUT"; then
        tip "ESP boards: hold the BOOT button, start the upload, release when 'Connecting...' appears."
    fi
    if grep -qiE "No module named 'serial'|python.*not found|python3: command not found" "$CLI_OUT"; then
        tip "Python 3 is missing: install it (Linux: python3 package; macOS: xcode-select --install)."
    fi
}

do_upload() {   # do_upload sketch_dir
    step "Compiling test sketch for $BOARD_NAME..."
    if ! cli_run compile --fqbn "$BOARD_FQBN" "$1"; then
        bad "Compiling failed."; upload_advice; return 1
    fi
    ok "Compiled"
    step "Uploading to $FOUND_PORT..."
    cli_run upload --fqbn "$BOARD_FQBN" --port "$FOUND_PORT" "$1" && return 0

    # Many cheap Nano clones still use the old bootloader (57600 baud)
    case "$BOARD_FQBN" in arduino:avr:nano*)
        warn "Upload failed - trying the 'Old Bootloader' setting used by most Nano clones..."
        local old="arduino:avr:nano:cpu=atmega328old"
        if cli_run compile --fqbn "$old" "$1" && cli_run upload --fqbn "$old" --port "$FOUND_PORT" "$1"; then
            ok "Upload worked with the old bootloader!"
            tip "In the IDE always choose: Tools > Processor > ATmega328P (Old Bootloader)."
            return 0
        fi ;;
    esac

    if [ "$BOARD_CORE" != arduino:avr ] && grep -qiE 'Failed to connect|Wrong boot mode|No serial data' "$CLI_OUT"; then
        warn "The ESP board did not enter upload mode."
        tip "Hold the BOOT button on the board now, and keep holding it."
        wait_enter "While holding BOOT"
        if cli_run upload --fqbn "$BOARD_FQBN" --port "$FOUND_PORT" "$1"; then
            ok "Upload worked with the BOOT button. You can release it."
            tip "Your board needs BOOT held during uploads (normal for some ESP32 boards)."
            return 0
        fi
    fi

    bad "Upload failed."
    upload_advice
    return 1
}

check_serial_output() {
    step "Reading Serial Monitor output on $FOUND_PORT..."
    local out="$TOOL_DIR/serial-test.txt" pid
    if [ "$OS" = Darwin ]; then stty -f "$FOUND_PORT" 115200 raw 2>/dev/null
    else stty -F "$FOUND_PORT" 115200 raw -echo 2>/dev/null
    fi
    : > "$out"
    cat "$FOUND_PORT" > "$out" 2>/dev/null &
    pid=$!
    sleep 6
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    if grep -q 'EASY-SETUP-OK' "$out"; then
        ok "Serial communication works"
    else
        warn "No serial text received (the upload worked, so this is usually harmless)."
        tip "In the IDE, open Tools > Serial Monitor and set the speed to 115200 baud."
    fi
}

test_board() {
    title "Test my board"
    [ -x "$CLI" ] || { install_cli && init_config; }
    wait_for_new_board || return 1
    fix_port_access "$FOUND_PORT"
    BOARD_NAME=""; BOARD_FQBN=""; BOARD_CORE=""
    select_board

    if ! cli core list 2>/dev/null | grep -q "^$BOARD_CORE "; then
        [ "$BOARD_CORE" = esp32:esp32 ] && init_config "$ESP32_URL"
        [ "$BOARD_CORE" = esp8266:esp8266 ] && init_config "$ESP8266_URL"
        install_cores "$BOARD_CORE"
    fi

    local sketch
    sketch="$(make_test_sketch)"
    if do_upload "$sketch"; then
        ok "Upload successful - the LED on your board should be blinking!"
        check_serial_output
        echo
        printf '  %sIn the Arduino IDE choose:%s\n' "$C_CYAN" "$C_RESET"
        echo "    Tools > Board > $BOARD_NAME"
        echo "    Tools > Port  > $FOUND_PORT"
    fi
}

# ---------------------------------------------------------------------------
# Diagnose
# ---------------------------------------------------------------------------
diagnose() {
    title "Diagnose and fix"
    if ide_installed; then ok "Arduino IDE installed"; else
        bad "Arduino IDE not installed"
        ask_yes_no "Install it now?" y && install_ide
    fi
    [ "$OS" = Linux ] && [ -d "${IDE_DIR:-}" ] && fix_chrome_sandbox
    [ -x "$CLI" ] || install_cli
    [ -f "$CLI_CONFIG" ] || init_config

    local data user
    data="$(current_dir data)"; user="$(current_dir user)"
    if path_is_safe "$data" && path_is_safe "$user"; then ok "Arduino folders are in safe paths"; else init_config; fi

    local cores
    cores="$(cli core list 2>/dev/null)"
    if printf '%s' "$cores" | grep -q '^arduino:avr '; then ok "Arduino AVR boards installed (Uno/Nano/Mega)"
    else bad "Arduino AVR boards missing"; install_cores arduino:avr; fi
    printf '%s' "$cores" | grep -q '^esp32:esp32 ' && ok "ESP32 boards installed"
    printf '%s' "$cores" | grep -q '^esp8266:esp8266 ' && ok "ESP8266 boards installed"

    if cli core update-index >/dev/null 2>&1; then ok "Board manager can download updates"
    else
        bad "Board manager index is broken or unreachable"
        repair_board_manager
        if cli core update-index >/dev/null 2>&1; then ok "Board manager repaired"
        else tip "Check your internet connection, VPN, proxy or firewall."; fi
    fi

    local avail
    avail="$(df -Pk "$HOME" | awk 'NR==2 {print int($4/1024/1024)}')"
    if [ "${avail:-0}" -lt 3 ]; then warn "Only ${avail} GB free disk space (ESP32 needs about 2 GB)."; fi

    if [ "$OS" = Linux ]; then
        fix_serial_permissions
        command -v python3 >/dev/null 2>&1 && ok "python3 present" || install_linux_deps
    else
        check_mac_drivers
    fi

    local ports
    ports="$(list_ports)"
    if [ -z "$ports" ]; then
        warn "No board plugged in right now (use 'Test my board' to check the USB connection)."
    else
        local p
        for p in $ports; do ok "Board: $(chip_name "$(port_vid "$p")") on $p"; done
    fi
    echo
    ok "Diagnose finished. Restart the Arduino IDE so it picks up the fixes."
}

# ---------------------------------------------------------------------------
# Full setup
# ---------------------------------------------------------------------------
full_setup() {
    if [ "$AUTO" != 1 ]; then
        ask_yes_no "Will you use ESP32 boards? (about 1 GB download)" n && WANT_ESP32=1
        ask_yes_no "Will you use ESP8266 boards (NodeMCU, Wemos D1)?" n && WANT_ESP8266=1
    fi
    local urls="" cores="arduino:avr"
    [ "$WANT_ESP32" = 1 ] && { urls="$urls $ESP32_URL"; cores="$cores esp32:esp32"; }
    [ "$WANT_ESP8266" = 1 ] && { urls="$urls $ESP8266_URL"; cores="$cores esp8266:esp8266"; }

    [ "$OS" = Linux ] && install_linux_deps
    install_ide
    install_cli || return 1
    # shellcheck disable=SC2086
    init_config $urls
    # shellcheck disable=SC2086
    install_cores $cores
    if [ "$OS" = Linux ]; then fix_serial_permissions; else check_mac_drivers; fi

    title "Setup finished"
    ok "Arduino IDE, boards and serial access are ready."
    [ "$OS" = Linux ] && tip "Log out and back in once so the serial port group applies everywhere."
    if [ "$AUTO" != 1 ] && ask_yes_no "Test a board now? (recommended)" y; then test_board; fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# Everything runs inside main() so that "curl ... | bash" reads the whole script
# before executing anything (otherwise commands reading stdin could eat the script).
main() {
    mkdir -p "$TOOL_DIR" "$DOWNLOAD_DIR" "$LOG_DIR"
    # Copy everything printed to a log file (useful when asking for help)
    exec > >(tee -a "$LOG_FILE") 2>&1

    printf '\n%s  ======================================%s\n' "$C_CYAN" "$C_RESET"
    printf '%s     Arduino Easy Setup (%s)%s\n' "$C_CYAN" "$( [ "$OS" = Darwin ] && echo macOS || echo Linux )" "$C_RESET"
    printf '%s  ======================================%s\n' "$C_CYAN" "$C_RESET"

    case "$OS" in Darwin|Linux) ;; *) bad "This script is for macOS and Linux. On Windows run setup-windows.bat"; exit 1 ;; esac
    command -v curl >/dev/null 2>&1 || { [ "$OS" = Linux ] && install_linux_deps; }

    if [ "$AUTO" = 1 ]; then
        full_setup
        exit $?
    fi

    while true; do
        echo
        echo "  1) Full setup (recommended for the first time)"
        echo "  2) Test my board (detect, upload Blink, check Serial)"
        echo "  3) Diagnose and fix problems"
        echo "  4) Repair board manager (stuck or failed downloads)"
        echo "  5) Show log folder"
        echo "  0) Exit"
        printf '  Choose: '
        read -r choice </dev/tty || exit 0
        case "$choice" in
            1) full_setup ;;
            2) test_board ;;
            3) diagnose ;;
            4) install_cli && repair_board_manager && install_cores arduino:avr ;;
            5) echo "  $LOG_DIR"; [ "$OS" = Darwin ] && open "$LOG_DIR" ;;
            0) exit 0 ;;
        esac
    done
}

main "$@"
