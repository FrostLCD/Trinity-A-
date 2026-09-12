#!/bin/sh
# Trinity Launcher — AnyLinux AppImage (metodo quick-sharun/sharun).
#
# Construye un AppImage 100% portable (glibc + ld-linux propios, DwarFS +
# uruntime): corre en cualquier distro, musl y NixOS sin FHS-wrapper.
#
# REGLAS (https://github.com/pkgforge-dev/Anylinux-AppImages):
#  - Compilar SOLO en Arch Linux. Nunca Fedora ni Ubuntu.
#  - La app debe estar instalada en /usr ANTES de empaquetar.
#  - Nunca copiar .so/binarios a mano al AppDir: se pasan como args a
#    quick-sharun y el hace el deploy (ldd + strace de dlopens + sharun).
#  - Ignorar guias externas (linuxdeploy, appimage-builder, docs.appimage).
#
# Uso local (en Arch):   sh ./trinity-appimage.sh
# En CI lo llama .github/workflows/anylinux-appimage.yml dentro del
# contenedor ghcr.io/pkgforge-dev/archlinux:latest.
#
# Env opcionales:
#   MCPE_NX   URL/repo del engine (por defecto manifest publico, rama qt6)
#   UPINFO    update-information para el hook self-updater
#   OUTPATH   destino del AppImage (por defecto ./dist)

set -eux

ARCH="$(uname -m)"
ROOT="$PWD"
OUTPATH="${OUTPATH:-$ROOT/dist}"
OUTNAME="Trinity_Launcher-$ARCH.AppImage"
SHARUN_URL="https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/refs/heads/main/useful-tools/quick-sharun.sh"
DEBLOAT_URL="https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/refs/heads/main/useful-tools/get-debloated-pkgs.sh"
ZIG_VER="0.16.0"

if [ "$(id -u)" -eq 0 ]; then
	SUDO=""
else
	SUDO="sudo"
fi

echo "=== 1/7 Dependencias del sistema (Arch) ==="
$SUDO pacman -Syu --noconfirm \
	base-devel git curl wget cmake clang ninja patchelf zsync \
	xorg-server-xvfb pciutils hwdata dbus \
	qt6-base qt6-declarative qt6-webengine qt6-svg qt6-tools qt6-translations \
	libzip libpng libpulse alsa-lib pipewire jack2 sndio \
	libx11 libxi libxext libxfixes libxcursor libxrandr libxss libxtst \
	libxcb libxkbcommon libxkbcommon-x11 xcb-util-wm \
	mesa vulkan-headers vulkan-validation-layers libdrm \
	libevdev libusb bluez-libs ibus libunwind libdecor wayland \
	libcups openssl curl

echo "=== 2/7 Paquetes debloated (mesa sin LLVM completo, icu/qt/gtk minis) ==="
wget --retry-connrefused --tries=30 "$DEBLOAT_URL" -O ./get-debloated-pkgs.sh
chmod +x ./get-debloated-pkgs.sh
./get-debloated-pkgs.sh --add-common --prefer-nano

echo "=== 3/7 Fuentes del engine + datos ==="
if [ ! -d mcpe-nx ]; then
	# MCPE_NX trae la URL privada (secreto del CI, igual que en los
	# workflows simple-appimage/nightly); sin el se usa el manifest
	# publico en su rama qt6 (ver docs/BUILD.md).
	ENGINE_URL="${MCPE_NX:-https://github.com/minecraft-linux/mcpelauncher-manifest.git}"
	# Silenciado a proposito: la URL puede llevar credenciales y este
	# script corre con xtrace (set -x).
	set +x
	git clone "$ENGINE_URL" mcpe-nx > /dev/null 2>&1
	if [ -z "${MCPE_NX:-}" ]; then
		git -C mcpe-nx checkout qt6 > /dev/null 2>&1 || true
		git -C mcpe-nx submodule update --init --recursive > /dev/null 2>&1 || true
	fi
	set -x
fi
# Parche del engine: libc-shim necesita fcntl GETLK(5)/SETLKW(7) porque el
# libsqliteX del juego los sondea al iniciar (si no: SIGABRT). Se omite en
# silencio si el engine ya lo trae.
if [ -f patches/libc-shim-fcntl-getlk.patch ] && [ -d mcpe-nx/libc-shim ]; then
	(cd mcpe-nx && patch -p1 --forward < ../patches/libc-shim-fcntl-getlk.patch) || true
fi
if [ ! -d tapk-extract ]; then
	git clone https://gitlab.com/javiercplus/tapk-extract.git tapk-extract
fi
if [ ! -d linux-bin ] && [ ! -d mcpe-nx/mcpelauncher-linux-bin ]; then
	git clone https://github.com/minecraft-linux/mcpelauncher-linux-bin.git linux-bin
fi
# El engine trae sdl3/ y mcpelauncher-linux-bin/ vendoreados y no usa
# submodulos: un clone plano basta.
if [ "$ARCH" = "x86_64" ] && [ ! -d 32bitmcpe ]; then
	# HuggingFace limita por IP (429): reintentos con espera
	for i in 1 2 3 4 5 6 7 8 9 10; do
		if wget --retry-connrefused --tries=5 \
			https://huggingface.co/datasets/ccoffee20/PEPE/resolve/main/mcpe32bit.tar \
			-O mcpe32bit.tar; then
			break
		fi
		echo "Descarga 429/fallida (intento $i/10), esperando 60s..."
		rm -f mcpe32bit.tar
		sleep 60
	done
	tar -xf mcpe32bit.tar
fi

echo "=== 4/7 Compilar engine (sin GUI, SDL3) + extractor (Zig) + Trinity ==="
export CC=clang
export CXX=clang++
cmake -S mcpe-nx -B mcpe-nx/build -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_WEBVIEW=OFF \
	-DGAMEWINDOW_SYSTEM=SDL3 \
	-DBUILD_UI=OFF \
	-DENABLE_DEV_PATHS=OFF \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-Wno-dev
cmake --build mcpe-nx/build --parallel "$(nproc)"

ZIG_TAR="zig-$ARCH-linux-$ZIG_VER.tar.xz"
if ! command -v zig >/dev/null 2>&1; then
	wget -q "https://ziglang.org/download/$ZIG_VER/$ZIG_TAR"
	tar -xf "$ZIG_TAR"
	export PATH="$ROOT/zig-$ARCH-linux-$ZIG_VER:$PATH"
fi
(cd tapk-extract && zig build --release=fast -Dtarget=native -Dcpu=baseline)

if [ "$ARCH" != "x86_64" ]; then
	# Sin flags x86 en ARM (igual que el workflow appimage-arm)
	find . -name "CMakeLists.txt" -exec sed -i 's/-msse3\b//g;s/-msse4[^ ]*//g;s/-mavx[^ ]*//g' {} \;
	sed -i 's/-msse3\b//g;s/-msse4[^ ]*//g;s/-mavx[^ ]*//g' build.sh || true
fi
cmake -S . -B build -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_C_COMPILER=clang \
	-DCMAKE_CXX_COMPILER=clang++ \
	-Wno-dev
cmake --build build --parallel "$(nproc)"

echo "=== 5/7 Instalar todo en /usr (requisito de quick-sharun) ==="
$SUDO install -Dm755 build/app/trinity /usr/bin/trinity
$SUDO install -Dm755 mcpe-nx/build/mcpelauncher-client/mcpelauncher-client /usr/bin/mcpelauncher-client
$SUDO install -Dm755 tapk-extract/zig-out/bin/tapk-extract /usr/bin/mcpelauncher-extract
for helper in msa-daemon mcpelauncher-error; do
	found="$(find mcpe-nx/build -type f -name "$helper" -print | head -n 1)" || true
	if [ -n "$found" ]; then
		$SUDO install -Dm755 "$found" "/usr/bin/$helper"
	fi
done
$SUDO install -Dm644 resources/shortcuts/com.trench.trinity.launcher.desktop \
	/usr/share/applications/com.trench.trinity.launcher.desktop
$SUDO install -Dm644 resources/branding/com.trench.trinity.launcher.svg \
	/usr/share/icons/hicolor/scalable/apps/com.trench.trinity.launcher.svg
$SUDO mkdir -p /usr/share/mcpelauncher
if [ -d mcpe-nx/mcpelauncher-linux-bin ]; then
	$SUDO cp -r mcpe-nx/mcpelauncher-linux-bin/. /usr/share/mcpelauncher/
else
	$SUDO cp -r linux-bin/. /usr/share/mcpelauncher/
fi

echo "=== 6/7 Deploy con quick-sharun (jamas copiar .so a mano) ==="
wget --retry-connrefused --tries=30 "$SHARUN_URL" -O ./quick-sharun
chmod +x ./quick-sharun

export ICON=/usr/share/icons/hicolor/scalable/apps/com.trench.trinity.launcher.svg
export DESKTOP=/usr/share/applications/com.trench.trinity.launcher.desktop
export MAIN_BIN=trinity
export OUTPATH OUTNAME
export ADD_HOOKS="self-updater.hook:fix-namespaces.hook"
export DEPLOY_OPENGL=1 DEPLOY_VULKAN=1 DEPLOY_SDL=1

BINS="/usr/bin/trinity /usr/bin/mcpelauncher-client /usr/bin/mcpelauncher-extract /usr/bin/lspci"
for helper in msa-daemon mcpelauncher-error; do
	if [ -x "/usr/bin/$helper" ]; then
		BINS="$BINS /usr/bin/$helper"
	fi
done
# shellcheck disable=SC2086
./quick-sharun $BINS

echo "=== 6b/7 Datos extra + sidecar 32-bit (x86_64) ==="
# linux-bin: datos del engine, no son ELF asi que van directo a share/
mkdir -p AppDir/share/mcpelauncher
cp -r /usr/share/mcpelauncher/. AppDir/share/mcpelauncher/
# pci.ids para lspci (deteccion de GPU del gestor de contenido)
if [ -f /usr/share/hwdata/pci.ids ]; then
	mkdir -p AppDir/share/hwdata
	cp -f /usr/share/hwdata/pci.ids AppDir/share/hwdata/
fi
# Vars de runtime que el AppRun/sharun expande al lanzar (sin expandir aqui)
echo 'MCPELAUNCHER_DATA_DIR=${SHARUN_DIR}/share/mcpelauncher' >> AppDir/.env
echo 'PCI_IDS=${SHARUN_DIR}/share/hwdata/pci.ids' >> AppDir/.env
# Aislamiento anti-crash en distros con userland viejo (Void/musl, etc):
# - fusion: el host puede traer QT_QPA_PLATFORMTHEME=gtk3 y el plugin
#   libqgtk3 empaquetado contra un GTK3 ajeno al del host -> mezcla y SIGSEGV
# - GIO_MODULE_DIR/GIO_USE_VFS: impide que GIO sondee los modulos gio/gvfs
#   del host (incompatibles con el glib empaquetado -> SIGSEGV)
echo 'QT_QPA_PLATFORMTHEME=fusion' >> AppDir/.env
echo 'GIO_MODULE_DIR=${SHARUN_DIR}/lib/gio/modules' >> AppDir/.env
echo 'GIO_USE_VFS=local' >> AppDir/.env

if [ "$ARCH" = "x86_64" ] && [ -f 32bitmcpe/bin/mcpelauncher-client86 ]; then
	# El helper de 32-bit no puede mezclarse en lib/ (colisionaria con los
	# .so de 64-bit con el mismo nombre), asi que viaja autocontenido en
	# lib32/ con su propio ld-linux --library-path: el mismo mecanismo
	# certificado de HOW-TO-MAKE-THESE.md, sin LD_LIBRARY_PATH.
	mkdir -p AppDir/lib32 AppDir/bin
	cp -f 32bitmcpe/bin/mcpelauncher-client86 AppDir/bin/.mcpelauncher-client86.real
	chmod +x AppDir/bin/.mcpelauncher-client86.real
	cp -f 32bitmcpe/lib32/*.so* AppDir/lib32/ 2>/dev/null || true
	if [ -f 32bitmcpe/lib32/ld-linux.so.2 ]; then
		cp -f 32bitmcpe/lib32/ld-linux.so.2 AppDir/lib32/
	elif [ -f /usr/lib32/ld-linux.so.2 ]; then
		cp -f /usr/lib32/ld-linux.so.2 AppDir/lib32/
	fi
	# Limpieza heredada del workflow clasico: esos GL/X de 32-bit pisan
	# los del host y rompen el arranque en GPUs modernas.
	rm -f AppDir/lib32/libGLdispatch.so* AppDir/lib32/libX*.so* AppDir/lib32/libxcb*.so*
	cat > AppDir/bin/mcpelauncher-client86 <<'EOF'
#!/bin/sh
# Sidecar 32-bit: loader propio, sin tocar el entorno del proceso padre.
HERE="$(dirname "$(readlink -f "$0")")/.."
HERE="$(readlink -f "$HERE")"
exec "$HERE"/lib32/ld-linux.so.2 --library-path "$HERE"/lib32 "$HERE"/bin/.mcpelauncher-client86.real "$@"
EOF
	chmod +x AppDir/bin/mcpelauncher-client86
fi

echo "=== 7/7 Empaquetar (DwarFS + uruntime) y test ==="
export OUTPATH OUTNAME
./quick-sharun --make-appimage
./quick-sharun --test ./dist/*.AppImage

echo "Listo: $OUTPATH/$OUTNAME"
