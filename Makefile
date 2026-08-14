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

# VelumRec - Makefile

# Uso:
#   make              -> compila standard y aggressive
#   make standard     -> solo standard (sin HolyC)
#   make aggressive   -> solo aggressive (con HolyC)
#   make clean        -> limpia todos los artefactos

PY_INCLUDES := $(shell python3.13-config --includes)
PY_LDFLAGS  := $(shell python3.13-config --ldflags --embed)
GHC         := ghc
GHC_PKGS    := -package SHA -package directory -package bytestring
CXX         := g++
QT_CFLAGS   := $(shell pkg-config --cflags Qt6Widgets Qt6Core Qt6Gui)
QT_LIBS     := $(shell pkg-config --libs Qt6Widgets Qt6Core Qt6Gui)
MOC         := /usr/lib/qt6/libexec/moc
MOC_FLAGS   := $(shell pkg-config --cflags Qt6Core)
CXXFLAGS    := -O2 -std=c++17 -fPIC $(QT_CFLAGS) -Ibuild

BUILD_DIR   := build

.PHONY: all standard aggressive clean

all: standard aggressive

# ================================================================
# 1. CYTHON — downloader.py -> downloader
# ================================================================

$(BUILD_DIR)/downloader.c: src/python/downloader.py
	mkdir -p $(BUILD_DIR)
	cython3 --embed src/python/downloader.py -o $(BUILD_DIR)/downloader.c

$(BUILD_DIR)/downloader: $(BUILD_DIR)/downloader.c
	gcc -O2 \
		$(PY_INCLUDES) \
		$(BUILD_DIR)/downloader.c \
		-lcurl \
		$(PY_LDFLAGS) \
		-o $(BUILD_DIR)/downloader

# ================================================================
# 2. HASKELL — Integrity.hs -> libintegrity.so
# ================================================================

$(BUILD_DIR)/libintegrity.so: src/haskell/Integrity.hs
	mkdir -p $(BUILD_DIR)
	$(GHC) -shared -dynamic -fPIC \
		$(GHC_PKGS) \
		src/haskell/Integrity.hs \
		-o $(BUILD_DIR)/libintegrity.so

# ================================================================
# 3. MOC — procesa operation_worker.h y recovery_core.cpp
# ================================================================

$(BUILD_DIR)/operation_worker.moc.cpp: src/cpp/operation_worker.h
	mkdir -p $(BUILD_DIR)
	$(MOC) $(MOC_FLAGS) \
		src/cpp/operation_worker.h \
		-o $(BUILD_DIR)/operation_worker.moc.cpp

$(BUILD_DIR)/recovery_core.moc: src/cpp/recovery_core.cpp
	mkdir -p $(BUILD_DIR)
	$(MOC) $(MOC_FLAGS) \
		src/cpp/recovery_core.cpp \
		-o $(BUILD_DIR)/recovery_core.moc

# ================================================================
# 4. C++ STANDARD
# ================================================================

standard: $(BUILD_DIR)/downloader $(BUILD_DIR)/libintegrity.so \
          $(BUILD_DIR)/operation_worker.moc.cpp $(BUILD_DIR)/recovery_core.moc
	$(CXX) $(CXXFLAGS) \
		src/cpp/recovery_core.cpp \
		$(BUILD_DIR)/operation_worker.moc.cpp \
		-L$(BUILD_DIR) -lintegrity \
		-Wl,-rpath,$(BUILD_DIR) \
		$(QT_LIBS) \
		-o $(BUILD_DIR)/recovery_core_standard
	@echo "[velumrec] Standard build completo."

# ================================================================
# 5. C++ AGGRESSIVE
# ================================================================

$(BUILD_DIR)/velumrec_hc.o: src/holyc/velumrec.HC
	@which holyc-lang > /dev/null 2>&1 || \
		{ echo "[velumrec] Error: holyc-lang no encontrado."; exit 1; }
	holyc-lang -c src/holyc/velumrec.HC -o $(BUILD_DIR)/velumrec_hc.o

aggressive: $(BUILD_DIR)/downloader $(BUILD_DIR)/libintegrity.so \
            $(BUILD_DIR)/operation_worker.moc.cpp $(BUILD_DIR)/recovery_core.moc \
            $(BUILD_DIR)/velumrec_hc.o
	$(CXX) $(CXXFLAGS) -DVELUMREC_AGGRESSIVE \
		src/cpp/recovery_core.cpp \
		$(BUILD_DIR)/operation_worker.moc.cpp \
		$(BUILD_DIR)/velumrec_hc.o \
		-L$(BUILD_DIR) -lintegrity \
		-Wl,-rpath,$(BUILD_DIR) \
		$(QT_LIBS) \
		-o $(BUILD_DIR)/recovery_core_aggressive
	@echo "[velumrec] Aggressive build completo."

# ================================================================
# CLEAN
# ================================================================

clean:
	rm -rf $(BUILD_DIR)
	@echo "[velumrec] Build limpiado."
