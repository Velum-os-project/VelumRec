# cython: language_level=3
# ==============================================================================
# Velum OS - Core Enterprise Infrastructure
# Copyright (C) 2026 Velum OS Project Contributors <velum_os_project@proton.me>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://gnu.org>.
# ==============================================================================
# VelumRec - CLI entry point (compiled with Cython)
# Installed by .deb into /velum/{dept}/layer{N}/velumrec
# Handles: --install, --install --aggressive, --reboot
# Downloads recovery files from GitHub, prepares partition, registers GRUB entry.
# Uses ctypes/libcurl — no requests, no subprocess.

import ctypes
import ctypes.util
import hashlib
import json
import os
import stat
import sys

# ================================================================
# libcurl via ctypes
# ================================================================

_libcurl = ctypes.CDLL(ctypes.util.find_library("curl"), use_errno=True)
_libcurl.curl_easy_init.restype      = ctypes.c_void_p
_libcurl.curl_easy_cleanup.argtypes  = [ctypes.c_void_p]
_libcurl.curl_easy_setopt.restype    = ctypes.c_int
_libcurl.curl_easy_perform.argtypes  = [ctypes.c_void_p]
_libcurl.curl_easy_perform.restype   = ctypes.c_int
_libcurl.curl_easy_getinfo.restype   = ctypes.c_int

CURLOPT_URL            = 10002
CURLOPT_WRITEFUNCTION  = 20011
CURLOPT_FOLLOWLOCATION = 52
CURLOPT_TIMEOUT        = 13
CURLOPT_SSL_VERIFYPEER = 64
CURLOPT_USERAGENT      = 10018
CURLINFO_RESPONSE_CODE = 0x200002

_WRITE_FUNC = ctypes.CFUNCTYPE(ctypes.c_size_t,
                                ctypes.c_void_p,
                                ctypes.c_size_t,
                                ctypes.c_size_t,
                                ctypes.c_void_p)


def _curl_get(url: str, timeout: int = 30) -> bytes:
    buf = bytearray()

    @_WRITE_FUNC
    def _write(ptr, size, nmemb, _):
        data = ctypes.string_at(ptr, size * nmemb)
        buf.extend(data)
        return size * nmemb

    handle = _libcurl.curl_easy_init()
    if not handle:
        raise RuntimeError("[velumrec] libcurl init failed")
    try:
        _libcurl.curl_easy_setopt(handle, CURLOPT_URL, url.encode())
        _libcurl.curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, ctypes.c_long(1))
        _libcurl.curl_easy_setopt(handle, CURLOPT_TIMEOUT, ctypes.c_long(timeout))
        _libcurl.curl_easy_setopt(handle, CURLOPT_SSL_VERIFYPEER, ctypes.c_long(1))
        _libcurl.curl_easy_setopt(handle, CURLOPT_USERAGENT, b"velumrec/1.0")
        _libcurl.curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, _write)
        ret = _libcurl.curl_easy_perform(handle)
        if ret != 0:
            raise RuntimeError(f"[velumrec] curl error {ret} fetching {url}")
        code = ctypes.c_long(0)
        _libcurl.curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, ctypes.byref(code))
        if code.value != 200:
            raise RuntimeError(f"[velumrec] HTTP {code.value} for {url}")
    finally:
        _libcurl.curl_easy_cleanup(handle)
    return bytes(buf)

# ================================================================
# CONSTANTS
# ================================================================

RECOVERY_PATH = "/recovery"
GRUB_SCRIPT   = "/etc/grub.d/42_velumrec"

GITHUB_API = {
    False: "https://api.github.com/repos/Velum-os-project/VelumRec/contents/standard",
    True:  "https://api.github.com/repos/Velum-os-project/VelumRec/contents/aggressive",
}
GITHUB_RAW = {
    False: "https://raw.githubusercontent.com/Velum-os-project/VelumRec/main/standard",
    True:  "https://raw.githubusercontent.com/Velum-os-project/VelumRec/main/aggressive",
}

GRUB_ENTRY = """\
menuentry "VelumRec Recovery" {
    search --no-floppy --label --set=root VelumRec
    linux /vmlinuz recovery=1
    initrd /initrd.img
}
"""

# ================================================================
# HELPERS
# ================================================================

def _get_velum_group() -> tuple:
    """
    Reads the velum_{dept}_layer{N} group of the current user.
    Returns (department, layer) or raises SystemExit if not found.
    """
    import grp
    groups = [grp.getgrgid(g).gr_name for g in os.getgroups()]
    velum_groups = [g for g in groups if g.startswith("velum_") and "_layer" in g]
    if not velum_groups:
        print("[velumrec] Error: current user does not belong to any velum group.")
        raise SystemExit(1)
    # Use the highest layer group available
    velum_groups.sort(key=lambda g: int(g.split("_layer")[1]))
    group = velum_groups[-1]
    dept  = group.split("_layer")[0].replace("velum_", "")
    layer = int(group.split("_layer")[1])
    return dept, layer


def _get_vta_log_dir(dept: str) -> str:
    return f"/velum/{dept}/layer4/vta/logs"


def _vta_log(event: str, dept: str) -> None:
    log_dir = _get_vta_log_dir(dept)
    os.makedirs(log_dir, exist_ok=True)
    logfile = os.path.join(log_dir, "velumrec_audit.log")
    with open(logfile, "a") as f:
        f.write(f"[velumrec] {event}\n")
    os.system(f"gpg --batch --yes --clearsign --output {logfile}.sig {logfile} 2>/dev/null")


def _get_checksums(aggressive: bool) -> dict:
    url = f"{GITHUB_RAW[aggressive]}/checksums.txt"
    print("[velumrec] Downloading checksums.txt...")
    raw = _curl_get(url, timeout=15)
    result = {}
    for line in raw.decode().strip().splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            result[parts[1].strip()] = parts[0].strip()
    return result


def _get_file_list(aggressive: bool) -> list:
    raw = _curl_get(GITHUB_API[aggressive], timeout=15)
    entries = json.loads(raw.decode())
    return [
        {"name": e["name"], "url": e["download_url"]}
        for e in entries
        if e["type"] == "file" and e["name"] != "checksums.txt"
    ]


def _download_file(url: str, dest: str) -> None:
    print(f"[velumrec] Downloading {os.path.basename(dest)}...")
    data = _curl_get(url, timeout=60)
    with open(dest, "wb") as f:
        f.write(data)
    os.chmod(dest, stat.S_IRWXU)


def _verify_sha512(filepath: str, expected: str) -> bool:
    h = hashlib.sha512()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest() == expected


def _write_grub_script() -> None:
    with open(GRUB_SCRIPT, "w") as f:
        f.write("#!/bin/sh\n")
        f.write(f"cat << 'GRUBEOF'\n{GRUB_ENTRY}\nGRUBEOF\n")
    os.chmod(GRUB_SCRIPT, 0o755)
    os.system("update-grub 2>/dev/null")
    print("[velumrec] GRUB entry registered.")

# ================================================================
# MODES
# ================================================================

def _install(aggressive: bool) -> None:
    if os.geteuid() != 0:
        print("[velumrec] Error: --install requires root.")
        raise SystemExit(1)

    dept, layer = _get_velum_group()
    required = 4 if aggressive else 3
    if layer < required:
        print(f"[velumrec] Error: {'--aggressive requires Layer 4' if aggressive else '--install requires Layer 3 or above'}.")
        print(f"           Current layer: {layer}")
        raise SystemExit(1)

    if aggressive:
        import getpass
        user = getpass.getuser()
        _vta_log(f"AGGRESSIVE mode activated by user={user} dept={dept} layer={layer}", dept)
        print("[velumrec] WARNING: Aggressive mode activates the HolyC layer.")
        print("           This layer operates below the kernel, LSM, and VTA.")
        print("           This activation has been logged and GPG-signed by the VTA.")
        print("           Proceeding in 3 seconds...")
        import time
        time.sleep(3)

    os.makedirs(RECOVERY_PATH, exist_ok=True)
    checksums = _get_checksums(aggressive)
    files     = _get_file_list(aggressive)

    for entry in files:
        dest = os.path.join(RECOVERY_PATH, entry["name"])
        _download_file(entry["url"], dest)
        expected = checksums.get(entry["name"])
        if not expected:
            print(f"[velumrec] WARNING: no checksum for {entry['name']} — skipping verify")
            continue
        if _verify_sha512(dest, expected):
            print(f"[velumrec] Verified: {entry['name']}")
        else:
            print(f"[velumrec] ERROR: checksum mismatch for {entry['name']}. Aborting.")
            os.remove(dest)
            raise SystemExit(1)

    print(f"[velumrec] Recovery files written to {RECOVERY_PATH}")
    _write_grub_script()
    print("[velumrec] Installation complete. Run 'velumrec --reboot' when ready.")


def _reboot() -> None:
    if os.geteuid() != 0:
        print("[velumrec] Error: --reboot requires root.")
        raise SystemExit(1)

    _, layer = _get_velum_group()
    if layer < 3:
        print("[velumrec] Error: --reboot requires Layer 3 or above.")
        print(f"           Current layer: {layer}")
        raise SystemExit(1)

    if not os.path.isdir(RECOVERY_PATH):
        print(f"[velumrec] Error: recovery partition not found at {RECOVERY_PATH}.")
        print("           Run 'velumrec --install' first.")
        raise SystemExit(1)

    print("[velumrec] Rebooting into recovery mode...")
    ret = os.system("grub-reboot 'VelumRec Recovery' 2>/dev/null")
    if ret != 0:
        print("[velumrec] Warning: grub-reboot failed. Select recovery from GRUB manually.")
    os.system("reboot")

# ================================================================
# ENTRY POINT
# ================================================================

def main() -> None:
    args = sys.argv[1:]

    if not args:
        print("Usage:")
        print("  velumrec --install               Standard recovery setup (Layer 3+)")
        print("  velumrec --install --aggressive  Full setup with HolyC (Layer 4 only)")
        print("  velumrec --reboot                Reboot directly into recovery (Layer 3+)")
        raise SystemExit(1)

    flag_install    = "--install"    in args
    flag_aggressive = "--aggressive" in args
    flag_reboot     = "--reboot"     in args

    unknown = [a for a in args if a not in ("--install", "--aggressive", "--reboot")]
    if unknown:
        print(f"[velumrec] Unknown argument: {unknown[0]}")
        raise SystemExit(1)

    if flag_aggressive and not flag_install:
        print("[velumrec] Error: --aggressive requires --install.")
        raise SystemExit(1)

    if flag_reboot and flag_install:
        print("[velumrec] Error: --reboot and --install cannot be used together.")
        raise SystemExit(1)

    if flag_reboot:
        _reboot()
    elif flag_install:
        _install(flag_aggressive)


if __name__ == "__main__":
    main()
