<h1 align="center">
  <br>
  <a href="https://knotch.seshyweshyy.com"><img src="https://github.com/user-attachments/assets/1244e94f-c3e0-4b13-a7d4-7519f2fe023f" alt="Knotch" width="150"></a>
  <br>
  Knotch
  <br>
</h1>

<p align="center">
  <b>Knotch</b> is my personal fork of <a href="https://github.com/TheBoredTeam/boring.notch">boring.notch</a>, reworked to look and feel like it ships with macOS. I focus on the little details that separate something that fits from something that just works.
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/4f197948-8cec-4dfc-9127-df7380cb9e5a" alt="Demo GIF" />
</p>

---

## Images
<div align="center">
<img height="120" alt="Knotch Home View" src="https://github.com/user-attachments/assets/b0111f67-1c77-4f4e-8aad-3c5087cfb778" />
<img height="120" alt="Knotch Tray View" src="https://github.com/user-attachments/assets/4e86af18-221b-4178-b25d-2d142e89982c" />
<img height="450" alt="Screenshot 2026-04-25 at 7 01 15 pm" src="https://github.com/user-attachments/assets/560929f6-91df-4010-b0fc-8598667699ca" />
<img height="450" alt="Screenshot 2026-04-25 at 7 00 08 pm" src="https://github.com/user-attachments/assets/d1297e35-8653-414d-93df-becbf64f8f2d" />
</div>

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

<a href="https://github.com/seshyweshyy/knotch/releases/latest/download/Knotch.zip"><img width="200" src="https://github.com/user-attachments/assets/e3179be1-8416-4b8a-b417-743e1ecc67d6" alt="Download for macOS" /></a>

Unzip the `.zip` file and move **Knotch** to your `/Applications` folder.

> [!IMPORTANT]
> Knotch is not yet notarized. macOS will block it on first launch. Run this once to clear the quarantine flag, then open normally:
> ```bash
> xattr -dr com.apple.quarantine /Applications/Knotch.app
> ```
> Alternatively: open the app, dismiss the warning, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
><br><br>
> <img height="200" alt="Step 1" src="https://github.com/user-attachments/assets/b8775f40-4667-45c0-a585-1acce746b792" />
> <img height="300" alt="Step 2" src="https://github.com/user-attachments/assets/8087b8b8-e32f-4d60-a75a-68e08d95ade1" />
> <img height="300" alt="Step 3" src="https://github.com/user-attachments/assets/53ab3462-19d8-47b8-8daa-da202af0bbe4" />
> <br>
***Knotch does not contain any pieces of malware, and is intended to be a simple app.***

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
- [x] Bluetooth live activity (connect/disconnect) 🎧
- [ ] Lock screen widgets ⛅

---

## Acknowledgments

- **[Boring.Notch](https://github.com/TheBoredTeam/boring.notch)** - main source code
- **[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)** — enabled Now Playing support on macOS 15.4+
- **[NotchDrop](https://github.com/Lakr233/NotchDrop)** — foundation for the Shelf feature
- Website: [Knotch](https://knotch.seshyweshyy.com)
