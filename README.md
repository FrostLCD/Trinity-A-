# Trinity A+
### (This project is currently being maintained by a single developer. If you want to help, click the heart icon button and make a donation.)
### Important note: On x86_64, the maximum supported version of bedrock is 26.50.4
If you have an ARM-based device, you won't have any problems with the new versions.

[Official Website](https://trinity-la.github.io/)

[Official  Reddit](https://www.reddit.com/r/TrinityUnix/comments/1s3p2ot/errores_comunes_de_trinity_launcher/)

[![Version](https://img.shields.io/badge/version-9.0.9-blue)]()
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)]()
[![License](https://img.shields.io/badge/license-BSD--3--Clause-green)]()

**Trinity A+** is a modular graphical environment designed to manage and run Minecraft: Bedrock Edition natively on Linux environments.

This application is a fork of Trinity Launcher developed with vibe coding, focused on a polished Linux Bedrock experience and Flatpak-first distribution.
<img width="1024" height="740" alt="image psd" src="https://github.com/user-attachments/assets/b505c732-1d44-426d-a538-4c05d82cee18" />


---

### Key Features
* **Multi-version Management:** Extracts and organizes different versions of the game (APKs).
* **Content Manager (Trinito):** Centralized interface for Mods, Textures, Shaders, and Worlds.
* **Native Integration:** Support for Flatpak and native execution.
* **Discord Integration:** Rich Presence implemented natively with separate original and A+ community links.
* **APK discovery:** Quick links to mcpehub.org and mcpelife.com from the main dashboard.

---

### How does it work?
**Trinity A+** is a *frontend* designed to improve the management and usability of **Minecraft: Bedrock Edition** on Linux systems.

> **Special Acknowledgments:** Trinity A+ is built upon the technical foundation of the [mcpelauncher-manifest](https://github.com/minecraft-linux) project.

---

## Installation

### Flatpak

Trinity A+ is distributed exclusively as a Flatpak:

```bash
flatpak-builder --user --install --force-clean build-dir com.frostlcd.trinityaplus.yml
flatpak run com.frostlcd.TrinityAPlus
```

Once a published repository build is available, the SDK is not required. Download
[`com.frostlcd.trinityaplus.flatpakref`](com.frostlcd.trinityaplus.flatpakref) and run:

```bash
flatpak install --user ./com.frostlcd.trinityaplus.flatpakref
flatpak run com.frostlcd.TrinityAPlus
```

### Method from source code
If you wish to compile the latest version from the repository:

1. **Clone the project:**
   ```bash
   git clone https://github.com/Trinity-LA/Trinity-Launcher.git
   cd Trinity-Launcher
   ```
2. **Install dependencies and compile:**
   ```bash
   chmod +x build.sh && ./build.sh --deps 
   ```

*(For a detailed guide, refer to [docs/BUILD.md](docs/BUILD.md))*

if you wanna use nix run only for test compile:
``` 
nix --extra-experimental-features "nix-command flakes" develop
```

---

## Technical Architecture

The project is divided into two main libraries:
- **`TrinityCore`**: File management logic, configuration, and communication with the Bedrock runtime.
- **`TrinityUI`**: User interface based on Qt6.

---

## Contributions
Contributions are welcome! Please read our [Contribution Guide](CONTRIBUTING.md) before opening a *Pull Request*.

---
