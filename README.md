<h1 align="center">
  <br>
  <a href="https://knotch.seshyweshyy.com"><img src="https://github.com/user-attachments/assets/1244e94f-c3e0-4b13-a7d4-7519f2fe023f" alt="Knotch" width="150"></a>
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
- Screen lock icon and notch lock protection
- Music widget displayed over the lock screen with selectable glass style
- Expanded album art background

**Customization**
- Notch size modes: match real notch, match menu bar, or fully custom
- Corner radius scaling, window shadow, accent color
- Emoji display, settings icon in notch, face animation when idle
- Keyboard shortcuts for sneak peek and open/close toggle
- Works on both notch and non-notch displays; multi-display aware

---

## System Requirements

- macOS **14 Sonoma** or later (may require macOS **26** for Liquid Glass features)
- Apple Silicon or Intel Mac

---

## Installation

### Download Manually

<a href="https://github.com/seshyweshyy/knotchapp/releases/latest/download/Knotch.zip"><img width="200" src="https://github.com/user-attachments/assets/e3179be1-8416-4b8a-b417-743e1ecc67d6" alt="Download for macOS" /></a>

Unzip the `.zip` file and move **Knotch** to your `/Applications` folder.

> [!IMPORTANT]
> Knotch is not yet notarized. macOS will block it on first launch. Run this once to clear the quarantine flag, then open normally:
> ```bash
> xattr -dr com.apple.quarantine /Applications/Knotch.app
> ```
> Alternatively: open the app, dismiss the warning, then go to **System Settings → Privacy & Security** and click **Open Anyway**. (This method doesn't work for all users.)

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
- [x] Customizable layout options 🛠️
- [ ] Download progress indicator 🌍
- [ ] Bluetooth live activity (connect/disconnect) 🎧
- [ ] Weather widget ⛅
- [ ] Extension system 🧩
- [ ] Notifications *(under consideration)* 🔔

---

## Acknowledgments

- **[Boring.Notch](https://github.com/TheBoredTeam/boring.notch)** - main source code
- **[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)** — enabled Now Playing support on macOS 15.4+
- **[NotchDrop](https://github.com/Lakr233/NotchDrop)** — foundation for the Shelf feature
- Website: [@seshyweshyy](https://github.com/seshyweshyy)
