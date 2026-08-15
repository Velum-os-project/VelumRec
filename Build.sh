#!bin/bash
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

set -e

QT_INC="-I/usr/include/x86_64-linux-gnu/qt6 \
  -I/usr/include/x86_64-linux-gnu/qt6/QtWidgets \
  -I/usr/include/x86_64-linux-gnu/qt6/QtCore \
  -I/usr/include/x86_64-linux-gnu/qt6/QtGui"

QT_LIBS="-lQt6Widgets -lQt6Core -lQt6Gui"

MOC=/usr/lib/qt6/libexec/moc

mkdir -p build

echo "[1/5] Compilando downloader.py con Cython..."
cython3 --embed src/python/downloader.py -o build/downloader.c
gcc -O2 -I/usr/include/python3.13 build/downloader.c \
  -lcurl \
  -L/usr/lib/python3.13/config-3.13-x86_64-linux-gnu \
  -lpython3.13 \
  -o build/downloader

echo "[2/5] Compilando Integrity.hs con GHC..."
ghc -shared -dynamic -fPIC \
  -package SHA -package directory -package bytestring \
  src/haskell/Integrity.hs \
  -o build/libintegrity.so

echo "[3/5] Generando metaobjetos Qt6 con MOC..."
$MOC $QT_INC src/cpp/operation_worker.h -o build/operation_worker.moc.cpp
$MOC $QT_INC src/cpp/recovery_core.cpp  -o build/recovery_core.moc

echo "[4/5] Compilando recovery_core_standard..."
g++ -O2 -std=c++17 -fPIC \
  $QT_INC \
  -Ibuild \
  src/cpp/recovery_core.cpp \
  build/operation_worker.moc.cpp \
  -Lbuild -lintegrity \
  -Wl,-rpath,build \
  $QT_LIBS \
  -o build/recovery_core_standard

echo "[5/5] Standard build completo."
echo "  build/downloader"
echo "  build/libintegrity.so"
echo "  build/recovery_core_standard"
