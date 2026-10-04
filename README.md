<div align="center">

  ### 👇
  
  <p>
    <a href="https://github.com/EXLOUD/Render-Switcher/releases/download/v1.0.1/Render_Switcher_v1.0.1.zip">
      <img src="https://img.shields.io/badge/Download_Render_Switcher-2ea44f?style=flat&logo=download&logoColor=white" height="40" alt="Download Render Switcher">
    </a>
  </p>

  ---
  
  ### 👀 Repository Stats
  
   <img alt="GitHub Views" src="https://count.getloli.com/get/@:EXLOUD-Render-Switcher?theme=rule34" />

   **⭐ If this tool helped you, please consider giving it a star! ⭐**

</div>

---

<div align="center">

  <img src="assets/webui-vulkan.png" width="300" alt="Render Switcher WebUI — Vulkan">
  <img src="assets/webui-opengl.png" width="300" alt="Render Switcher WebUI — OpenGL">

  <h1>Render Switcher</h1>

  **Language:** [English](#) | [Українська](README-UK.md)

  ![Version](https://img.shields.io/badge/Version-v1.0.1-6d4dee?style=for-the-badge)
  ![Root](https://img.shields.io/badge/Magisk%20%7C%20KernelSU%20%7C%20APatch-222222?style=for-the-badge)
  ![Zygisk](https://img.shields.io/badge/Zygisk-required-success?style=for-the-badge)
  ![Architecture](https://img.shields.io/badge/ABI-arm64--v8a%20%7C%20armeabi--v7a%20%7C%20x86%20%7C%20x86__64-blue?style=for-the-badge)

  Per-app HWUI renderer control (Vulkan / OpenGL) for rooted Android devices.
  Pick the global renderer once, then override it for individual apps.

</div>

---

**Author:** EXLOUD  
**GitHub:** https://github.com/EXLOUD

## 📋 Description

Render Switcher lets you choose which HWUI rendering backend Android uses: **Vulkan** (`skiavk`) or **OpenGL** (`skiagl`).

- A **global default** is applied at boot for every app.
- **Per-app overrides** let you run selected apps on the other renderer, without touching the rest of the system.

Everything can be managed from the built-in **WebUI** or from the **`skiactl`** command line tool.

## 🔧 Requirements

- **Root:** Magisk, KernelSU or APatch
- **Zygisk:** enabled (Magisk built-in Zygisk) or a Zygisk implementation such as Zygisk Next / ReZygisk / NeoZygisk (KernelSU, APatch)
- **Architecture:** arm64-v8a, armeabi-v7a, x86, x86_64

## 🚀 Installation

1. Open your root manager (Magisk / KernelSU / APatch)
2. Install `Render_Switcher_v1.0.0.zip` as a module
3. Make sure **Zygisk is enabled**
4. Reboot
5. Open the module's **WebUI** and add the apps you want to override

## ⚙️ How it works

| Layer | Role |
|-------|------|
| **Global default** | `post-fs-data` sets `debug.hwui.renderer` early in boot (default: `skiavk`) |
| **Per-app** | The Zygisk module patches the renderer properties in the app's **private copy-on-write property page(s)** right after specialize. The shared system property area is never modified, and no PLT hooks are used. |

Only packages listed in `targets.conf` are touched. Apps that are not targets are left alone and produce no log lines.

## 🖥️ WebUI

- **Dashboard:** global renderer switch, system options and a log of recent events
- **Packages:** searchable list of apps (User / System / All) with a renderer picker per app: *Default*, *Vulkan* or *OpenGL*
- English and Ukrainian interface
- System option **Always GPU screen composition** (`persist.skia.force_gpu`)

Open it from your root manager's module list.

## 💻 CLI

```sh
/data/adb/modules/render_switcher/bin/skiactl status
```

| Command | Description |
|---------|-------------|
| `skiactl status` | Show global renderer, paths and targets |
| `skiactl renderer get` | Print the global renderer |
| `skiactl renderer set <skiavk\|skiagl>` | Set the global renderer |
| `skiactl target list` | List per-app targets |
| `skiactl target add <pkg> <renderer>` | Add an app override |
| `skiactl target set <pkg> <renderer>` | Change an app's renderer |
| `skiactl target get <pkg>` | Show an app's renderer and state |
| `skiactl target enable\|disable <pkg>` | Toggle an override without removing it |
| `skiactl target remove <pkg>` | Remove an app override |
| `skiactl zygisk` | Check that Zygisk is active (`ok` / `missing`) |
| `skiactl logs` | Show module logs |
| `skiactl packages [user\|system\|all]` | List installed packages |

Example:

```sh
skiactl target add com.example.game skiagl
skiactl renderer set skiavk
```

The target app is force-stopped automatically, so the new renderer is used on its next launch.

## 📁 Configuration

Data is stored outside the module folder and survives module updates:

```
/data/adb/render_switcher/
├── config/
│   ├── targets.conf      # package=renderer
│   └── settings.conf     # GLOBAL_RENDERER=skiavk
├── state/
├── locks/
└── render_switcher.log
```

`targets.conf` format:

```
com.example.game=skiagl
com.example.app=skiavk
```

Allowed renderers: `skiavk` | `skiagl`.

## 📦 Module structure

```
📄 module.prop
📄 customize.sh           # Installer
📄 post-fs-data.sh        # Early boot: global renderer
📄 service.sh             # Late boot
📄 uninstall.sh           # Full cleanup
📂 bin/skiactl            # CLI
📂 common/                # Shell libraries
📂 scripts/boot.sh        # Boot logic
📂 config/                # Default configuration
📂 webroot/               # WebUI
📂 zygisk/                # Native module sources + build scripts
📂 docs/
📂 tests/                # Mock environment + tests
```

## 🛡️ Safety

- **Bootloop guard:** if the device fails to finish booting several times in a row, the module disables enforcement automatically instead of keeping you stuck.
- **Uninstall:** removing the module deletes `/data/adb/render_switcher` (targets, settings, logs) and resets the module's runtime properties.
- **Manual disable:** create a `disable` file in the module folder, or turn the module off in your root manager.

## ⚠️ Important notes

- Use at your own risk. Not every app or GPU driver behaves well on both renderers, so switch one app at a time.
- Changing an override takes effect when the app is **restarted**.
- A reboot is recommended after installing or updating the module.

## 🆘 Troubleshooting

**Per-app override is not applied**
- Make sure Zygisk is enabled: `skiactl zygisk` should print `ok`
- Check that the app is listed and enabled: `skiactl target get <pkg>`
- Restart the app, then check `skiactl logs`

**Global renderer is wrong after boot**
- Run `skiactl renderer get` and check `skiactl logs`
- If the bootloop guard has triggered, enforcement is disabled until the module is reinstalled

**WebUI shows "WebUI bridge unavailable"**
- Open the WebUI from KernelSU, APatch or Magisk's module screen, not from a regular browser

## 🔨 Building from source

This is the full source tree. The release ZIP additionally contains the compiled `zygisk/<abi>.so` libraries, which are **not** included here.

**Requirements:** Android NDK r25+, CMake 3.18+ (Linux / macOS / WSL / Windows)

```sh
cd zygisk
export ANDROID_NDK_HOME=$HOME/Android/Sdk/ndk/27.0.12077973   # your NDK path
./build.sh                          # all ABIs
./build.sh arm64-v8a armeabi-v7a    # selected ABIs only
```

On Windows use `build.bat`. The build writes `zygisk/arm64-v8a.so`, `armeabi-v7a.so`, `x86.so` and `x86_64.so`.

**Packaging:** zip the module root (`module.prop` must be at the top level of the archive) and install it in your root manager. For a release build you can strip the libraries first (`strip --strip-unneeded`) and drop `tests/`, `scripts/check.sh` and the `zygisk/` sources/build scripts from the archive.

Details: [`zygisk/BUILD.md`](zygisk/BUILD.md), [`docs/RENDERER_ISOLATION_V1_0_0.md`](docs/RENDERER_ISOLATION_V1_0_0.md), [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

**Checks (host or device):**

```sh
sh scripts/check.sh        # static checks
sh tests/test_targets.sh   # targets manager tests with mocked environment
```

## 📞 Support

- **GitHub:** https://github.com/EXLOUD

---

<div align="center">

**Warning:** This module changes system graphics properties. Make sure you understand the consequences before use.

**[⬆ Back to Top](#render-switcher)**

</div>
