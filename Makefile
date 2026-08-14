# ==============================================================================
# Velum OS - Core Enterprise Infrastructure
# Copyright (C) 2026 Velum OS Project Contributors <velum_os_project@proton.me>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# ==============================================================================
# VelumRec - Makefile
# Compila los componentes de la partición de recovery:
#   1. Python → Cython (downloader.py)
#   2. Haskell → shared lib (Integrity.hs)
#   3. Qt6 MOC → metaobjetos para recovery_core.cpp
#   4. C++ Qt6 → recovery_core (standard y aggressive)
#
# recovery_setup.py lo compila OBS al hacer apt install velum-rec.
#
# Uso:
#   make              → compila standard y aggressive
#   make standard     → solo standard (sin HolyC)
#   make aggressive   → solo aggressive (con HolyC)
#   make clean        → limpia todos los artefactos

# ================================================================
# CONFIGURACIÓN
# ================================================================

PYTHON_FLAGS := $(shell python3-config --includes --ldflags)
GHC          := ghc
GHC_PACKAGES := -package SHA -package directory -package bytestring
CXX          := g++
CXXFLAGS     := -O2 -std=c++17 -fPIC
QT_FLAGS     := $(shell pkg-config --cflags --libs Qt6Widgets Qt6Core)
MOC          := moc6

BUILD_DIR    := build

# ================================================================
# TARGETS PRINCIPALES
# ================================================================

.PHONY: all standard aggressive clean

all: standard aggressive

# ================================================================
# 1. CYTHON — downloader.py → downloader (partición de recovery)
# ================================================================

$(BUILD_DIR)/downloader.c: src/python/downloader.py
	mkdir -p $(BUILD_DIR)
	cython3 --embed src/python/downloader.py -o $(BUILD_DIR)/downloader.c

$(BUILD_DIR)/downloader: $(BUILD_DIR)/downloader.c
	gcc -O2 $(BUILD_DIR)/downloader.c \
		$(PYTHON_FLAGS) \
		-lpython3.13 \
		-lcurl \
		-o $(BUILD_DIR)/downloader

# ================================================================
# 2. HASKELL — Integrity.hs → libintegrity.so
# ================================================================

$(BUILD_DIR)/libintegrity.so: src/haskell/Integrity.hs
	mkdir -p $(BUILD_DIR)
	$(GHC) -shared -dynamic -fPIC \
		$(GHC_PACKAGES) \
		src/haskell/Integrity.hs \
		-o $(BUILD_DIR)/libintegrity.so

# ================================================================
# 3. MOC — genera metaobjetos Qt6 para recovery_core.cpp
# ================================================================

$(BUILD_DIR)/recovery_core.moc.cpp: src/cpp/recovery_core.cpp
	mkdir -p $(BUILD_DIR)
	$(MOC) $(shell pkg-config --cflags Qt6Core) \
		src/cpp/recovery_core.cpp \
		-o $(BUILD_DIR)/recovery_core.moc.cpp

# ================================================================
# 4. C++ STANDARD — sin HolyC
# ================================================================

standard: $(BUILD_DIR)/downloader $(BUILD_DIR)/libintegrity.so $(BUILD_DIR)/recovery_core.moc.cpp
	$(CXX) $(CXXFLAGS) \
		src/cpp/recovery_core.cpp \
		$(BUILD_DIR)/recovery_core.moc.cpp \
		-L$(BUILD_DIR) -lintegrity \
		-Wl,-rpath,$(BUILD_DIR) \
		$(QT_FLAGS) \
		-o $(BUILD_DIR)/recovery_core_standard
	@echo ""
	@echo "[velumrec] Standard build completo:"
	@echo "  $(BUILD_DIR)/downloader              ← descargador de ISO/módulos"
	@echo "  $(BUILD_DIR)/recovery_core_standard  ← UI Qt6 de recovery (sin HolyC)"

# ================================================================
# 5. C++ AGGRESSIVE — con HolyC
# ================================================================

$(BUILD_DIR)/velumrec_hc.o: src/holyc/velumrec.HC
	@which holyc-lang > /dev/null 2>&1 || \
		{ echo "[velumrec] Error: holyc-lang no encontrado."; \
		  echo "           Instálalo antes de compilar aggressive."; \
		  exit 1; }
	holyc-lang -c src/holyc/velumrec.HC -o $(BUILD_DIR)/velumrec_hc.o

aggressive: $(BUILD_DIR)/downloader $(BUILD_DIR)/libintegrity.so $(BUILD_DIR)/recovery_core.moc.cpp $(BUILD_DIR)/velumrec_hc.o
	$(CXX) $(CXXFLAGS) -DVELUMREC_AGGRESSIVE \
		src/cpp/recovery_core.cpp \
		$(BUILD_DIR)/recovery_core.moc.cpp \
		$(BUILD_DIR)/velumrec_hc.o \
		-L$(BUILD_DIR) -lintegrity \
		-Wl,-rpath,$(BUILD_DIR) \
		$(QT_FLAGS) \
		-o $(BUILD_DIR)/recovery_core_aggressive
	@echo ""
	@echo "[velumrec] Aggressive build completo:"
	@echo "  $(BUILD_DIR)/downloader                 ← descargador de ISO/módulos"
	@echo "  $(BUILD_DIR)/recovery_core_aggressive   ← UI Qt6 de recovery (con HolyC)"

# ================================================================
# CLEAN
# ================================================================

clean:
	rm -rf $(BUILD_DIR)
	@echo "[velumrec] Build limpiado."
