<h1 align="center">
  <br>
  <a><img src="https://github.com/user-attachments/assets/e0c2c051-2776-42dc-8720-461b785f0704" alt="Knotch" width="150"></a>
  <br>
  Knotch
  <br>
</h1>

<p align="center">
  Make your MacBook's notch actually do something.
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/657cf681-9098-4b21-aa07-a21880023ce9" alt="Demo GIF" />
</p>

---

**Knotch** is a fork of [Boring.Notch](https://github.com/TheBoredTeam/boring.notch) that transforms the MacBook notch into a live, interactive hub — music controls, album art, system HUD replacements, lock screen widgets, a drag-and-drop shelf, calendar, and more.

## Features

**Music & Media**
- Live music activity with album art, playback controls, and audio spectrum visualizer
- Sneak peek on playback changes (collapsed notch preview)
- Lock screen music widget with frosted glass or tinted style
- Expanded album art background on lock screen *(Beta)*
- Lyrics display below artist name *(Beta)*
- Configurable media inactivity timeout and full-screen behavior

**System HUD Replacement**
- Replaces macOS volume, display brightness, and keyboard brightness HUDs
- Inline or overlay HUD style with optional gradient and glow
- Accent color tinting and shadow effects

**Notch Widgets**
- Calendar integration with reminders, all-day event filtering, and auto-scroll
- Mirror widget (webcam preview in the notch)
- Battery indicator with charging status, percentage, and power notifications
- Download progress indicator for Safari and other browsers

**Shelf**
- Drag files into the notch to stage them for AirDrop or LocalSend
- Configurable drag detection area, copy-on-drag, and auto-remove after sharing

**Lock Screen**
- Music widget displayed over the lock screen with selectable glass style
- Lock screen clock overlay

**Customization**
- Notch size modes: match real notch, match menu bar, or fully custom
- Corner radius scaling, window shadow, accent color
- Emoji display, settings icon in notch, face animation when idle
- Keyboard shortcuts for sneak peek and open/close toggle
- Works on both notch and non-notch displays; multi-display aware

---

## System Requirements

- macOS **14 Sonoma** or later
- Apple Silicon or Intel Mac

---

## Installation

### Option 1: Download Manually

<a href="https://github.com/TheBoredTeam/boring.notch/releases/latest/download/boringNotch.dmg"><img width="200" src="https://github.com/user-attachments/assets/e3179be1-8416-4b8a-b417-743e1ecc67d6" alt="Download for macOS" /></a>

Open the `.dmg` and move **Knotch** to your `/Applications` folder.

> [!IMPORTANT]
> Knotch is not yet notarized. macOS will block it on first launch. Run this once to clear the quarantine flag, then open normally:
> ```bash
> xattr -dr com.apple.quarantine /Applications/boringNotch.app
> ```
> Alternatively: open the app, dismiss the warning, then go to **System Settings → Privacy & Security** and click **Open Anyway**. (This method doesn't work for all users.)

### Option 2: Homebrew

```bash
brew install --cask TheBoredTeam/boring-notch/boring-notch
```
Homebrew handles the quarantine bypass automatically.

---

## Building from Source

**Prerequisites:** macOS 14+, Xcode 16+

```bash
git clone https://github.com/TheBoredTeam/boring.notch.git
cd boring.notch
open boringNotch.xcodeproj
```

Then press `Cmd + R` to build and run.

---

## Roadmap

- [x] Music live activity with visualizer 🎧
- [x] Calendar & Reminders integration 📆
- [x] Mirror widget 📷
- [x] Battery indicator & charging status 🔋
- [x] Customizable gesture controls 👆
- [x] Shelf with AirDrop & LocalSend support 📚
- [x] Notch sizing & multi-display support 🖥️
- [x] System HUD replacement (volume, brightness, backlight) 🎚️
- [x] Lock screen widgets 🔒
- [x] Download progress indicator 🌍
- [ ] Bluetooth live activity (connect/disconnect) 🎧
- [ ] Weather widget ⛅
- [ ] Customizable layout options 🛠️
- [ ] Extension system 🧩
- [ ] Notifications *(under consideration)* 🔔

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to get involved.

## Join the Discord

<a href="https://discord.gg/GvYcYpAKTu"><img src="https://iili.io/28m3GHv.png" alt="Join The Boring Server!" style="height: 60px !important;width: 217px !important;" /></a>

## Support

<a href="https://www.ko-fi.com/alexander5015"><img src="https://github.com/user-attachments/assets//a76175ef-7e93-475a-8b67-4922ba5964c2" alt="Support on Ko-fi" style="height: 70px !important;width: 346px !important;" /></a>

## Star History

<a href="https://www.star-history.com/#TheBoredTeam/boring.notch&Timeline">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=TheBoredTeam/boring.notch&type=Timeline&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=TheBoredTeam/boring.notch&type=Timeline" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=TheBoredTeam/boring.notch&type=Timeline" />
  </picture>
</a>

---

## Acknowledgments

- **[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)** — enabled Now Playing support on macOS 15.4+
- **[NotchDrop](https://github.com/Lakr233/NotchDrop)** — foundation for the Shelf feature
- Icon design: [@maxtron95](https://github.com/maxtron95)
- Website: [@himanshhhhuv](https://github.com/himanshhhhuv)

For full third-party licenses see [THIRD_PARTY_LICENSES.md](./THIRD_PARTY_LICENSES.md).
