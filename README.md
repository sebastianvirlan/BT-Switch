<img src="docs/icon.png" width="128" alt="BTSwitch icon" align="right">

# BTSwitch

A menu bar app that switches your Apple Magic Keyboard, Magic Mouse, and Magic Trackpad between two Macs over your local network.

One click in the menu bar and your peripherals jump to the other Mac. No iCloud account required, no SSH, no kernel extensions, no key remapping.

![Menu bar icon and dropdown menu](docs/screenshots/menu.jpg)

## Why

If you have two Macs on the same desk — say a personal one and a work one — you've probably tried Universal Control, given up because it doesn't share a single Bluetooth keyboard, tried unpairing/repairing manually, and given up on that too. BTSwitch automates the unpair-on-source / repair-on-destination dance so it happens in a couple of seconds when you click the menu bar icon.

It works with any Bluetooth peripheral that holds only one bond at a time, which includes every Apple Magic peripheral.

### Reliability

BTSwitch uses the same Bluetooth approach as Blue Switch (`IOBluetoothDevicePair.start()` plus the private `remove` selector), with several reliability fixes:

- All IOBluetooth work runs on one dedicated background queue, so pairing callbacks aren't blocked by `openConnection` (without this, pairing hangs after `devicePairingStarted`) and the framework is never used from two threads at once.
- A hard RSSI check fails fast on sleeping peripherals instead of timing out after 10–20 seconds.
- It pings the destination *before* removing peripherals locally, so a network failure can't leave you with no working keyboard.
- If a peripheral doesn't arrive on the destination, BTSwitch reconnects it to the source Mac.
- Only one switch runs at a time. If both Macs are clicked at once, both back off instead of fighting over the peripherals.
- Connection attempts are retried up to 3 times, and `isConnected` is polled briefly afterwards because it can lag.

## How it works

You install BTSwitch on both Macs. Each app:

- Listens on a local TCP port for switch requests from the other Mac
- When clicked, removes the configured peripherals from its own Bluetooth database, then asks the other Mac (over the network) to re-pair and connect them
- Authenticates each request with a shared token you configure once

Click the icon on Mac A, peripherals move to Mac B. Click on Mac B, peripherals move back. Each Mac is configured with the other Mac's address and the list of peripherals to switch.

## Requirements

- Two Macs on the same local network (Wi-Fi or wired)
- macOS 13 (Ventura) or later
- Xcode Command Line Tools (`xcode-select --install`) to build
- Bluetooth peripherals already paired with both Macs at least once via System Settings

## Install

Clone the repo on each Mac and build:

```bash
git clone https://github.com/sebastianvirlan/BT-Switch.git
cd BT-Switch
./build.sh
```

This produces `build/BTSwitch.app`. Move it into Applications:

```bash
mv build/BTSwitch.app /Applications/
```

The first time you launch it, macOS may show a "developer cannot be verified" warning. Right-click the app and choose **Open** to bypass it.

### Building with Xcode

If you'd rather work in Xcode, install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and generate a project:

```bash
brew install xcodegen
xcodegen generate
open BTSwitch.xcodeproj
```

Build with Cmd+B.

## First-time setup

Do these steps on **both** Macs.

### 1. Launch and grant permissions

Open BTSwitch from `/Applications`. macOS will prompt for:

- **Bluetooth permission** — required to switch peripherals
- **Local Network permission** — required so the two Macs can talk

Grant both. If you accidentally denied either, enable them under
System Settings → Privacy & Security. If BTSwitch isn't listed there, delete and reinstall the app.

### 2. Open Settings

A keyboard icon appears in the menu bar. Right-click it and choose **Settings…**

![Settings — General tab](docs/screenshots/settings-general.jpg)

### 3. Configure each Mac

In the **General** tab, fill in:

- **Destination Mac**: the IP address or hostname of the *other* Mac (use IP for reliability)
- **Peripherals**: comma-separated MAC addresses of the keyboard, mouse, etc.

To find a Mac's IP:

```bash
ipconfig getifaddr en0    # Wi-Fi
ipconfig getifaddr en1    # often Ethernet/dock
```

To find a peripheral's Bluetooth address:

```bash
system_profiler SPBluetoothDataType | grep -A 3 -i "magic"
```

### 4. Sync the token

In the **Token** tab, BTSwitch generates a 32-character secret on first launch. Both Macs need the **same** token.

![Settings — Token tab](docs/screenshots/settings-token.jpg)

On the first Mac, click **Copy**. On the second Mac, paste the token into the Token field. Order doesn't matter — pick either Mac's token and use it on both.

### 5. Test the link

Back in the **General** tab, click **Test Connection**. You should see a green check with the other Mac's name, for example "✓ reachable: Studio Mac mini, tokens match".

If you see a red error, it names the cause: BTSwitch not running there, no route to the address, Local Network permission blocked, a token mismatch, and so on. The General tab also shows whether *this* Mac is listening.

## Usage

**Left-click** the menu bar icon to switch peripherals to the other Mac.

**Right-click** for the menu:

- *Switch peripherals to {destination}* — same as left-click
- *Settings…* — open the configuration window
- *Quit*

The icon reflects current state:

| Icon | Meaning |
|---|---|
| Filled keyboard | All peripherals are connected to this Mac |
| Outlined keyboard | Peripherals are on the other Mac |
| Mixed indicator | Some are here, some aren't |
| Spinning arrows | Switch in progress |

## Troubleshooting

### "Last switch failed: can't reach …"

The other Mac's BTSwitch isn't responding. Make sure it's running, the IP is correct, and your firewall allows TCP on the listener port (default 52525).

### "asleep or out of range"

The peripheral isn't responding to wake signals. Press a key or click the mouse to wake it, then try again.

### Token mismatch

Both Macs must use the same token. Open Settings → Token on each Mac and compare the **fingerprints** (a 6-character code). If they differ, copy the token from one Mac and paste it on the other. Spaces and line breaks picked up while pasting are stripped automatically.

The error message shows both fingerprints ("this Mac a3f9c1, other Mac 7be204"), so you can tell which Mac has the wrong token. If it says the tokens match but the request was still rejected, the two Macs are running different BTSwitch builds.

### "Not listening: port 52525 is already in use"

Another program, usually a second copy of BTSwitch, holds the port. BTSwitch offers to quit another running copy at launch. If something else uses the port, pick a different port on **both** Macs.

### "… is this Mac"

The destination address points back at the Mac you're on. Enter the *other* Mac's address.

### "macOS blocked the connection"

Allow BTSwitch under System Settings → Privacy & Security → Local Network.

### "clocks differ by more than 60s"

Requests are timestamped to prevent replay, so both Macs' clocks must be within 60 seconds of each other. Enable System Settings → General → Date & Time → *Set time and date automatically* on both.

### "the other Mac runs an older/newer BTSwitch"

Version 2 changed the network protocol. Update BTSwitch on both Macs.

### Keychain prompt after rebuilding

The token is stored in your Keychain. Because `build.sh` ad-hoc signs the app, each rebuild looks like a new app to the Keychain, and macOS asks whether BTSwitch may read the token. Click **Always Allow**.

### Menu bar icon does nothing on click

If you haven't configured a destination/peripherals/token yet, left-click opens Settings instead of switching. Fill in the General and Token tabs first.

### Peripheral connects then jumps back to the other Mac

This is rare but can happen if the source Mac doesn't fully release the peripheral. Try clicking the icon again — the second attempt usually settles it. If it persists, restart Bluetooth on the source Mac:

```bash
sudo pkill bluetoothd    # auto-respawns
```

### Logs

Settings → **Log** tab shows everything BTSwitch has done. Click **Copy All** to share logs when filing an issue.

![Settings — Log tab](docs/screenshots/settings-log.jpg)

## Security

- BTSwitch listens on one TCP port (default 52525) and only accepts connections from local-network addresses (private IPv4 ranges, link-local, IPv6 unique-local, loopback, and 100.64.0.0/10 for Tailscale-style VPNs).
- Every request is signed with HMAC-SHA256 using the shared token. The token itself never crosses the network.
- Each request carries a timestamp and a one-time nonce, so a captured request can't be replayed.
- The token is stored in the macOS Keychain. Earlier versions kept it in UserDefaults; it's moved to the Keychain automatically on first launch.
- No outbound traffic except to the destination you configure.
- No telemetry, no analytics, no network calls outside the LAN.
- Traffic is not encrypted. Anyone on your network can see which commands are sent and which peripheral addresses are involved, but can't forge or replay them.
- Removing a peripheral relies on a private IOBluetooth method. If a macOS update removes it, BTSwitch logs a warning instead of silently claiming success.

## Configuration reference

All settings are in the Settings window:

| Setting | Description | Default |
|---|---|---|
| Destination Mac | IP or hostname of the other Mac | (empty) |
| Peripherals | Comma-separated Bluetooth MACs | (empty) |
| Listener Port | TCP port BTSwitch listens on | 52525 |
| Token | Shared secret (must match on both Macs) | (auto-generated) |

Settings persist across app restarts via UserDefaults.

## Building from source

The project is a single Swift app, no external dependencies.

```
BTSwitch/
├── BTSwitch/
│   ├── BTSwitchApp.swift          App entry, window management
│   ├── MenuBarController.swift    Menu bar icon and click handling
│   ├── AppSettings.swift          User-configurable settings
│   ├── Keychain.swift             Token storage
│   ├── Protocol.swift             Wire protocol, auth, parsing (pure, unit-tested)
│   ├── SettingsView.swift         Settings UI
│   ├── SwitchCoordinator.swift    Orchestrates a switch
│   ├── BluetoothController.swift  Bluetooth pair/connect/remove
│   ├── NetworkServer.swift        TCP listener
│   ├── NetworkClient.swift        TCP sender
│   ├── Logger.swift               In-app log buffer
│   ├── AppIcon.icns               App icon (generated by scripts/make-icon.swift)
│   ├── Info.plist
│   └── BTSwitch.entitlements
├── project.yml                    XcodeGen spec
├── scripts/make-icon.swift        Regenerates the app icon
├── Tests/main.swift               Unit tests for Protocol.swift
├── build.sh                       Build script (no Xcode project required)
├── test.sh                        Run unit tests (no Xcode required)
└── README.md
```

`build.sh` invokes `swiftc` directly and ad-hoc signs the resulting bundle. The app uses Apple frameworks only: `IOBluetooth`, `Network`, `AppKit`, `SwiftUI`, `Combine`, `CryptoKit`. The one private API is the `remove` selector described above.

Run the unit tests with:

```bash
./test.sh
```

### Upgrading from 1.x

- The protocol changed to `BT-SWITCH/2`. Update **both** Macs.
- The bundle ID changed from `com.user.btswitch` to `io.github.sebastianvirlan.btswitch`. Your destination, peripherals, port and token are migrated automatically, but macOS treats it as a new app, so you'll be asked for Bluetooth and Local Network permission again.

## Contributing

Issues and pull requests welcome. When reporting a bug, please include:

- macOS version (`sw_vers`)
- Mac model (Apple silicon or Intel)
- A copy of the BTSwitch log (Settings → Log → Copy All)
- Whether the issue happens on both Macs or only one

## License

MIT. See [LICENSE](LICENSE).
