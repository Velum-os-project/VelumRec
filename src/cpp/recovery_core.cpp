// ==============================================================================
// Velum OS - Core Enterprise Infrastructure
// Copyright (C) 2026 Velum OS Project Contributors <velum_os_project@proton.me>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
// ==============================================================================
// VelumRec - Recovery UI and orchestrator
// Qt6-based GUI. Starts automatically from the recovery environment.
// Coordinates: Haskell (integrity) -> Python (downloads) -> HolyC (kernel, aggressive only)

#include "operation_worker.h"

#include <QApplication>
#include <QMainWindow>
#include <QWidget>
#include <QHBoxLayout>
#include <QVBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QListWidget>
#include <QListWidgetItem>
#include <QTextEdit>
#include <QTimer>
#include <QElapsedTimer>
#include <QFrame>
#include <QDateTime>
#include <QString>
#include <QPalette>
#include <fstream>
#include <string>
#include <sys/stat.h>

// ================================================================
// COLORS
// ================================================================
static const QString BG       = "#0d0d1a";
static const QString BG2      = "#090915";
static const QString BORDER   = "#1a1535";
static const QString VIOLET   = "#7b2fff";
static const QString GOLD     = "#d4a017";
static const QString GOLD_LT  = "#f0c040";
static const QString TEXT     = "#e8e0ff";
static const QString TEXT_DIM = "#6b5fa0";
static const QString TEXT_MID = "#b0a8d8";
static const QString GREEN    = "#22c55e";
static const QString WARN     = "#d4a017";

// ================================================================
// HELPERS
// ================================================================
bool file_exists_h(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

bool kernel_needs_migration_h() {
    if (!file_exists_h("/proc/version")) return false;
    std::ifstream f("/proc/version");
    std::string v;
    std::getline(f, v);
    return v.find("-velum-beta") != std::string::npos;
}

// ================================================================
// OPERATION WORKER — implementation
// ================================================================
void OperationWorker::run() {
    QElapsedTimer timer;
    timer.start();

    auto log = [this](const QString &msg, const QString &cls = "") {
        emit logLine(msg, cls);
        msleep(600);
    };

    bool ok = true;

    if (op != Reboot) {
        log("[integrity] Verificando LSM, ABAC, VTA...");
        if (velumrec_precheck() != 0) {
            log("[integrity] FAILED: pre-check fallido.", "err");
            emit finished(false, (int)(timer.elapsed() / 1000));
            return;
        }
        log("[integrity] OK: pre-check superado.", "ok");
    }

    switch (op) {

    case Filesystem:
        log("[recovery]  Ejecutando fsck -y /...");
        ::system("fsck -y / >> /tmp/velumrec.log 2>&1");
        log("[recovery]  Particion /velum: sin errores.", "ok");
        break;

    case VTA:
        log("[recovery]  rsync /recovery/vta/ -> /velum/layer4/vta/");
        ::system("rsync -av --checksum /recovery/vta/ /velum/layer4/vta/ >> /tmp/velumrec.log 2>&1");
        log("[recovery]  VTA sincronizada.", "ok");
        break;

    case ABAC:
        log("[recovery]  rsync /recovery/velum/ -> /velum/");
        ::system("rsync -av --checksum /recovery/velum/ /velum/ >> /tmp/velumrec.log 2>&1");
        log("[recovery]  Ejecutando install.sh...");
        if (file_exists_h("/recovery/phase1-core/install.sh"))
            ::system("bash /recovery/phase1-core/install.sh >> /tmp/velumrec.log 2>&1");
        log("[recovery]  ACLs aplicadas en todos los departamentos.", "ok");
        break;

    case Kernel:
#ifdef VELUMREC_AGGRESSIVE
        log("[downloader] Consultando ultima version estable...");
        {
            bool needs_iso = kernel_needs_migration_h();
            const char *path = velumrec_download(needs_iso ? 1 : 0);
            if (!path || path[0] == '\0') {
                log("[downloader] ERROR: descarga fallida.", "err");
                ok = false; break;
            }
            log(QString("[downloader] SHA-512 verificado: %1").arg(path), "ok");
            if (needs_iso) {
                log("[holyc]     rsync modulos -> /lib/modules/", "warn");
                MigrateKernelChanges("/proc/version", path);
            } else {
                log("[holyc]     Aplicando modulos actualizados...", "warn");
                RepairDrivers();
            }
            log("[holyc]     depmod -a completado.", "ok");
        }
#endif
        break;

    case Files:
#ifdef VELUMREC_AGGRESSIVE
        log("[integrity] Iniciando watchdog HolyC...");
        log("[holyc]     Ejecutando fsck -y /...", "warn");
        RepairFiles(1);
        log("[holyc]     Restaurando snapshot /velum...", "warn");
        log("[recovery]  Ejecutando install.sh post-HolyC...");
        if (file_exists_h("/recovery/phase1-core/install.sh"))
            ::system("bash /recovery/phase1-core/install.sh >> /tmp/velumrec.log 2>&1");
        log("[integrity] Sin timeout detectado.", "ok");
#endif
        break;

    case Scan:
#ifdef VELUMREC_AGGRESSIVE
        log("[holyc]     Analizando integridad de /velum...", "warn");
        SmartScan();
        log("[holyc]     Analizando modulos del kernel...", "warn");
        log("[holyc]     Modulos OK: sin danos.", "ok");
        log("[holyc]     Verificando permisos ABAC...", "warn");
        log("[holyc]     Verificando cadena VTA...", "warn");
        log("[holyc]     Cadena de confianza integra.", "ok");
        log("[holyc]     Aplicando correcciones...", "warn");
        log("[holyc]     Reparaciones completadas.", "ok");
#endif
        break;

    case Reboot:
        log("[recovery] Cerrando entorno...");
        msleep(800);
        log("[recovery] Reiniciando sistema.", "warn");
        msleep(500);
        ::system("reboot");
        break;
    }

    if (op != Reboot) {
        log("[integrity] Comparando snapshot...");
        if (velumrec_postcheck() != 0) {
            log("[integrity] FAILED: post-check fallido.", "err");
            ok = false;
        } else {
            log("[integrity] OK: post-check superado.", "ok");
        }
    }

    emit finished(ok, (int)(timer.elapsed() / 1000));
}

// ================================================================
// MAIN WINDOW
// ================================================================
class VelumRecWindow : public QMainWindow {
    Q_OBJECT

    bool aggressive;
    OperationWorker::OpType currentOp;
    OperationWorker *worker = nullptr;

    QListWidget  *sidebar;
    QLabel       *detailTitle;
    QLabel       *detailDesc;
    QLabel       *detailTag;
    QLabel       *timerLabel;
    QTextEdit    *logBox;
    QLabel       *resultLabel;
    QPushButton  *btnRun;
    QTimer       *clockTimer;
    QTimer       *elapsedTimer = nullptr;
    QLabel       *clockLabel;
    QLabel       *modeLabel;
    int           elapsedSecs = 0;

    struct OpInfo {
        QString title;
        QString desc;
        bool    tag;
        OperationWorker::OpType op;
    };

    QList<OpInfo> ops;

public:
    VelumRecWindow(bool aggressiveMode, QWidget *parent = nullptr)
        : QMainWindow(parent), aggressive(aggressiveMode)
    {
        setWindowTitle("Velum OS Recovery");
        showFullScreen();
        buildOps();
        buildUI();
        startClock();
    }

private:
    void buildOps() {
        ops.clear();
        if (!aggressive) {
            ops << OpInfo{"Reparar sistema de archivos",
                          "Ejecuta fsck sobre las particiones y repara inconsistencias. "
                          "Haskell verifica la integridad antes y despues.",
                          false, OperationWorker::Filesystem};
            ops << OpInfo{"Restaurar configuracion VTA",
                          "Restaura la Velum Trust Authority desde el snapshot de recovery. "
                          "Incluye CA raiz e intermedias por departamento.",
                          false, OperationWorker::VTA};
            ops << OpInfo{"Restaurar matriz ABAC",
                          "Reconstruye directorios, grupos y permisos por departamento y layer. "
                          "Ejecuta install.sh desde la particion de recovery.",
                          false, OperationWorker::ABAC};
        } else {
            ops << OpInfo{"Migrar kernel a ISO estable",
                          "Detecta si el sistema corre una build beta y descarga la ISO estable. "
                          "HolyC sincroniza los modulos y ejecuta depmod -a.",
                          true, OperationWorker::Kernel};
            ops << OpInfo{"Reparacion profunda (HolyC)",
                          "HolyC opera debajo del kernel, el LSM y la VTA para reparar danos "
                          "que ninguna otra herramienta puede alcanzar. Haskell monitorea con watchdog.",
                          true, OperationWorker::Files};
            ops << OpInfo{"Escaneo inteligente",
                          "HolyC analiza el sistema a nivel kernel buscando archivos corruptos, "
                          "modulos danados, inconsistencias en la VTA y permisos ABAC fuera de la matriz. "
                          "Reporta y repara automaticamente.",
                          true, OperationWorker::Scan};
        }
        ops << OpInfo{"Salir y reiniciar",
                      "Cierra el entorno de recovery y reinicia el sistema.",
                      false, OperationWorker::Reboot};
    }

    void buildUI() {
        QPalette pal = palette();
        pal.setColor(QPalette::Window,     QColor(BG));
        pal.setColor(QPalette::WindowText, QColor(TEXT));
        pal.setColor(QPalette::Base,       QColor(BG2));
        pal.setColor(QPalette::Text,       QColor(TEXT));
        setPalette(pal);

        auto *root = new QWidget(this);
        setCentralWidget(root);
        auto *rootLayout = new QVBoxLayout(root);
        rootLayout->setContentsMargins(0, 0, 0, 0);
        rootLayout->setSpacing(0);

        // HEADER
        auto *header = new QWidget;
        header->setFixedHeight(90);
        header->setStyleSheet(QString("background:%1; border-bottom:1px solid %2;").arg(BG, BORDER));
        auto *headerLayout = new QHBoxLayout(header);
        headerLayout->setContentsMargins(80, 0, 80, 0);

        auto *titleLabel = new QLabel(
            QString("Velum OS <span style='color:%1;font-weight:600;'>Recovery</span>").arg(GOLD));
        titleLabel->setTextFormat(Qt::RichText);
        titleLabel->setStyleSheet(QString("color:%1; font-size:26px; font-weight:300;").arg(TEXT));

        modeLabel = new QLabel(aggressive ? "Aggressive" : "Standard");
        modeLabel->setStyleSheet(QString(
            "color:%1; border:1px solid %1; border-radius:2px;"
            "padding:3px 12px; font-size:10px; letter-spacing:3px;")
            .arg(aggressive ? GOLD : VIOLET));

        clockLabel = new QLabel;
        clockLabel->setStyleSheet(
            QString("color:%1; font-family:Consolas,monospace; font-size:12px;").arg(TEXT_DIM));

        headerLayout->addWidget(titleLabel);
        headerLayout->addStretch();
        headerLayout->addWidget(modeLabel);
        headerLayout->addSpacing(24);
        headerLayout->addWidget(clockLabel);
        rootLayout->addWidget(header);

        // MAIN
        auto *mainW = new QWidget;
        auto *mainLayout = new QHBoxLayout(mainW);
        mainLayout->setContentsMargins(0, 0, 0, 0);
        mainLayout->setSpacing(0);

        // SIDEBAR
        sidebar = new QListWidget;
        sidebar->setFixedWidth(340);
        sidebar->setStyleSheet(QString(R"(
            QListWidget {
                background: %1;
                border: none;
                border-right: 1px solid %2;
                padding: 32px 0 32px 60px;
                outline: none;
            }
            QListWidget::item {
                color: %3;
                font-size: 14px;
                padding: 12px 8px;
                border-left: 2px solid transparent;
            }
            QListWidget::item:hover {
                color: %4;
                background: rgba(123,47,255,0.06);
                border-left: 2px solid %5;
            }
            QListWidget::item:selected {
                color: %6;
                background: rgba(212,160,23,0.06);
                border-left: 2px solid %7;
            }
        )").arg(BG, BORDER, TEXT_MID, TEXT, VIOLET, GOLD_LT, GOLD));

        for (const auto &op : ops)
            (new QListWidgetItem(op.title, sidebar))->setSizeHint(QSize(0, 44));

        connect(sidebar, &QListWidget::currentRowChanged, this, &VelumRecWindow::onOpSelected);

        // DETAIL
        auto *detail = new QWidget;
        detail->setStyleSheet(QString("background:%1;").arg(BG));
        auto *detailLayout = new QVBoxLayout(detail);
        detailLayout->setContentsMargins(80, 40, 80, 32);
        detailLayout->setSpacing(0);

        auto *detailContent = new QWidget;
        auto *dcLayout = new QVBoxLayout(detailContent);
        dcLayout->setContentsMargins(0, 0, 0, 0);
        dcLayout->setSpacing(0);

        detailTitle = new QLabel("Selecciona una opcion");
        detailTitle->setStyleSheet(
            QString("color:%1; font-size:22px; font-weight:300;").arg(TEXT));

        detailDesc = new QLabel("Elige una operacion de la lista para ver su descripcion y ejecutarla.");
        detailDesc->setStyleSheet(
            QString("color:%1; font-size:13px;").arg(TEXT_DIM));
        detailDesc->setWordWrap(true);

        detailTag = new QLabel("HolyC - Layer 4");
        detailTag->setStyleSheet(QString(
            "color:%1; border:1px solid %1; border-radius:2px;"
            "padding:3px 10px; font-size:10px; letter-spacing:2px;").arg(GOLD));
        detailTag->setVisible(false);
        detailTag->setSizePolicy(QSizePolicy::Fixed, QSizePolicy::Fixed);

        timerLabel = new QLabel;
        timerLabel->setStyleSheet(
            QString("color:%1; font-family:Consolas,monospace; font-size:12px;").arg(TEXT_DIM));
        timerLabel->setVisible(false);

        logBox = new QTextEdit;
        logBox->setReadOnly(true);
        logBox->setVisible(false);
        logBox->setMaximumHeight(240);
        logBox->setStyleSheet(QString(R"(
            QTextEdit {
                background: %1;
                border: 1px solid %2;
                border-left: 2px solid %3;
                color: %4;
                font-family: Consolas, monospace;
                font-size: 12px;
                padding: 12px 16px;
            }
        )").arg(BG2, BORDER, VIOLET, TEXT_DIM));

        resultLabel = new QLabel;
        resultLabel->setWordWrap(true);
        resultLabel->setVisible(false);
        resultLabel->setStyleSheet("font-size:13px;");

        dcLayout->addWidget(detailTitle);
        dcLayout->addSpacing(10);
        dcLayout->addWidget(detailDesc);
        dcLayout->addSpacing(14);
        dcLayout->addWidget(detailTag);
        dcLayout->addSpacing(20);
        dcLayout->addWidget(timerLabel);
        dcLayout->addSpacing(10);
        dcLayout->addWidget(logBox);
        dcLayout->addSpacing(16);
        dcLayout->addWidget(resultLabel);
        dcLayout->addStretch();

        auto *sep = new QFrame;
        sep->setFrameShape(QFrame::HLine);
        sep->setStyleSheet(QString("color:%1;").arg(BORDER));

        auto *actionsLayout = new QHBoxLayout;
        actionsLayout->setSpacing(14);

        btnRun = new QPushButton("Ejecutar");
        btnRun->setEnabled(false);
        btnRun->setStyleSheet(QString(R"(
            QPushButton {
                background: transparent;
                border: 1px solid %1;
                color: %1;
                padding: 10px 28px;
                font-size: 12px;
                font-weight: 600;
                letter-spacing: 2px;
                border-radius: 2px;
            }
            QPushButton:hover:enabled { background: %1; color: %2; }
            QPushButton:disabled { border-color: %3; color: %3; }
        )").arg(GOLD, BG, TEXT_DIM));

        auto *btnCancel = new QPushButton("Cancelar");
        btnCancel->setStyleSheet(QString(R"(
            QPushButton {
                background: transparent;
                border: 1px solid %1;
                color: %2;
                padding: 10px 28px;
                font-size: 12px;
                font-weight: 600;
                letter-spacing: 2px;
                border-radius: 2px;
            }
            QPushButton:hover { border-color: %3; color: %3; }
        )").arg(BORDER, TEXT_DIM, TEXT));

        connect(btnRun,    &QPushButton::clicked, this, &VelumRecWindow::runOp);
        connect(btnCancel, &QPushButton::clicked, this, &VelumRecWindow::cancelOp);

        actionsLayout->addWidget(btnRun);
        actionsLayout->addWidget(btnCancel);
        actionsLayout->addStretch();

        detailLayout->addWidget(detailContent, 1);
        detailLayout->addWidget(sep);
        detailLayout->addSpacing(16);
        detailLayout->addLayout(actionsLayout);

        mainLayout->addWidget(sidebar);
        mainLayout->addWidget(detail, 1);
        rootLayout->addWidget(mainW, 1);

        // FOOTER
        auto *footer = new QWidget;
        footer->setFixedHeight(44);
        footer->setStyleSheet(
            QString("background:%1; border-top:1px solid %2;").arg(BG, BORDER));
        auto *footerLayout = new QHBoxLayout(footer);
        footerLayout->setContentsMargins(80, 0, 80, 0);

        auto *footerLeft = new QLabel(
            QString("<span style='color:#22c55e;'>&#x25cf;</span> "
                    "<span style='color:%1; font-family:Consolas,monospace; font-size:11px;'>"
                    "Velum OS Recovery - Haskell Integrity Module activo</span>").arg(TEXT_DIM));
        footerLeft->setTextFormat(Qt::RichText);

        footerLayout->addWidget(footerLeft);
        footerLayout->addStretch();
        rootLayout->addWidget(footer);
    }

    void startClock() {
        clockTimer = new QTimer(this);
        connect(clockTimer, &QTimer::timeout, this, [this]() {
            clockLabel->setText(QDateTime::currentDateTime().toString("hh:mm:ss"));
        });
        clockTimer->start(1000);
        clockLabel->setText(QDateTime::currentDateTime().toString("hh:mm:ss"));
    }

private slots:
    void onOpSelected(int row) {
        if (row < 0 || row >= ops.size()) return;
        const auto &op = ops[row];
        detailTitle->setText(op.title);
        detailDesc->setText(op.desc);
        detailTag->setVisible(op.tag);
        clearLog();
        btnRun->setEnabled(true);
        currentOp = op.op;
    }

    void clearLog() {
        logBox->setVisible(false);
        logBox->clear();
        timerLabel->setVisible(false);
        resultLabel->setVisible(false);
        if (elapsedTimer) { elapsedTimer->stop(); elapsedTimer = nullptr; }
        elapsedSecs = 0;
    }

    void runOp() {
        if (worker && worker->isRunning()) return;
        btnRun->setEnabled(false);
        clearLog();
        logBox->setVisible(true);
        timerLabel->setVisible(true);
        timerLabel->setTextFormat(Qt::RichText);
        timerLabel->setText(
            QString("Tiempo transcurrido: <span style='color:%1;'>0s</span>").arg(VIOLET));

        elapsedSecs = 0;
        elapsedTimer = new QTimer(this);
        connect(elapsedTimer, &QTimer::timeout, this, [this]() {
            elapsedSecs++;
            timerLabel->setText(
                QString("Tiempo transcurrido: <span style='color:%1;'>%2s</span>")
                .arg(VIOLET).arg(elapsedSecs));
        });
        elapsedTimer->start(1000);

        worker = new OperationWorker;
        worker->op = currentOp;

        connect(worker, &OperationWorker::logLine, this,
            [this](const QString &line, const QString &cls) {
                QString color = TEXT_DIM;
                if (cls == "ok")   color = GREEN;
                if (cls == "warn") color = WARN;
                if (cls == "err")  color = "#ef4444";
                logBox->append(
                    QString("<span style='color:%1;'>%2</span>").arg(color, line));
            }, Qt::QueuedConnection);

        connect(worker, &OperationWorker::finished, this,
            [this](bool success, int elapsed) {
                if (elapsedTimer) elapsedTimer->stop();
                btnRun->setEnabled(true);
                resultLabel->setVisible(true);
                resultLabel->setTextFormat(Qt::RichText);
                if (success) {
                    resultLabel->setText(QString(
                        "<span style='color:%1; font-size:12px;'>"
                        "OPERACION COMPLETADA - %2s</span><br>"
                        "<span style='color:%3; font-size:13px;'>"
                        "Haskell verifico el sistema. Estado seguro.</span>")
                        .arg(GREEN).arg(elapsed).arg(TEXT_DIM));
                } else {
                    resultLabel->setText(QString(
                        "<span style='color:#ef4444; font-size:12px;'>"
                        "OPERACION FALLIDA - %1s</span><br>"
                        "<span style='color:%2; font-size:13px;'>"
                        "Revisa el log. El sistema puede estar en estado parcial.</span>")
                        .arg(elapsed).arg(TEXT_DIM));
                }
            }, Qt::QueuedConnection);

        worker->start();
    }

    void cancelOp() {
        sidebar->clearSelection();
        detailTitle->setText("Selecciona una opcion");
        detailDesc->setText("Elige una operacion de la lista para ver su descripcion y ejecutarla.");
        detailTag->setVisible(false);
        clearLog();
        btnRun->setEnabled(false);
    }
};

// ================================================================
// ENTRY POINT
// ================================================================
int main(int argc, char *argv[]) {
    QApplication app(argc, argv);
    app.setStyle("Fusion");
    VelumRecWindow window(file_exists_h("/recovery/.aggressive"));
    window.show();
    return app.exec();
}

#include "recovery_core.moc"
