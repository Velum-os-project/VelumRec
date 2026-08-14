// ==============================================================================
// Velum OS - Core Enterprise Infrastructure
// Copyright (C) 2026 Velum OS Project Contributors <velum_os_project@proton.me>
// AGPLv3 — see LICENSE
// ==============================================================================
// VelumRec - OperationWorker header
// Must be a separate header so MOC can process Q_OBJECT correctly.

#pragma once

#include <QThread>
#include <QString>
#include <QElapsedTimer>

extern "C" {
    int velumrec_precheck(void);
    int velumrec_postcheck(void);
    const char* velumrec_download(int iso);
}

#ifdef VELUMREC_AGGRESSIVE
extern "C" {
    void MigrateKernelChanges(const char *beta_path, const char *stable_path);
    void RepairDrivers(void);
    void RepairFiles(long auto_mode);
    void SmartScan(void);
}
#endif

bool file_exists_h(const char *path);
bool kernel_needs_migration_h(void);

class OperationWorker : public QThread {
    Q_OBJECT
public:
    enum OpType { Filesystem, VTA, ABAC, Kernel, Files, Scan, Reboot };
    OpType op;

signals:
    void logLine(const QString &line, const QString &cls);
    void finished(bool success, int elapsed);

protected:
    void run() override;
};
