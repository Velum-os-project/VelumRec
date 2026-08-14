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
# VelumRec - Recovery downloader
# Lives in the recovery partition, NOT in the main system.
# Called by C++ (recovery UI) when it detects a kernel version mismatch
# between the running beta and the stable release.
# Downloads either:
#   - The full stable ISO (iso=True)  → HolyC uses it to migrate the kernel
#   - Updated kernel modules only     → HolyC installs them without full migration
# Uses ctypes/libcurl — no requests library.

import ctypes
import ctypes.util
import hashlib
import json
import os
import stat

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
        raise RuntimeError("[downloader] libcurl init failed")
    try:
        _libcurl.curl_easy_setopt(handle, CURLOPT_URL, url.encode())
        _libcurl.curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, ctypes.c_long(1))
        _libcurl.curl_easy_setopt(handle, CURLOPT_TIMEOUT, ctypes.c_long(timeout))
        _libcurl.curl_easy_setopt(handle, CURLOPT_SSL_VERIFYPEER, ctypes.c_long(1))
        _libcurl.curl_easy_setopt(handle, CURLOPT_USERAGENT, b"velumrec/1.0")
        _libcurl.curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, _write)
        ret = _libcurl.curl_easy_perform(handle)
        if ret != 0:
            raise RuntimeError(f"[downloader] curl error {ret} fetching {url}")
        code = ctypes.c_long(0)
        _libcurl.curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, ctypes.byref(code))
        if code.value != 200:
            raise RuntimeError(f"[downloader] HTTP {code.value} for {url}")
    finally:
        _libcurl.curl_easy_cleanup(handle)
    return bytes(buf)

# ================================================================
# CONSTANTS
# TODO: replace with real Velum OS release URLs when repo is public
# ================================================================

RECOVERY_PATH = "/recovery"

# GitHub Releases API — returns latest stable release metadata
GITHUB_RELEASES_API = ("https://api.github.com/repos/"
                        "Velum-os-project/VelumOS/releases/latest")

# GitHub API for kernel modules directory in the latest stable release
GITHUB_MODULES_API  = ("https://api.github.com/repos/"
                        "Velum-os-project/VelumOS/contents/modules")

# ================================================================
# HELPERS
# ================================================================

def _verify_sha512(filepath: str, expected: str) -> bool:
    h = hashlib.sha512()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest() == expected


def _stream_to_file(url: str, dest: str, timeout: int = 300) -> None:
    """
    Downloads url to dest via libcurl streaming.
    Used for large files (ISO). Sets permissions to 0o600 after write.
    """
    print(f"[downloader] Downloading {os.path.basename(dest)}...")
    data = _curl_get(url, timeout=timeout)
    with open(dest, "wb") as f:
        f.write(data)
    os.chmod(dest, stat.S_IRUSR | stat.S_IWUSR)  # 0o600


def _get_latest_release() -> dict:
    """
    Queries GitHub Releases API and returns the latest stable release metadata.
    Returns dict with keys: tag_name, assets (list of {name, browser_download_url}).
    """
    raw = _curl_get(GITHUB_RELEASES_API, timeout=15)
    return json.loads(raw.decode())


def _find_asset(assets: list, suffix: str) -> dict:
    """
    Finds a release asset by filename suffix (e.g. '.iso', '.sha512').
    Raises RuntimeError if not found.
    """
    for asset in assets:
        if asset["name"].endswith(suffix):
            return asset
    raise RuntimeError(f"[downloader] No asset with suffix '{suffix}' in release.")

# ================================================================
# DOWNLOAD STABLE ISO
# Called by C++ when kernel migration is needed (iso=True in download()).
# Returns the path to the downloaded ISO for HolyC to use.
# ================================================================

def download_stable_iso(dest: str = RECOVERY_PATH) -> str:
    print("[downloader] Fetching latest stable release info...")
    release = _get_latest_release()
    tag     = release.get("tag_name", "unknown")
    assets  = release.get("assets", [])

    iso_asset      = _find_asset(assets, ".iso")
    checksum_asset = _find_asset(assets, ".sha512")

    iso_url      = iso_asset["browser_download_url"]
    checksum_url = checksum_asset["browser_download_url"]
    iso_name     = iso_asset["name"]

    iso_path      = os.path.join(dest, iso_name)
    checksum_path = iso_path + ".sha512"

    # Download checksum first
    print(f"[downloader] Downloading checksum for {iso_name}...")
    checksum_data = _curl_get(checksum_url, timeout=15)
    with open(checksum_path, "w") as f:
        f.write(checksum_data.decode().strip())

    # Download ISO
    _stream_to_file(iso_url, iso_path, timeout=600)

    # Verify
    expected = checksum_data.decode().strip().split()[0]
    print(f"[downloader] Verifying {iso_name} (SHA-512)...")
    if not _verify_sha512(iso_path, expected):
        os.remove(iso_path)
        os.remove(checksum_path)
        raise RuntimeError(f"[downloader] Checksum mismatch for {iso_name}. Aborted.")

    print(f"[downloader] ISO verified: {iso_name} ({tag})")
    return iso_path

# ================================================================
# DOWNLOAD UPDATED KERNEL MODULES
# Called by C++ when only module updates are needed (iso=False).
# Downloads only modules that differ from the currently running version.
# Returns the path to the directory containing the downloaded modules.
# ================================================================

def download_updated_modules(dest: str = RECOVERY_PATH) -> str:
    modules_dir = os.path.join(dest, "modules")
    os.makedirs(modules_dir, exist_ok=True)

    print("[downloader] Fetching module list from repo...")
    raw     = _curl_get(GITHUB_MODULES_API, timeout=15)
    entries = json.loads(raw.decode())

    # Filter to .ko files only
    modules = [e for e in entries if e["name"].endswith(".ko")]
    if not modules:
        raise RuntimeError("[downloader] No kernel modules found in repo.")

    # Read checksums file from repo root
    checksums_url  = GITHUB_MODULES_API.replace("/contents/modules",
                                                 "/raw/main/modules/checksums.txt")
    checksums_raw  = _curl_get(checksums_url, timeout=15)
    repo_checksums = {}
    for line in checksums_raw.decode().strip().splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            repo_checksums[parts[1].strip()] = parts[0].strip()

    downloaded = []
    for module in modules:
        name     = module["name"]
        url      = module["download_url"]
        expected = repo_checksums.get(name)

        # Compare against currently installed module if it exists
        installed_path = os.path.join("/lib/modules", name)
        if expected and os.path.isfile(installed_path):
            if _verify_sha512(installed_path, expected):
                print(f"[downloader] Up to date: {name} — skipping")
                continue

        dest_path = os.path.join(modules_dir, name)
        print(f"[downloader] Downloading module: {name}")
        data = _curl_get(url, timeout=60)
        with open(dest_path, "wb") as f:
            f.write(data)
        os.chmod(dest_path, stat.S_IRUSR | stat.S_IWUSR)

        if expected:
            if not _verify_sha512(dest_path, expected):
                os.remove(dest_path)
                raise RuntimeError(f"[downloader] Checksum mismatch for {name}. Aborted.")
            print(f"[downloader] Verified: {name}")

        downloaded.append(name)

    if not downloaded:
        print("[downloader] All modules are up to date. Nothing to download.")
    else:
        print(f"[downloader] Downloaded {len(downloaded)} module(s) to {modules_dir}")

    return modules_dir

# ================================================================
# ENTRY POINT — called by C++ via Cython FFI
# iso=True  → full ISO download for kernel migration (HolyC)
# iso=False → module updates only
# Returns the path C++ passes to HolyC.
# ================================================================

def download(iso: bool = False) -> str:
    if iso:
        return download_stable_iso()
    else:
        return download_updated_modules()
