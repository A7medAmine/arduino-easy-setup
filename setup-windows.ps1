# Arduino Easy Setup - Windows
# Installs Arduino IDE 2 + board packages + USB drivers, then diagnoses and fixes
# the common beginner problems (missing drivers, bad paths, busy ports, clone Nanos...).
# Runs as the normal user; only driver installs and registry fixes ask for admin (UAC).

param(
    [switch]$Auto,      # run the full setup without the menu
    [switch]$Esp32,     # also install the ESP32 boards package
    [switch]$Esp8266    # also install the ESP8266 boards package
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is 10x slower with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$ToolDir     = Join-Path $env:LOCALAPPDATA 'ArduinoEasySetup'
$CliDir      = Join-Path $ToolDir 'cli'
$Cli         = Join-Path $CliDir 'arduino-cli.exe'
$CliConfig   = Join-Path $ToolDir 'arduino-cli.yaml'
$IdeConfig   = Join-Path $env:USERPROFILE '.arduinoIDE\arduino-cli.yaml'
$DownloadDir = Join-Path $ToolDir 'downloads'
$DriverDir   = Join-Path $env:ProgramData 'ArduinoEasySetup\drivers'   # no user name in path for pnputil
$LogDir      = Join-Path $ToolDir 'logs'
$SafeDataDir = 'C:\ArduinoData'        # used when the default path would break the toolchains
$SafeUserDir = 'C:\ArduinoSketches'

$Esp32Url   = 'https://espressif.github.io/arduino-esp32/package_esp32_index.json'
$Esp8266Url = 'https://arduino.esp8266.com/stable/package_esp8266com_index.json'

$Ch340DriverUrl  = 'https://www.wch-ic.com/download/file?id=5'   # CH341SER.ZIP (contains the .INF)
$Ch340DriverPage = 'https://www.wch-ic.com/downloads/CH341SER_ZIP.html'
$Cp210xDriverUrl  = 'https://www.silabs.com/documents/public/software/CP210x_Universal_Windows_Driver.zip'
$Cp210xDriverPage = 'https://www.silabs.com/developer-tools/usb-to-uart-bridge-vcp-drivers'

# USB vendor IDs we know about: VID -> chip description and the driver it needs
$KnownChips = @{
    '2341' = @{ Name = 'Genuine Arduino';           Driver = 'builtin' }
    '2A03' = @{ Name = 'Genuine Arduino (.org)';    Driver = 'builtin' }
    '1A86' = @{ Name = 'CH340/CH341 (clone boards)'; Driver = 'ch340' }
    '10C4' = @{ Name = 'CP210x (many ESP32/ESP8266)'; Driver = 'cp210x' }
    '0403' = @{ Name = 'FTDI';                      Driver = 'builtin' }
    '303A' = @{ Name = 'ESP32-S2/S3/C3 native USB'; Driver = 'builtin' }
    '067B' = @{ Name = 'PL2303 (old adapters)';     Driver = 'pl2303' }
}

$Boards = @(
    @{ Key = '1'; Name = 'Arduino Uno (or Uno clone)';      Fqbn = 'arduino:avr:uno';               Core = 'arduino:avr' }
    @{ Key = '2'; Name = 'Arduino Nano (or Nano clone)';    Fqbn = 'arduino:avr:nano:cpu=atmega328'; Core = 'arduino:avr' }
    @{ Key = '3'; Name = 'Arduino Mega 2560';               Fqbn = 'arduino:avr:mega';              Core = 'arduino:avr' }
    @{ Key = '4'; Name = 'ESP32 Dev Module';                Fqbn = 'esp32:esp32:esp32';             Core = 'esp32:esp32' }
    @{ Key = '5'; Name = 'ESP8266 NodeMCU / Wemos D1 mini'; Fqbn = 'esp8266:esp8266:nodemcuv2';     Core = 'esp8266:esp8266' }
)

$Libraries = @(
    @{ Name = 'Servo';              For = 'Servo motors' }
    @{ Name = 'DHT sensor library'; For = 'DHT11 / DHT22 temperature and humidity sensors' }
    @{ Name = 'LiquidCrystal I2C';  For = '16x2 / 20x4 LCD screens with an I2C backpack' }
    @{ Name = 'Adafruit SSD1306';   For = '0.96 inch OLED screens' }
    @{ Name = 'Adafruit NeoPixel';  For = 'WS2812 / NeoPixel RGB LED strips' }
    @{ Name = 'NewPing';            For = 'HC-SR04 ultrasonic distance sensors' }
    @{ Name = 'IRremote';           For = 'Infrared remotes and receivers' }
    @{ Name = 'Keypad';             For = 'Matrix keypads (4x4, 4x3)' }
    @{ Name = 'MFRC522';            For = 'RC522 RFID card readers' }
    @{ Name = 'DallasTemperature';  For = 'DS18B20 waterproof temperature sensors' }
    @{ Name = 'RTClib';             For = 'DS1307 / DS3231 real-time clocks' }
)

# Header file -> library that provides it (used by the error explainer)
$HeaderToLibrary = @{
    'Servo.h' = 'Servo'; 'DHT.h' = 'DHT sensor library'; 'Adafruit_Sensor.h' = 'Adafruit Unified Sensor'
    'LiquidCrystal_I2C.h' = 'LiquidCrystal I2C'; 'Adafruit_SSD1306.h' = 'Adafruit SSD1306'
    'Adafruit_GFX.h' = 'Adafruit GFX Library'; 'Adafruit_NeoPixel.h' = 'Adafruit NeoPixel'
    'NewPing.h' = 'NewPing'; 'IRremote.h' = 'IRremote'; 'IRremote.hpp' = 'IRremote'; 'Keypad.h' = 'Keypad'
    'MFRC522.h' = 'MFRC522'; 'DallasTemperature.h' = 'DallasTemperature'; 'OneWire.h' = 'OneWire'
    'RTClib.h' = 'RTClib'
}

# Headers that only exist when the matching board is selected
$BoardOnlyHeaders = @{
    'WiFi.h' = 'ESP32 boards'; 'WebServer.h' = 'ESP32 boards'; 'BluetoothSerial.h' = 'ESP32 boards'
    'ESP8266WiFi.h' = 'ESP8266 boards'; 'ESP8266WebServer.h' = 'ESP8266 boards'
}

# Compiler and upload messages -> plain-language explanation
$ErrorRules = @(
    @{ Pattern = 'expected .{1,3};.{1,3} before'; Title = 'Missing semicolon'
       Fix = @('A line is missing ";" at the end. Look at the line BEFORE the one in the error.') }
    @{ Pattern = 'expected .{1,3}\}.{1,3} at end of input'; Title = 'Missing closing brace }'
       Fix = @('Every { needs a matching }. Use Tools > Auto Format to see where one is missing.') }
    @{ Pattern = 'expected (declaration|unqualified-id) before'; Title = 'Code outside a function, or an extra }'
       Fix = @('Code must be inside setup() or loop(). Check for an extra } or a stray character.') }
    @{ Pattern = 'a function-definition is not allowed here'; Title = 'A function is inside another function'
       Fix = @('Usually a } is missing at the end of setup() or loop() just above this line.') }
    @{ Pattern = 'expected .{1,3}\).{1,3} before'; Title = 'Missing closing bracket )'
       Fix = @('Count the ( and ) on that line - they must match.') }
    @{ Pattern = 'expected primary-expression before'; Title = 'Typo in an expression'
       Fix = @('Something is missing or extra near that spot: a bracket, a comma, or a value.') }
    @{ Pattern = 'expected initializer before'; Title = 'Typo in a declaration'
       Fix = @('Often a missing ";" on the line before, or a misspelled type like "Int" instead of "int".') }
    @{ Pattern = 'else.{1,3} without a previous .{1,3}if'; Title = 'else without if'
       Fix = @('Remove the ";" after if (...), and wrap multi-line blocks in { }.') }
    @{ Pattern = 'stray .{1,3}\\\d{3}'; Title = 'Strange characters in the code'
       Fix = @('Code copied from a website or PDF contains invisible or "smart" quote characters.',
               'Retype the quotes and minus signs on that line, or copy the code from a plain text source.') }
    @{ Pattern = 'redefinition of .{1,3}void (setup|loop)\(\)'; Title = 'setup() or loop() exists twice'
       Fix = @('Your sketch folder has more than one .ino file (several tabs). A sketch needs exactly one setup() and one loop().') }
    @{ Pattern = '(redeclaration of|conflicting declaration)'; Title = 'Same name declared twice'
       Fix = @('Two variables have the same name. Rename one or remove the duplicate.') }
    @{ Pattern = 'too (few|many) arguments to function'; Title = 'Wrong number of values passed to a function'
       Fix = @('Check how many values the function needs, e.g. digitalWrite(pin, HIGH) needs two.') }
    @{ Pattern = '(invalid conversion from|cannot convert)'; Title = 'Wrong type of value'
       Fix = @('A value has the wrong type (text where a number is expected, etc). Check the variable types.') }
    @{ Pattern = 'jump to case label'; Title = 'Variable declared inside a switch case'
       Fix = @('Put the code of that case inside { } braces.') }
    @{ Pattern = 'undefined reference to'; Title = 'Function used but not found when linking'
       Fix = @('A function is used but never written, a library is incomplete, or the library does not support this board.') }
    @{ Pattern = '(Sketch too big|text section exceeds available space|region .* overflowed)'; Title = 'Program too big for this board'
       Fix = @('Remove unused libraries/code, or use a bigger board (Mega or ESP32).') }
    @{ Pattern = '(Low memory available|data section exceeds available space)'; Title = 'Not enough RAM'
       Fix = @('Wrap fixed texts in F(): Serial.println(F("hello")). Use smaller arrays.') }
    @{ Pattern = '(may be incompatible with your current board|claims to run on)'; Title = 'Library made for another board'
       Fix = @('This library does not support the board selected in Tools > Board. Find another library or board.') }
    @{ Pattern = 'Multiple libraries were found for'; Title = 'Note: two copies of a library are installed'
       Fix = @('Not an error by itself. If things fail, delete the copy you do not use from the libraries folder of your sketchbook.') }
    @{ Pattern = '(programmer is not responding|not in sync|stk500v2_ReceiveMessage|stk500_recv)'; Title = 'The board did not answer the upload'
       Fix = @('Check Tools > Board and Tools > Port. Nano clones: Tools > Processor > ATmega328P (Old Bootloader).',
               'Disconnect anything on pins 0 and 1. Run "Test my board" or "Board hardware check" in this tool.') }
    @{ Pattern = "(can't open device|could not open port|Access is denied|Permission denied|Resource busy|PermissionError)"; Title = 'Serial port busy or not allowed'
       Fix = @('Close the Serial Monitor/Plotter and other programs using the port, then upload again.') }
    @{ Pattern = '(no upload port provided|No device found|Port monitor error)'; Title = 'No port selected'
       Fix = @('Plug in the board and choose it in Tools > Port. No port listed? Run "Test my board".') }
    @{ Pattern = '(Failed to connect to ESP|Wrong boot mode|Timed out waiting for packet header|No serial data received)'; Title = 'ESP board not in upload mode'
       Fix = @('Hold the BOOT button, click Upload, release when "Connecting..." appears.') }
    @{ Pattern = '(executable file not found|python3?: (command )?not found)'; Title = 'A required tool (Python) is missing'
       Fix = @('Run "Diagnose and fix" in this tool, then restart the IDE.') }
    @{ Pattern = '(file name too long|filename or extension is too long)'; Title = 'File path too long'
       Fix = @('Run "Diagnose and fix" in this tool to enable long paths and move the Arduino folders.') }
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Title($text) { Write-Host ''; Write-Host "=== $text ===" -ForegroundColor Cyan }
function Write-Step($text)  { Write-Host "  > $text" -ForegroundColor White }
function Write-Ok($text)    { Write-Host "  [OK]   $text" -ForegroundColor Green }
function Write-Warn($text)  { Write-Host "  [WARN] $text" -ForegroundColor Yellow }
function Write-Bad($text)   { Write-Host "  [FAIL] $text" -ForegroundColor Red }
function Write-Tip($text)   { Write-Host "         $text" -ForegroundColor Gray }

function Ask-YesNo($question, [bool]$default = $true) {
    if ($Auto) { return $default }
    $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "  ? $question $hint").Trim().ToLower()
        if ($answer -eq '') { return $default }
        if ($answer -in @('y', 'yes')) { return $true }
        if ($answer -in @('n', 'no')) { return $false }
    }
}

function Wait-Enter($text) {
    if ($Auto) { return }
    [void](Read-Host "  $text (press Enter)")
}

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------
function Get-File($url, $dest) {
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    $agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ArduinoEasySetup'
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -UserAgent $agent
}

function Get-LatestReleaseAsset($repo, $namePattern) {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -like $namePattern } | Select-Object -First 1
    if (-not $asset) { throw "No release file matching '$namePattern' found in $repo" }
    return $asset
}

# Runs a PowerShell snippet as administrator (UAC prompt) and returns its exit code.
function Invoke-Elevated($scriptText) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
    try {
        $proc = Start-Process powershell.exe -Verb RunAs -Wait -PassThru `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
        return $proc.ExitCode
    } catch {
        Write-Warn 'Administrator permission was refused.'
        return 1
    }
}

# Runs arduino-cli, streams its output, and returns exit code + captured lines.
function Invoke-Cli {
    $cliArgs = @('--config-file', $CliConfig) + $args
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # native stderr must not become a terminating error
    $lines = @(& $Cli @cliArgs 2>&1 | ForEach-Object { $s = "$_"; Write-Host "    $s" -ForegroundColor DarkGray; $s })
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    return [pscustomobject]@{ ExitCode = $code; Output = ($lines -join "`n") }
}

# Same as Invoke-Cli but silent (for queries).
function Invoke-CliQuiet {
    $cliArgs = @('--config-file', $CliConfig) + $args
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = (& $Cli @cliArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    return [pscustomobject]@{ ExitCode = $code; Output = $out }
}

# Paths with spaces are fine; non-ASCII characters, apostrophes and very long paths
# break parts of the ESP32/ESP8266 toolchains (and some AVR tools) on Windows.
function Test-PathIsSafe($path) {
    if ($path -match "[^\x20-\x7E]") { return $false }
    if ($path -match "['&%!^]") { return $false }
    if ($path -match 'OneDrive') { return $false }    # OneDrive sync locks build files
    return $true
}

# ---------------------------------------------------------------------------
# arduino-cli + configuration
# ---------------------------------------------------------------------------
function Install-ArduinoCli {
    Write-Title 'Arduino command-line tools'
    if (Test-Path $Cli) {
        $v = Invoke-CliQuiet version
        if ($v.ExitCode -eq 0) { Write-Ok "arduino-cli already installed ($($v.Output.Trim()))"; return }
    }
    Write-Step 'Downloading arduino-cli...'
    $asset = Get-LatestReleaseAsset 'arduino/arduino-cli' 'arduino-cli_*_Windows_64bit.zip'
    $zip = Join-Path $DownloadDir $asset.name
    Get-File $asset.browser_download_url $zip
    New-Item -ItemType Directory -Force -Path $CliDir | Out-Null
    Expand-Archive -Path $zip -DestinationPath $CliDir -Force
    Write-Ok 'arduino-cli installed'
}

function Get-CurrentDirectories {
    $dump = Invoke-CliQuiet config dump --format json
    $data = Join-Path $env:LOCALAPPDATA 'Arduino15'
    $user = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Arduino'
    try {
        $cfg = ($dump.Output | ConvertFrom-Json).config
        if ($cfg.directories.data) { $data = $cfg.directories.data }
        if ($cfg.directories.user) { $user = $cfg.directories.user }
    } catch { }
    return @{ Data = $data; User = $user }
}

function Initialize-Config([string[]]$extraUrls) {
    Write-Title 'Board manager configuration'
    if (-not (Test-Path $CliConfig)) {
        Invoke-CliQuiet config init --dest-file $CliConfig | Out-Null
    }
    foreach ($url in $extraUrls) {
        Invoke-CliQuiet config add board_manager.additional_urls $url | Out-Null
    }

    # Move data/sketch folders out of paths that break the compilers
    $dirs = Get-CurrentDirectories
    if (-not (Test-PathIsSafe $dirs.Data) -or -not (Test-PathIsSafe $dirs.User)) {
        Write-Warn "Your Arduino folders are in a path that breaks some compilers:"
        Write-Tip  "data:      $($dirs.Data)"
        Write-Tip  "sketches:  $($dirs.User)"
        Write-Tip  '(special characters, emoji, accents, or OneDrive in the path)'
        if (Ask-YesNo "Use $SafeDataDir and $SafeUserDir instead? (recommended)") {
            New-Item -ItemType Directory -Force -Path $SafeDataDir, $SafeUserDir | Out-Null
            Invoke-CliQuiet config set directories.data $SafeDataDir | Out-Null
            Invoke-CliQuiet config set directories.user $SafeUserDir | Out-Null
            Write-Ok 'Arduino folders moved to safe paths'
        }
    } else {
        Write-Ok "Arduino folders look fine ($($dirs.Data))"
    }

    Sync-IdeConfig
}

# The IDE keeps its own copy of the arduino-cli config; make it use the same URLs and folders.
function Sync-IdeConfig {
    New-Item -ItemType Directory -Force -Path (Split-Path $IdeConfig) | Out-Null
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if (-not (Test-Path $IdeConfig)) {
        & $Cli config init --dest-file $IdeConfig 2>&1 | Out-Null
    }
    $cfg = (Invoke-CliQuiet config dump --format json).Output | ConvertFrom-Json
    foreach ($url in @($cfg.config.board_manager.additional_urls)) {
        if ($url) { & $Cli --config-file $IdeConfig config add board_manager.additional_urls $url 2>&1 | Out-Null }
    }
    if ($cfg.config.directories.data) {
        & $Cli --config-file $IdeConfig config set directories.data $cfg.config.directories.data 2>&1 | Out-Null
    }
    if ($cfg.config.directories.user) {
        & $Cli --config-file $IdeConfig config set directories.user $cfg.config.directories.user 2>&1 | Out-Null
    }
    $ErrorActionPreference = $previous
    Write-Ok 'Arduino IDE uses the same board manager settings'
}

# ---------------------------------------------------------------------------
# Arduino IDE
# ---------------------------------------------------------------------------
function Find-Ide {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Arduino IDE\Arduino IDE.exe'),
        (Join-Path $env:ProgramFiles 'Arduino IDE\Arduino IDE.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Install-Ide {
    Write-Title 'Arduino IDE 2'
    $existing = Find-Ide
    if ($existing) { Write-Ok "Arduino IDE already installed ($existing)"; return }

    if (Test-Path (Join-Path ${env:ProgramFiles(x86)} 'Arduino\arduino.exe')) {
        Write-Warn 'Old Arduino IDE 1.x found. It can stay, but use the new IDE 2 from now on.'
    }

    Write-Step 'Downloading Arduino IDE (about 150 MB, please wait)...'
    $asset = Get-LatestReleaseAsset 'arduino/arduino-ide' 'arduino-ide_*_Windows_64bit.exe'
    $installer = Join-Path $DownloadDir $asset.name
    if (-not (Test-Path $installer) -or (Get-Item $installer).Length -ne $asset.size) {
        Get-File $asset.browser_download_url $installer
    }
    Write-Step 'Installing Arduino IDE (silent)...'
    Start-Process -FilePath $installer -ArgumentList '/S' -Wait
    $ide = Find-Ide
    if ($ide) {
        Write-Ok "Arduino IDE installed ($ide)"
    } else {
        Write-Bad 'The IDE installer finished but the IDE was not found.'
        Write-Tip "Run the installer manually: $installer"
    }
}

# ---------------------------------------------------------------------------
# Board packages (cores)
# ---------------------------------------------------------------------------
function Repair-BoardManager {
    Write-Step 'Clearing broken downloads and board index cache...'
    $dirs = Get-CurrentDirectories
    $staging = Join-Path $dirs.Data 'staging'
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue }
    Get-ChildItem -Path $dirs.Data -Filter 'package_*index.json*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $dirs.Data -Filter 'library_index.json*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Install-Core($core) {
    Write-Step "Installing board package $core (can take several minutes)..."
    $r = Invoke-Cli core install $core
    if ($r.ExitCode -eq 0) { Write-Ok "$core installed"; return $true }

    Write-Warn "Install of $core failed, repairing and retrying once..."
    Repair-BoardManager
    Invoke-Cli core update-index | Out-Null
    $r = Invoke-Cli core install $core
    if ($r.ExitCode -eq 0) { Write-Ok "$core installed"; return $true }

    Write-Bad "Could not install $core."
    if ($r.Output -match 'timeout|connection|dial tcp|no such host|TLS') {
        Write-Tip 'Network problem: check your internet, disable VPN/proxy, or try another network.'
    }
    if ($r.Output -match 'Access is denied|being used by another process') {
        Write-Tip 'Files are locked: close the Arduino IDE and your antivirus scan, then retry.'
    }
    return $false
}

function Install-Cores([string[]]$cores) {
    Write-Title 'Board packages'
    Write-Step 'Updating board index...'
    $r = Invoke-Cli core update-index
    if ($r.ExitCode -ne 0) {
        Repair-BoardManager
        $r = Invoke-Cli core update-index
        if ($r.ExitCode -ne 0) { Write-Bad 'Could not download the board index (check your internet).'; return }
    }
    $installed = (Invoke-CliQuiet core list).Output
    foreach ($core in $cores) {
        if ($installed -match [regex]::Escape($core)) { Write-Ok "$core already installed"; continue }
        [void](Install-Core $core)
    }
}

# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------
function Test-DriverInstalled($infName) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $list = (& pnputil.exe /enum-drivers 2>&1) -join "`n"
    $ErrorActionPreference = $previous
    return ($list -match [regex]::Escape($infName))
}

function Install-InfDriverFromZip($label, $url, $page, $infName) {
    if (Test-DriverInstalled $infName) { Write-Ok "$label driver already installed"; return $true }
    Write-Step "Downloading $label driver..."
    $zip = Join-Path $DriverDir "$label-driver.zip"
    $dir = Join-Path $DriverDir "$label-driver"
    try {
        Get-File $url $zip
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        Expand-Archive -Path $zip -DestinationPath $dir -Force
    } catch {
        Write-Warn "Automatic download of the $label driver failed. Opening the download page..."
        Start-Process $page
        Write-Tip 'Download, unzip, right-click the .inf file and choose Install.'
        return $false
    }
    Write-Step "Installing $label driver (Windows will ask for administrator permission)..."
    $code = Invoke-Elevated "pnputil.exe /add-driver `"$dir\*.inf`" /subdirs /install; exit 0"
    if (Test-DriverInstalled $infName) { Write-Ok "$label driver installed"; return $true }
    Write-Bad "$label driver was not installed (code $code)."
    return $false
}

function Install-Ch340Driver  { Install-InfDriverFromZip 'CH340'  $Ch340DriverUrl  $Ch340DriverPage  'ch341ser.inf' }
function Install-Cp210xDriver { Install-InfDriverFromZip 'CP210x' $Cp210xDriverUrl $Cp210xDriverPage 'silabser.inf' }

function Install-Drivers {
    Write-Title 'USB drivers'
    Write-Tip 'Genuine Arduino and FTDI boards use drivers built into Windows.'
    Write-Tip 'Clone boards (CH340) and most ESP32/ESP8266 boards (CP210x/CH340) need extra drivers.'
    [void](Install-Ch340Driver)
    [void](Install-Cp210xDriver)
}

# Re-scan hardware so freshly installed drivers attach to plugged-in boards.
function Update-Devices {
    Invoke-Elevated 'pnputil.exe /scan-devices; exit 0' | Out-Null
    Start-Sleep -Seconds 3
}

# ---------------------------------------------------------------------------
# System fixes
# ---------------------------------------------------------------------------
function Repair-LongPaths {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    $value = (Get-ItemProperty -Path $key -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
    if ($value -eq 1) { Write-Ok 'Long file paths are enabled'; return }
    Write-Warn 'Long file paths are disabled (ESP32 builds can fail with "file name too long").'
    if (Ask-YesNo 'Enable long file paths? (needs administrator)') {
        Invoke-Elevated "Set-ItemProperty -Path '$key' -Name LongPathsEnabled -Value 1 -Type DWord; exit 0" | Out-Null
        $value = (Get-ItemProperty -Path $key -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
        if ($value -eq 1) { Write-Ok 'Long file paths enabled' } else { Write-Bad 'Could not enable long paths' }
    }
}

# ---------------------------------------------------------------------------
# USB device detection
# ---------------------------------------------------------------------------
function Get-UsbSerialDevices {
    $devices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '^(USB|FTDIBUS)\\VID_([0-9A-F]{4})' }
    $result = @()
    foreach ($d in $devices) {
        if ($d.InstanceId -notmatch 'VID_([0-9A-F]{4})[&+]PID_([0-9A-F]{4})') { continue }   # FTDIBUS uses '+'
        $vid = $Matches[1]; $pid_ = $Matches[2]
        if (-not $KnownChips.ContainsKey($vid)) { continue }
        $port = $null
        if ($d.FriendlyName -match '\((COM\d+)\)') { $port = $Matches[1] }
        $result += [pscustomobject]@{
            InstanceId = $d.InstanceId
            Name       = $d.FriendlyName
            Vid        = $vid
            Pid        = $pid_
            Chip       = $KnownChips[$vid].Name
            Driver     = $KnownChips[$vid].Driver
            Status     = $d.Status
            Port       = $port
        }
    }
    # Composite devices show up as several entries; prefer the one with a COM port
    return $result | Sort-Object { -not $_.Port } | Group-Object Vid, Pid | ForEach-Object { $_.Group[0] }
}

function Repair-Device($device) {
    # Official FTDI drivers set the product ID of counterfeit chips to 0000, which disables them
    if ($device.Vid -eq '0403' -and $device.Pid -eq '0000') {
        Write-Bad 'This board has a counterfeit FTDI chip that the FTDI driver disabled (PID 0000).'
        Write-Tip 'The board is not broken. Restore it with FTDI "FT_PROG" (set PID back to 6001),'
        Write-Tip 'or use a board/adapter with a CH340 or CP2102 chip instead.'
        return $null
    }
    if ($device.Status -eq 'OK' -and $device.Port) { return $device }
    Write-Warn "$($device.Chip) found but it has no working COM port (status: $($device.Status))."
    switch ($device.Driver) {
        'ch340'  { [void](Install-Ch340Driver) }
        'cp210x' { [void](Install-Cp210xDriver) }
        'pl2303' {
            Write-Tip 'PL2303 clones are blocked by new Prolific drivers. Use a CH340 or CP2102 adapter,'
            Write-Tip 'or install the old Prolific 3.3.2.102 driver.'
        }
        default  { Write-Tip 'Unplug the board, wait 5 seconds, plug it into a different USB port.' }
    }
    Update-Devices
    $again = Get-UsbSerialDevices | Where-Object { $_.Vid -eq $device.Vid -and $_.Pid -eq $device.Pid } | Select-Object -First 1
    if ($again -and $again.Status -eq 'OK' -and $again.Port) { Write-Ok "Driver fixed: $($again.Port)"; return $again }
    Write-Bad 'The board still has no COM port. Unplug and replug it, then run "Test my board" again.'
    return $again
}

function Wait-ForNewBoard {
    Write-Step 'Unplug your board from the computer.'
    Wait-Enter 'When the board is unplugged'
    $before = @(Get-UsbSerialDevices | ForEach-Object { $_.InstanceId })
    $beforePorts = @([System.IO.Ports.SerialPort]::GetPortNames())

    Write-Step 'Now plug your board in... (waiting up to 30 seconds)'
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        $new = Get-UsbSerialDevices | Where-Object { $before -notcontains $_.InstanceId } | Select-Object -First 1
        if ($new) {
            Start-Sleep -Seconds 2   # give Windows time to finish installing the driver
            $refreshed = Get-UsbSerialDevices | Where-Object { $_.InstanceId -eq $new.InstanceId } | Select-Object -First 1
            if ($refreshed) { $new = $refreshed }
            Write-Ok "Detected: $($new.Chip)  [VID $($new.Vid) PID $($new.Pid)]  $($new.Port)"
            return $new
        }
        $newPort = @([System.IO.Ports.SerialPort]::GetPortNames()) | Where-Object { $beforePorts -notcontains $_ } | Select-Object -First 1
        if ($newPort) {
            Write-Ok "Detected a new serial port: $newPort (unknown chip)"
            return [pscustomobject]@{ Port = $newPort; Status = 'OK'; Vid = ''; Pid = ''; Chip = 'Unknown'; Driver = 'builtin'; InstanceId = '' }
        }
    }
    Write-Bad 'No board detected.'
    Write-Tip '1. Many USB cables are "charge only" - try a different cable (the #1 beginner problem).'
    Write-Tip '2. Try a different USB port, directly on the computer (not a hub).'
    Write-Tip '3. Check that a power LED on the board lights up.'
    return $null
}

# ---------------------------------------------------------------------------
# Test sketch: compile, upload, read serial
# ---------------------------------------------------------------------------
# Lives in the sketchbook (already checked for a safe path) so the toolchains can build it.
function New-TestSketch {
    $dir = Join-Path (Get-CurrentDirectories).User 'EasySetupBlink'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $code = @'
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
'@
    Set-Content -Path (Join-Path $dir 'EasySetupBlink.ino') -Value $code -Encoding ASCII
    return $dir
}

function Select-Board($device) {
    if ($device.Vid -in @('2341', '2A03')) {
        $list = Invoke-CliQuiet board list --format json
        try {
            $ports = ($list.Output | ConvertFrom-Json).detected_ports
            $match = $ports | Where-Object { $_.port.address -eq $device.Port } | Select-Object -First 1
            $fqbn = @($match.matching_boards)[0].fqbn
            $known = $Boards | Where-Object { $fqbn -like "$($_.Fqbn.Split(':')[0..2] -join ':')*" } | Select-Object -First 1
            if ($known) { Write-Ok "Board identified automatically: $($known.Name)"; return $known }
        } catch { }
    }
    Write-Host ''
    Write-Host '  Which board do you have?'
    foreach ($b in $Boards) { Write-Host "    $($b.Key)) $($b.Name)" }
    if ($device.Driver -eq 'cp210x') { Write-Tip 'Hint: CP210x chips are usually on ESP32 or ESP8266 boards.' }
    if ($device.Vid -eq '303A') { Write-Tip 'Hint: this is an ESP32 board with native USB.' }
    while ($true) {
        $choice = (Read-Host '  Number').Trim()
        $b = $Boards | Where-Object { $_.Key -eq $choice } | Select-Object -First 1
        if ($b) { return $b }
    }
}

function Test-SerialOutput($port) {
    Write-Step "Reading Serial Monitor output on $port..."
    $sp = New-Object System.IO.Ports.SerialPort $port, 115200
    $sp.ReadTimeout = 500
    try {
        $sp.Open()
        $deadline = (Get-Date).AddSeconds(8)
        $text = ''
        while ((Get-Date) -lt $deadline) {
            try { $text += $sp.ReadExisting() } catch { }
            if ($text -match 'EASY-SETUP-OK') { Write-Ok 'Serial communication works'; return $true }
            if ($text -match 'NON GENUINE DEVICE') {
                Write-Bad 'The FTDI driver found a counterfeit chip and replaces your data with a warning.'
                Write-Tip 'Install the older FTDI driver 2.10.00, or use a CH340/CP2102 board instead.'
                return $false
            }
            Start-Sleep -Milliseconds 200
        }
        Write-Warn 'No serial text received (the upload worked, so this is usually harmless).'
        Write-Tip 'In the IDE, open Tools > Serial Monitor and set the speed to 115200 baud.'
        return $false
    } catch {
        Write-Warn "Could not open $port : $($_.Exception.Message)"
        Write-Tip 'Close the Arduino IDE Serial Monitor/Plotter and any other serial program, then retry.'
        return $false
    } finally {
        if ($sp.IsOpen) { $sp.Close() }
    }
}

function Invoke-Upload($board, $port, $sketch) {
    Write-Step "Compiling test sketch for $($board.Name)..."
    $c = Invoke-Cli compile --fqbn $board.Fqbn $sketch
    if ($c.ExitCode -ne 0) {
        Write-Bad 'Compiling failed.'
        [void](Show-ErrorHelp $c.Output)
        return $false
    }
    Write-Ok 'Compiled'

    Write-Step "Uploading to $port..."
    $u = Invoke-Cli upload --fqbn $board.Fqbn --port $port $sketch
    if ($u.ExitCode -eq 0) { return $true }

    # Many cheap Nano clones still use the old bootloader (57600 baud)
    if ($board.Fqbn -like 'arduino:avr:nano*') {
        Write-Warn 'Upload failed - trying the "Old Bootloader" setting used by most Nano clones...'
        $old = 'arduino:avr:nano:cpu=atmega328old'
        $c = Invoke-Cli compile --fqbn $old $sketch
        $u = Invoke-Cli upload --fqbn $old --port $port $sketch
        if ($u.ExitCode -eq 0) {
            Write-Ok 'Upload worked with the old bootloader!'
            Write-Tip 'In the IDE always choose: Tools > Processor > ATmega328P (Old Bootloader).'
            return $true
        }
    }

    if ($board.Core -ne 'arduino:avr' -and $u.Output -match 'Failed to connect|Wrong boot mode|No serial data') {
        Write-Warn 'The ESP board did not enter upload mode.'
        Write-Tip 'Hold the BOOT button on the board now, and keep holding it.'
        Wait-Enter 'While holding BOOT'
        $u = Invoke-Cli upload --fqbn $board.Fqbn --port $port $sketch
        if ($u.ExitCode -eq 0) {
            Write-Ok 'Upload worked with the BOOT button. You can release it.'
            Write-Tip 'Your board needs BOOT held during uploads (normal for some ESP32 boards).'
            return $true
        }
    }

    Write-Bad 'Upload failed.'
    [void](Show-ErrorHelp $u.Output)
    return $false
}

function Test-Board {
    Write-Title 'Test my board'
    if (-not (Test-Path $Cli)) { Install-ArduinoCli; Initialize-Config @() }
    $device = Wait-ForNewBoard
    if (-not $device) { return }
    if ($device.Vid) { $device = Repair-Device $device }
    if (-not $device -or -not $device.Port) { return }
    [void](Test-ConnectionStable $device)

    $board = Select-Board $device
    $installed = (Invoke-CliQuiet core list).Output
    if ($installed -notmatch [regex]::Escape($board.Core)) {
        if ($board.Core -eq 'esp32:esp32') { Initialize-Config @($Esp32Url) }
        if ($board.Core -eq 'esp8266:esp8266') { Initialize-Config @($Esp8266Url) }
        Install-Cores @($board.Core)
    }

    $sketch = New-TestSketch
    if (Invoke-Upload $board $device.Port $sketch) {
        Write-Ok 'Upload successful - the LED on your board should be blinking!'
        [void](Test-SerialOutput $device.Port)
        Write-Host ''
        Write-Host '  In the Arduino IDE choose:' -ForegroundColor Cyan
        Write-Host "    Tools > Board > $($board.Name)"
        Write-Host "    Tools > Port  > $($device.Port)"
    } else {
        Invoke-BoardRescue $device $board
    }
}

# ---------------------------------------------------------------------------
# Beginner libraries
# ---------------------------------------------------------------------------
function Install-Library($name) {
    $r = Invoke-Cli lib install $name
    if ($r.ExitCode -eq 0) { Write-Ok "$name installed"; return $true }
    Write-Bad "Could not install $name"
    return $false
}

function Install-Libraries {
    Write-Title 'Beginner libraries'
    if (-not (Test-Path $Cli)) { Install-ArduinoCli; Initialize-Config @() }
    Write-Step 'Updating library index...'
    [void](Invoke-CliQuiet lib update-index)
    $installed = (Invoke-CliQuiet lib list).Output
    for ($i = 0; $i -lt $Libraries.Count; $i++) {
        $lib = $Libraries[$i]
        $mark = ''
        if ($installed -match "(?m)^$([regex]::Escape($lib.Name)) ") { $mark = '[installed]' }
        Write-Host ('    {0,2}) {1,-20} {2} {3}' -f ($i + 1), $lib.Name, $lib.For, $mark)
    }
    Write-Host '     A) All of them'
    $answer = 'A'
    if (-not $Auto) { $answer = (Read-Host '  Numbers separated by commas, or A for all').Trim() }
    $selected = @()
    if ($answer -match '^[aA]') {
        $selected = $Libraries
    } else {
        foreach ($part in ($answer -split '[,\s]+')) {
            if ($part -match '^\d+$' -and [int]$part -ge 1 -and [int]$part -le $Libraries.Count) {
                $selected += $Libraries[[int]$part - 1]
            }
        }
    }
    if ($selected.Count -eq 0) { Write-Warn 'Nothing selected.'; return }
    foreach ($lib in $selected) {
        Write-Step "Installing $($lib.Name)..."
        [void](Install-Library $lib.Name)
    }
    Write-Tip 'Examples: in the IDE open File > Examples and scroll down to the library name.'
}

# ---------------------------------------------------------------------------
# Error explainer
# ---------------------------------------------------------------------------
# Explains compiler/upload output in plain language. Returns how many problems it recognized.
# gcc quotes names with ' or with Unicode quotes depending on the system, hence ".{1,3}".
function Show-ErrorHelp($text) {
    if (-not $text) { return 0 }
    $found = 0

    $headers = @([regex]::Matches($text, '([\w./\\-]+\.h(?:pp)?): No such file or directory') |
        ForEach-Object { Split-Path $_.Groups[1].Value -Leaf } | Select-Object -Unique)
    foreach ($h in $headers) {
        $found++
        if ($BoardOnlyHeaders.ContainsKey($h)) {
            Write-Host "  * $h only exists for $($BoardOnlyHeaders[$h])" -ForegroundColor Yellow
            Write-Tip 'Select the right board in Tools > Board. Uno, Nano and Mega have no WiFi or Bluetooth.'
            continue
        }
        Write-Host "  * Missing library: $h" -ForegroundColor Yellow
        $lib = $HeaderToLibrary[$h]
        if (-not $lib -and (Test-Path $Cli)) {
            try {
                $search = (Invoke-CliQuiet lib search --format json "provides=$h").Output | ConvertFrom-Json
                $lib = @($search.libraries)[0].name
            } catch { }
        }
        if ($lib) {
            Write-Tip "It comes from the library '$lib'."
            if ((Test-Path $Cli) -and (Ask-YesNo "Install '$lib' now?")) { [void](Install-Library $lib) }
        } else {
            Write-Tip "Search for $h in the IDE: Sketch > Include Library > Manage Libraries."
        }
    }

    $names = @([regex]::Matches($text, '([A-Za-z_][\w:]*).{1,3} (?:was not declared in this scope|does not name a type)') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    foreach ($n in $names) {
        $found++
        Write-Host "  * '$n' is unknown to the compiler" -ForegroundColor Yellow
        switch -Regex ($n) {
            '^Serial[123]$' { Write-Tip 'This board has only one serial port: use Serial, or choose Mega/ESP32 in Tools > Board.' }
            '^(WiFi|WebServer|BluetoothSerial)' { Write-Tip 'WiFi/Bluetooth need an ESP32 or ESP8266 board selected in Tools > Board.' }
            '^LED_BUILTIN$' { Write-Tip 'This board has no LED_BUILTIN: use the pin number of your LED instead (e.g. 13 or 2).' }
            default {
                $lib = $HeaderToLibrary["$n.h"]
                if ($lib) {
                    Write-Tip "Add #include <$n.h> at the top of the sketch (library '$lib')."
                    break
                }
                Write-Tip 'Check the spelling AND capital letters (digitalWrite, not digitalwrite).'
                Write-Tip 'Variables must be declared before use, and not only inside another function.'
                Write-Tip 'If it comes from a library, add its #include line at the top of the sketch.'
            }
        }
    }

    foreach ($rule in $ErrorRules) {
        if ($text -match $rule.Pattern) {
            $found++
            Write-Host "  * $($rule.Title)" -ForegroundColor Yellow
            foreach ($line in $rule.Fix) { Write-Tip $line }
        }
    }

    if ($found -eq 0) {
        $first = ($text -split "`n") | Where-Object { $_ -match 'error' } | Select-Object -First 1
        Write-Host '  * Unknown error' -ForegroundColor Yellow
        if ($first) { Write-Tip "First error line: $($first.Trim())" }
        Write-Tip 'Fix the FIRST error in the list; the others are often caused by it.'
        Write-Tip 'The number after the file name (sketch.ino:12) is the line to look at.'
    }
    return $found
}

function Invoke-ExplainError {
    Write-Title 'Explain an error message'
    Write-Tip 'In the Arduino IDE, click "Copy error messages" (top right of the Output panel).'
    Wait-Enter 'Then come back here'
    $text = ''
    try { $text = Get-Clipboard -Raw } catch { }
    if (-not $text -or $text -notmatch 'error|avrdude|esptool|fatal|exit status|Failed') {
        Write-Step 'Paste the error here, then type END on its own line:'
        $lines = @()
        while ($true) {
            $line = Read-Host
            if ($line.Trim() -eq 'END') { break }
            $lines += $line
        }
        $text = $lines -join "`n"
    } else {
        Write-Ok 'Read the error from the clipboard'
    }
    Write-Host ''
    [void](Show-ErrorHelp $text)
}

# ---------------------------------------------------------------------------
# Hardware checks
# ---------------------------------------------------------------------------
function Test-ConnectionStable($device) {
    if (-not $device.Port) { return $true }
    Write-Step 'Checking that the connection is stable (5 seconds)...'
    for ($i = 0; $i -lt 5; $i++) {
        Start-Sleep -Seconds 1
        if (@([System.IO.Ports.SerialPort]::GetPortNames()) -notcontains $device.Port) {
            Write-Bad 'The board disconnected by itself.'
            Write-Tip 'Usual causes: a short circuit in your wiring (5V touching GND), motors or servos'
            Write-Tip 'powered from the Arduino 5V pin, a damaged cable, or a weak USB port/hub.'
            Write-Tip 'Remove all wires from the board and try again.'
            return $false
        }
    }
    Write-Ok 'Connection is stable'
    return $true
}

# Sends text out of TX and expects it back on RX (pins 0 and 1 bridged, main chip held in reset).
# Returns $true/$false, or $null when the port could not be opened.
function Test-Loopback($port) {
    $sp = New-Object System.IO.Ports.SerialPort $port, 9600
    try {
        $sp.Open()
        $sp.DiscardInBuffer()
        $sp.Write('LOOPBACK-TEST-123')
        Start-Sleep -Milliseconds 800
        return ($sp.ReadExisting() -match 'LOOPBACK-TEST-123')
    } catch {
        Write-Warn "Could not open $port : $($_.Exception.Message)"
        return $null
    } finally {
        if ($sp.IsOpen) { $sp.Close() }
    }
}

function Show-BurnBootloaderGuide {
    Write-Tip 'Fix: burn a new bootloader using a second, working Arduino Uno as a programmer:'
    Write-Tip '  1. On the working Uno upload: File > Examples > 11.ArduinoISP > ArduinoISP'
    Write-Tip '  2. Wire working Uno -> broken board:  10 -> RESET,  11 -> 11,  12 -> 12,  13 -> 13,'
    Write-Tip '     5V -> 5V,  GND -> GND   (Mega as target: use its pins 51, 50, 52 instead of 11, 12, 13)'
    Write-Tip '  3. Tools > Board: the BROKEN board type.  Tools > Programmer: "Arduino as ISP"'
    Write-Tip '  4. Tools > Burn Bootloader. Then upload normally over USB again.'
}

function Invoke-BoardRescue($device, $board) {
    Write-Title 'Board hardware check'
    if (-not (Ask-YesNo 'Run a guided hardware check to find the cause? (2 minutes)')) { return }

    Write-Step 'Disconnect ALL wires, sensors and shields from the board. Keep only the USB cable.'
    Wait-Enter 'When only the USB cable is connected'
    if ($board -and (Ask-YesNo 'Try the upload again with nothing connected?')) {
        if (Invoke-Upload $board $device.Port (New-TestSketch)) {
            Write-Ok 'Upload worked! Something in your wiring was blocking it (often a wire on pin 0 or 1).'
            return
        }
    }

    if (-not (Ask-YesNo 'Is the ON (power) LED on the board lit?')) {
        Write-Bad 'The board gets no power.'
        Write-Tip 'Try another cable and USB port. If it stays dark the board is damaged (often a short or a burnt regulator).'
        return
    }

    $bootloader = $true
    if (-not $board -or $board.Core -eq 'arduino:avr') {
        Write-Step 'Press and release the RESET button while watching the small "L" LED.'
        $bootloader = Ask-YesNo 'Did the L LED flash quickly 1-3 times right after RESET?'
    }

    $loop = $null
    if ($device.Vid -ne '303A') {
        Write-Step 'USB chip test: connect a jumper wire between pin 0 (RX) and pin 1 (TX).'
        Write-Step 'Then press and HOLD the RESET button (EN on ESP boards).'
        Wait-Enter 'While holding RESET'
        $loop = Test-Loopback $device.Port
        Write-Step 'You can release RESET and remove the jumper wire.'
    }

    Write-Host ''
    if ($loop -eq $false) {
        Write-Bad 'The USB-to-serial part does not pass data.'
        Write-Tip 'Try a different USB cable. If it still fails, the USB chip on the board is damaged.'
    } elseif ($loop -eq $true -and -not $bootloader) {
        Write-Bad 'The USB part works, but the main chip does not answer: its bootloader is missing or damaged.'
        Show-BurnBootloaderGuide
    } elseif ($loop -eq $true) {
        Write-Ok 'The board hardware looks fine.'
        Write-Tip 'Check the board type in Tools > Board (a "Uno" clone can really be a Nano, etc).'
        Write-Tip 'Nano clones: Tools > Processor > ATmega328P (Old Bootloader).'
        Write-Tip 'Make sure nothing is connected to pins 0 and 1 while uploading.'
    } else {
        Write-Tip 'Could not run the USB test. Close every program that uses the port and try again.'
    }
}

function Invoke-HardwareCheck {
    if (-not (Test-Path $Cli)) { Install-ArduinoCli; Initialize-Config @() }
    $device = Wait-ForNewBoard
    if (-not $device) { return }
    if ($device.Vid) { $device = Repair-Device $device }
    if (-not $device -or -not $device.Port) { return }
    [void](Test-ConnectionStable $device)
    Invoke-BoardRescue $device $null
}

# ---------------------------------------------------------------------------
# Diagnose
# ---------------------------------------------------------------------------
function Invoke-Diagnose {
    Write-Title 'Diagnose and fix'
    $problems = 0

    $ide = Find-Ide
    if ($ide) { Write-Ok "Arduino IDE installed" } else { Write-Bad 'Arduino IDE not installed'; $problems++
        if (Ask-YesNo 'Install it now?') { Install-Ide } }

    if (-not (Test-Path $Cli)) { Install-ArduinoCli }
    if (-not (Test-Path $CliConfig)) { Initialize-Config @() }

    $dirs = Get-CurrentDirectories
    if ((Test-PathIsSafe $dirs.Data) -and (Test-PathIsSafe $dirs.User)) {
        Write-Ok 'Arduino folders are in safe paths'
    } else { $problems++; Initialize-Config @() }

    Repair-LongPaths

    $cores = (Invoke-CliQuiet core list).Output
    if ($cores -match 'arduino:avr') { Write-Ok 'Arduino AVR boards installed (Uno/Nano/Mega)' }
    else { Write-Bad 'Arduino AVR boards missing'; $problems++; Install-Cores @('arduino:avr') }
    if ($cores -match 'esp32:esp32') { Write-Ok 'ESP32 boards installed' }
    if ($cores -match 'esp8266:esp8266') { Write-Ok 'ESP8266 boards installed' }

    $check = Invoke-CliQuiet core update-index
    if ($check.ExitCode -eq 0) { Write-Ok 'Board manager can download updates' }
    else {
        Write-Bad 'Board manager index is broken or unreachable'; $problems++
        Repair-BoardManager
        if ((Invoke-CliQuiet core update-index).ExitCode -eq 0) { Write-Ok 'Board manager repaired' }
        else { Write-Tip 'Check your internet connection, VPN, proxy or firewall.' }
    }

    $ideRunning = Get-Process -Name 'Arduino IDE' -ErrorAction SilentlyContinue
    if ($ideRunning) { Write-Tip 'The Arduino IDE is running; restart it after fixes so it picks them up.' }

    $devices = @(Get-UsbSerialDevices)
    if ($devices.Count -eq 0) {
        Write-Warn 'No board plugged in right now (use "Test my board" to check the USB connection).'
    }
    foreach ($d in $devices) {
        if ($d.Status -eq 'OK' -and $d.Port) { Write-Ok "Board: $($d.Chip) on $($d.Port)" }
        else { $problems++; [void](Repair-Device $d) }
    }

    Write-Host ''
    if ($problems -eq 0) { Write-Ok 'No problems found.' }
    else { Write-Host "  Found and tried to fix $problems problem(s). Run Diagnose again to confirm." -ForegroundColor Yellow }
}

# ---------------------------------------------------------------------------
# Full setup
# ---------------------------------------------------------------------------
function Invoke-FullSetup {
    $wantEsp32 = $Esp32
    $wantEsp8266 = $Esp8266
    if (-not $Auto) {
        $wantEsp32 = Ask-YesNo 'Will you use ESP32 boards? (about 1 GB download)' $false
        $wantEsp8266 = Ask-YesNo 'Will you use ESP8266 boards (NodeMCU, Wemos D1)?' $false
    }
    $urls = @()
    $cores = @('arduino:avr')
    if ($wantEsp32) { $urls += $Esp32Url; $cores += 'esp32:esp32' }
    if ($wantEsp8266) { $urls += $Esp8266Url; $cores += 'esp8266:esp8266' }

    Install-Ide
    Install-ArduinoCli
    Initialize-Config $urls
    Repair-LongPaths
    Install-Cores $cores
    Install-Drivers
    if (Ask-YesNo 'Install popular beginner libraries (servo, sensors, LCD, LEDs)?') { Install-Libraries }

    Write-Title 'Setup finished'
    Write-Ok 'Arduino IDE, boards and drivers are ready.'
    if (-not $Auto -and (Ask-YesNo 'Test a board now? (recommended)')) { Test-Board }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $ToolDir, $DownloadDir, $LogDir | Out-Null
$logFile = Join-Path $LogDir ("setup-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
try { Start-Transcript -Path $logFile | Out-Null } catch { }

Write-Host ''
Write-Host '  ======================================' -ForegroundColor Cyan
Write-Host '       Arduino Easy Setup (Windows)' -ForegroundColor Cyan
Write-Host '  ======================================' -ForegroundColor Cyan

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Bad 'Arduino IDE 2 needs 64-bit Windows.'
    exit 1
}

try {
    if ($Auto) {
        Invoke-FullSetup
    } else {
        while ($true) {
            Write-Host ''
            Write-Host '  1) Full setup (recommended for the first time)'
            Write-Host '  2) Test my board (detect, upload Blink, check Serial)'
            Write-Host '  3) Diagnose and fix problems'
            Write-Host '  4) Install beginner libraries'
            Write-Host '  5) Explain an error message'
            Write-Host '  6) Board hardware check (upload keeps failing)'
            Write-Host '  7) Repair board manager (stuck or failed downloads)'
            Write-Host '  8) Reinstall USB drivers'
            Write-Host '  9) Open log folder'
            Write-Host '  0) Exit'
            $choice = (Read-Host '  Choose').Trim()
            try {
                switch ($choice) {
                    '1' { Invoke-FullSetup }
                    '2' { Test-Board }
                    '3' { Invoke-Diagnose }
                    '4' { Install-Libraries }
                    '5' { Invoke-ExplainError }
                    '6' { Invoke-HardwareCheck }
                    '7' { Install-ArduinoCli; Repair-BoardManager; Install-Cores @('arduino:avr') }
                    '8' { Install-Drivers; Update-Devices }
                    '9' { Start-Process explorer.exe $LogDir }
                    '0' { break }
                }
            } catch {
                Write-Bad "Unexpected error: $($_.Exception.Message)"
                Write-Tip "Details are saved in the log: $logFile"
            }
            if ($choice -eq '0') { break }
        }
    }
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}
