#!/bin/bash
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
# VelumRec - build.sh
# Códigos de error:
#   E01 - cython3 no encontrado
#   E02 - gcc no encontrado
#   E03 - g++ no encontrado
#   E04 - ghc no encontrado
#   E05 - moc no encontrado
#   E06 - Qt6 headers no encontrados
#   E07 - Python 3.13 headers no encontrados
#   E08 - Fallo compilando downloader.py (Cython)
#   E09 - Fallo compilando downloader (GCC)
#   E10 - Fallo compilando Integrity.hs (GHC)
#   E11 - Fallo MOC en operation_worker.h
#   E12 - Fallo MOC en recovery_core.cpp
#   E13 - Fallo compilando recovery_core_standard (G++)
#   E14 - holyc-lang no encontrado
#   E15 - Fallo compilando velumrec.HC (holyc-lang)
#   E16 - Fallo compilando recovery_core_aggressive (G++)
#
# Uso:
#   bash build.sh            -> compila standard y aggressive
#   bash build.sh standard   -> solo standard
#   bash build.sh aggressive -> solo aggressive
# ==============================================================================

MODE=${1:-all}
LOG="build/build.log"
ERRORS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ================================================================
# BARRA DE PROGRESO REAL — corre en background mientras compila
# ================================================================
spinner_pid=""

start_progress() {
    local label="$1"
    local cols=30
    printf "${CYAN}%-40s${NC} [" "$label"
    (
        i=0
        while true; do
            filled=$((i % (cols + 1)))
            empty=$((cols - filled))
            bar=$(printf '#%.0s' $(seq 1 $filled 2>/dev/null))
            spaces=$(printf ' %.0s' $(seq 1 $empty 2>/dev/null))
            pct=$(( (filled * 100) / cols ))
            printf "\r${CYAN}%-40s${NC} [${GREEN}%s%s${NC}] %3d%%" \
                "$label" "$bar" "$spaces" "$pct"
            i=$((i + 1))
            sleep 0.08
        done
    ) &
    spinner_pid=$!
}

stop_progress() {
    local success=$1
    if [ -n "$spinner_pid" ]; then
        kill "$spinner_pid" 2>/dev/null
        wait "$spinner_pid" 2>/dev/null
        spinner_pid=""
    fi
    local cols=30
    local bar=$(printf '#%.0s' $(seq 1 $cols 2>/dev/null))
    if [ "$success" = "ok" ]; then
        printf "\r${CYAN}%-40s${NC} [${GREEN}%s${NC}] ${GREEN}OK${NC}\n" "$1" "$bar"
    else
        printf "\r${CYAN}%-40s${NC} [${RED}%s${NC}] ${RED}FAIL${NC}\n" "$1" "$bar"
    fi
}

# ================================================================
# MANEJO DE ERRORES
# ================================================================
fail() {
    local code=$1
    local msg=$2
    echo -e "\n${RED}[$code]${NC} $msg"
    echo "[$code] $msg" >> "$LOG"
    ERRORS+=("$code: $msg")
}

run() {
    local code=$1
    local label=$2
    local errmsg=$3
    shift 3
    start_progress "$label"
    "$@" >> "$LOG" 2>&1
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        stop_progress "$label" "fail"
        fail "$code" "$errmsg"
        return 1
    fi
    stop_progress "$label" "ok"
}

# ================================================================
# DETECCIÓN DE HERRAMIENTAS
# ================================================================
detect_tools() {
    echo -e "${CYAN}=== Detectando herramientas ===${NC}"

    which cython3 > /dev/null 2>&1 || { fail "E01" "cython3 no encontrado. apt install cython3"; return 1; }
    which gcc     > /dev/null 2>&1 || { fail "E02" "gcc no encontrado. apt install gcc"; return 1; }
    which g++     > /dev/null 2>&1 || { fail "E03" "g++ no encontrado. apt install g++"; return 1; }
    which ghc     > /dev/null 2>&1 || { fail "E04" "ghc no encontrado. apt install ghc"; return 1; }

    if [ -x "/usr/lib/qt6/libexec/moc" ]; then
        MOC="/usr/lib/qt6/libexec/moc"
    elif which moc > /dev/null 2>&1; then
        MOC=$(which moc)
    else
        fail "E05" "moc no encontrado. apt install qt6-base-dev"
        return 1
    fi

    if [ -d "/usr/include/x86_64-linux-gnu/qt6" ]; then
        QT_BASE="/usr/include/x86_64-linux-gnu/qt6"
        QT_INC="-I$QT_BASE -I$QT_BASE/QtWidgets -I$QT_BASE/QtCore -I$QT_BASE/QtGui"
        QT_LIBS="-lQt6Widgets -lQt6Core -lQt6Gui"
    elif pkg-config --cflags Qt6Core > /dev/null 2>&1; then
        QT_INC=$(pkg-config --cflags Qt6Widgets Qt6Core Qt6Gui)
        QT_LIBS=$(pkg-config --libs Qt6Widgets Qt6Core Qt6Gui)
    else
        fail "E06" "Qt6 headers no encontrados. apt install qt6-base-dev"
        return 1
    fi

    if [ -d "/usr/include/python3.13" ]; then
        PY_INC="-I/usr/include/python3.13"
        PY_LDFLAGS="-L/usr/lib/python3.13/config-3.13-x86_64-linux-gnu -lpython3.13"
    elif python3.13-config --includes > /dev/null 2>&1; then
        PY_INC=$(python3.13-config --includes)
        PY_LDFLAGS=$(python3.13-config --ldflags --embed)
    else
        fail "E07" "Python 3.13 headers no encontrados. apt install python3-dev"
        return 1
    fi

    echo -e "${GREEN}[OK]${NC} Herramientas detectadas."
}

# ================================================================
# PASOS COMUNES
# ================================================================
build_common() {
    mkdir -p build

    run "E08" "downloader.py → Cython" "Cython falló en downloader.py" \
        cython3 --embed src/python/downloader.py -o build/downloader.c || return 1

    run "E09" "downloader.c → GCC" "GCC falló compilando downloader" \
        gcc -O2 $PY_INC build/downloader.c -lcurl $PY_LDFLAGS -o build/downloader || return 1

    run "E10" "Integrity.hs → GHC" "GHC falló en Integrity.hs" \
        ghc -shared -dynamic -fPIC \
        -package SHA -package directory -package bytestring \
        src/haskell/Integrity.hs \
        -o build/libintegrity.so || return 1

    run "E11" "operation_worker.h → MOC" "MOC falló en operation_worker.h" \
        $MOC $QT_INC src/cpp/operation_worker.h -o build/operation_worker.moc.cpp || return 1

    run "E12" "recovery_core.cpp → MOC" "MOC falló en recovery_core.cpp" \
        $MOC $QT_INC src/cpp/recovery_core.cpp -o build/recovery_core.moc || return 1
}

# ================================================================
# STANDARD
# ================================================================
build_standard() {
    echo ""; echo -e "${CYAN}=== Standard Build ===${NC}"; echo ""
    build_common || return 1

    run "E13" "recovery_core_standard → G++" "G++ falló compilando standard" \
        g++ -O2 -std=c++17 -fPIC \
        $QT_INC -Ibuild \
        src/cpp/recovery_core.cpp \
        build/operation_worker.moc.cpp \
        -Lbuild -lintegrity \
        -Wl,-rpath,build \
        $QT_LIBS \
        -o build/recovery_core_standard || return 1

    echo ""
    echo -e "${GREEN}  ✓ build/downloader${NC}"
    echo -e "${GREEN}  ✓ build/libintegrity.so${NC}"
    echo -e "${GREEN}  ✓ build/recovery_core_standard${NC}"
}

# ================================================================
# AGGRESSIVE
# ================================================================
build_aggressive() {
    echo ""; echo -e "${CYAN}=== Aggressive Build ===${NC}"; echo ""
    build_common || return 1

    if ! which holyc-lang > /dev/null 2>&1; then
        fail "E14" "holyc-lang no encontrado"
        return 1
    fi

    run "E15" "velumrec.HC → holyc-lang" "holyc-lang falló en velumrec.HC" \
        holyc-lang -c src/holyc/velumrec.HC -o build/velumrec_hc.o || return 1

    run "E16" "recovery_core_aggressive → G++" "G++ falló compilando aggressive" \
        g++ -O2 -std=c++17 -fPIC -DVELUMREC_AGGRESSIVE \
        $QT_INC -Ibuild \
        src/cpp/recovery_core.cpp \
        build/operation_worker.moc.cpp \
        build/velumrec_hc.o \
        -Lbuild -lintegrity \
        -Wl,-rpath,build \
        $QT_LIBS \
        -o build/recovery_core_aggressive || return 1

    echo ""
    echo -e "${GREEN}  ✓ build/downloader${NC}"
    echo -e "${GREEN}  ✓ build/libintegrity.so${NC}"
    echo -e "${GREEN}  ✓ build/recovery_core_aggressive${NC}"
}

# ================================================================
# RESUMEN
# ================================================================
print_summary() {
    echo ""
    if [ ${#ERRORS[@]} -eq 0 ]; then
        echo -e "${GREEN}=== Build completado sin errores ===${NC}"
    else
        echo -e "${RED}=== Build falló ===${NC}"
        for e in "${ERRORS[@]}"; do
            echo -e "  ${RED}✗${NC} $e"
        done
        echo -e "\n  Log completo: ${CYAN}$LOG${NC}"
    fi
}

# ================================================================
# ENTRY
# ================================================================
mkdir -p build; > "$LOG"
detect_tools || { print_summary; exit 1; }

case $MODE in
    standard)   build_standard ;;
    aggressive) build_aggressive ;;
    all)        build_standard; build_aggressive ;;
    *)          echo "Uso: bash build.sh [standard|aggressive|all]"; exit 1 ;;
esac

print_summary
