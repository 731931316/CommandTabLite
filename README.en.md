# Qingyue (轻跃)

[简体中文](README.md) | English

![Qingyue icon](Assets/AppIcon-source.png)

Qingyue is a lightweight application and window switcher for macOS. It runs in the menu bar and offers a selection interface inspired by the native Command+Tab switcher. You can choose which applications appear and whether an application's windows are shown as separate entries.

## Features

- Uses **Control+Tab** by default. Set it to **Command+Tab** in settings to replace the system application switcher shortcut.
- Hold the modifier key and repeatedly press the main key to cycle through entries. Release the modifier to switch to the selected application or window. Press Shift to move backward.
- Hover over an entry to select it, click it to switch, or click outside the panel to cancel.
- Configure running applications in the Chinese settings interface: **Always show** (始终显示), **Show only when windows exist** (仅有窗口时显示), or **Exclude from switching** (不参与切换). Rules persist across restarts. Qingyue itself is always excluded.
- Enable **Split by window** (按窗口拆分) for individual applications. Each window then becomes a separate entry with its own position in the list.
- Multiple processes belonging to the same application share one settings row. With window splitting disabled, they share one switcher entry. With splitting enabled, windows from all processes are included. A process left running after its windows close does not add an extra entry. If all windows are closed, **Always show** keeps one application entry.
- **Show only when windows exist** requires at least one window that has not been closed. Minimized windows count as existing windows. These rules apply to all applications.
- Entries are ordered from left to right: non-minimized windows, minimized windows, then applications without windows. Within each group, entries follow actual recent usage. Split windows are tracked independently and can interleave with other applications. Mouse clicks and other focus changes also update usage, while an open switcher keeps its snapshot order. History starts when Qingyue launches; unvisited windows retain their relative fallback order. Qingyue can restore minimized windows and request that a running application reopen a window when none remain.
- Optionally launch automatically when you log in to your Mac.
- The login toggle reads existing system login items and avoids duplicate registration. Additional copies of Qingyue exit before taking over shortcuts. If Accessibility access is unavailable at startup, Qingyue retries automatically after permission is granted. Explicitly disabling the shortcut prevents automatic re-enabling during that session.

## Build and install

Requires macOS 13 or later and Xcode Command Line Tools. The project currently provides source code for local builds; no notarized installer has been released.

```sh
git clone https://github.com/731931316/CommandTabLite.git
cd CommandTabLite
./build.sh
ditto "轻跃.app" "/Applications/轻跃.app"
open "/Applications/轻跃.app"
```

`build.sh` creates `轻跃.app` in the project root and applies an ad hoc signature. On first launch, allow Qingyue in **System Settings → Privacy & Security → Accessibility**. macOS may require you to grant access again after rebuilding or moving the application.

For local development, reuse a signing certificate with `CODE_SIGN_IDENTITY="certificate name or SHA-1" ./build.sh`. Keeping the same certificate and installation path reduces permission churn caused by ad hoc signatures. Switching certificates may still require authorization. Development signing is not a notarized Developer ID release.

Legacy login items are detected through the public but deprecated `LSSharedFileList` compatibility API; new registrations use `SMAppService`. An incomplete login-item read produces a warning instead of blindly adding another registration.

Qingyue runs in the menu bar and does not have a regular Dock icon. Click the `⌘⇥` menu bar icon and choose **Settings…** to open the Chinese settings interface. The menu also includes **Enable shortcut**, **Disable shortcut**, and **Quit**.

## Command+Tab and recovery

When you select Command+Tab in settings, Qingyue disables the corresponding system switcher shortcuts and registers its own shortcut. It attempts to restore the system shortcuts when you choose a different shortcut or quit normally.

If Command+Tab is not restored after an unexpected exit, run this command in Terminal:

```sh
"/Applications/轻跃.app/Contents/MacOS/CommandTabLite" --restore-system-shortcuts
```

Shortcut replacement uses the macOS **SkyLight private API**, whose behavior may change with system updates. This source code and build script are intended for local use. The current version is not suitable for direct submission to the Mac App Store.

## Acknowledgments and license

The shortcut replacement approach was inspired by the open-source project [AltTab](https://github.com/lwouis/alt-tab-macos). Qingyue is licensed under the [MIT License](LICENSE).
