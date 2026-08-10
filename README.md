# VelumRec

> Enterprise recovery tool for Velum OS. When the OS can't fix itself, VelumRec can.

VelumRec is the official recovery package for Velum OS. It operates at a lower level than the kernel, the LSM, and the VTA — giving administrators the ability to repair damage that no other tool can reach.

---

## Installation

```bash
apt install velum-rec
```

Then initialize the recovery partition:

```bash
# Standard mode — safe by default
# Layer 3 or above required to authorize installation on lower layers
velumrec --install

# Aggressive mode — includes HolyC layer
# Only Layer 4 can authorize this installation
# The VTA logs who activated this mode and when, signed with GPG
velumrec --install --aggressive
```

`--install` connects to the official VelumRec GitHub repository to download the recovery files not included in the `.deb`. This keeps the package lightweight and ensures the latest recovery tools are always used.

---

## Usage

```bash
# Reboot directly into recovery mode (no GRUB menu needed)
velumrec --reboot
```

---

## What it can do in recovery mode

- Repair the filesystem
- Restore VTA configuration if corrupted
- Recover access if credentials were lost
- Verify LSM integrity
- Repair the `/velum` directory matrix and ABAC permissions if damaged

---

## Modes

### Standard (`--install`)
Safe by default. Does not include HolyC. Recommended for all deployments. Layer 3 or above required to authorize installation on lower layers.

### Aggressive (`--install --aggressive`)
Includes the HolyC layer, which operates deeper than C, deeper than the kernel, the LSM, and the VTA. This allows repairing damage that no other layer can reach — but a vulnerability at this level would invalidate all security layers above it.

For this reason:
- Only **Layer 4** can authorize this installation
- The VTA **logs every activation** with a GPG-signed timestamp
- The admin explicitly accepts the risk

---

## Architecture

VelumRec is a hybrid project:

- **C++** — core orchestration logic
- **Python (compiled with Cython)** — GitHub download and verification, general coordination
- **Haskell** — integrity verification logic and handler of posible errors
- **HolyC (TempleOS)** — deepest recovery layer, aggressive mode only

---

## License

Licensed under the **GNU Affero General Public License v3.0 (AGPLv3)**.

See [LICENSE](LICENSE) or visit [https://www.gnu.org/licenses/agpl-3.0.html](https://www.gnu.org/licenses/agpl-3.0.html).

---

## Contributing

Use an anonymous GitHub handle and encrypted email when contributing.

Contact: velum_os_project@proton.me



