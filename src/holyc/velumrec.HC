//==============================================================================
// Velum OS - Core Enterprise Infrastructure
// Copyright (C) 2026 Velum OS Project Contributors <velum_os_project@proton.me>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://gnu.org>.
// ==============================================================================
// VelumRec - HolyC Recovery Layer
// Internal library — called by C++ core, never directly by the admin.
// Aggressive mode only — Layer 4 authorization required.
//
// HolyC operates below the kernel, LSM, and VTA.
// It only executes what C++ tells it to — all control flow,
// authorization, integrity checks and ABAC restoration live in C++ and Haskell.

extern "c" I64 system(U8 *cmd);

// ================================================================
// 1. KERNEL MIGRATION
// Called by C++ when it detects a kernel version mismatch.
// C++ provides both paths after verifying them and running preCheck.
// stable_path is the path returned by Python's downloader.
// ================================================================

U0 MigrateKernelChanges(U8 *beta_path, U8 *stable_path)
{
    U8 cmd[512];

    // Sync kernel modules from stable ISO to live system
    StrPrint(cmd, "rsync -av --checksum %s/lib/modules/ /lib/modules/",
             stable_path);
    system(cmd);

    // Rebuild module dependency tree
    system("depmod -a");
}

// ================================================================
// 2. DRIVER REPAIR
// Called by C++ when updated modules were downloaded.
// Probes each .ko in /lib/modules that modinfo can read.
// ================================================================

U0 RepairDrivers()
{
    system("find /lib/modules -name '*.ko' | while read m; do "
           "modinfo $m > /dev/null 2>&1 || "
           "modprobe $(basename $m .ko); done");
}

// ================================================================
// 3. FILE REPAIR
// Called by C++ with auto_mode already resolved from admin selection.
// Only runs fsck and restores /velum snapshot.
// ABAC permission restoration (install.sh) is handled by C++ after
// this returns — HolyC does not call orchestration scripts.
// ================================================================

U0 RepairFiles(I64 auto_mode)
{
    if (auto_mode) {
        system("fsck -y /");
        system("rsync -av --checksum /recovery/velum/ /velum/");
    }
}
