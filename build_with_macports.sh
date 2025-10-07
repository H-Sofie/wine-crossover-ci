#!/usr/bin/env arch -x86_64 bash

set -eo pipefail

TMP_EXTRACT_DIR=""

cleanup() {
    if [[ -n "$TMP_EXTRACT_DIR" && -d "$TMP_EXTRACT_DIR" ]]; then
        rm -rf "$TMP_EXTRACT_DIR"
    fi
}

trap cleanup EXIT

printtag() {
    # GitHub Actions tag format
    echo "::$1::${2-}"
}

begingroup() {
    printtag "group" "$1"
}

endgroup() {
    printtag "endgroup"
}

export GITHUB_WORKSPACE=$(pwd)

# Only supports building 25.1.0 or later
: "${CROSS_OVER_VERSION:=25.1.1}"
echo "Building crossover-wine-${CROSS_OVER_VERSION}"

# crossover source code to be downloaded
: "${CROSS_OVER_SOURCE_URL:=https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CROSS_OVER_VERSION}.tar.gz}"
: "${CROSS_OVER_LOCAL_FILE:=crossover-sources-${CROSS_OVER_VERSION}}"

download_file() {
    local url="$1"
    local destination="$2"
    curl --fail --location --retry 3 --retry-delay 5 -o "$destination" "$url"
}

# directories / files inside the downloaded tar file directory structure
export WINE_CONFIGURE=$GITHUB_WORKSPACE/sources/wine/configure

# build directories
export BUILDROOT=$GITHUB_WORKSPACE/build

# target directory for installation
export INSTALLROOT=$GITHUB_WORKSPACE/install

# artifact name
export WINE_INSTALLATION=wine-cx${CROSS_OVER_VERSION}

# Need to ensure port actually exists
if ! command -v "/opt/local/bin/port" &> /dev/null; then
    echo "</opt/local/bin/port> could not be found"
    echo "A MacPorts installation is required"
    exit 1
fi

# Manually configure $PATH
export PATH="/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin"


PORT_CMD=(sudo port -N)

begingroup "Installing dependencies build"
"${PORT_CMD[@]}" install bison ccache gettext mingw-w64 pkgconfig
endgroup


begingroup "Installing dependencies libraries"
"${PORT_CMD[@]}" install freetype gnutls-devel gettext-runtime libpcap libsdl2 moltenvk-latest
endgroup


export CC="ccache clang"
export CXX="${CC}++"
export i386_CC="ccache i686-w64-mingw32-gcc"
export x86_64_CC="ccache x86_64-w64-mingw32-gcc"

export CPATH="/opt/local/include"
export LIBRARY_PATH="/opt/local/lib"
export MACOSX_DEPLOYMENT_TARGET="10.15"

export OPTFLAGS="-O2"
export CFLAGS="${OPTFLAGS} -Wno-deprecated-declarations -Wno-format"
# gcc14.1 now sets -Werror-incompatible-pointer-types
export CROSSCFLAGS="${OPTFLAGS} -Wno-incompatible-pointer-types"
export LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-rpath,@loader_path/../../ -Wl,-rpath,/opt/local/lib"

export ac_cv_lib_soname_vulkan=""


if [[ ! -f ${CROSS_OVER_LOCAL_FILE}.tar.gz ]]; then
    begingroup "Downloading $CROSS_OVER_LOCAL_FILE"
    download_file "${CROSS_OVER_SOURCE_URL}" "${CROSS_OVER_LOCAL_FILE}.tar.gz"
    endgroup
fi


begingroup "Extracting $CROSS_OVER_LOCAL_FILE"
TMP_EXTRACT_DIR=$(mktemp -d "${GITHUB_WORKSPACE}/tmp.crossover.XXXXXX")
tar xf "${CROSS_OVER_LOCAL_FILE}.tar.gz" -C "$TMP_EXTRACT_DIR"

SOURCE_DIR=$(find "$TMP_EXTRACT_DIR" -maxdepth 2 -type d -path '*/sources' -print -quit || true)
if [[ -z "$SOURCE_DIR" ]]; then
    echo "Unable to locate sources directory inside archive" >&2
    exit 1
fi

rm -rf "${GITHUB_WORKSPACE}/sources"
mkdir -p "${GITHUB_WORKSPACE}/sources"

if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$SOURCE_DIR"/ "${GITHUB_WORKSPACE}/sources"/
else
    cp -R "$SOURCE_DIR"/. "${GITHUB_WORKSPACE}/sources"/
fi
endgroup


begingroup "Add distversion.h"
cp "${GITHUB_WORKSPACE}/distversion.h" "${GITHUB_WORKSPACE}/sources/wine/programs/winedbg/distversion.h"
endgroup


begingroup "Configure winecx-${CROSS_OVER_VERSION}"
mkdir -p "${BUILDROOT}/winecx-${CROSS_OVER_VERSION}"
pushd "${BUILDROOT}/winecx-${CROSS_OVER_VERSION}"
${WINE_CONFIGURE} \
    --prefix= \
    --disable-tests \
    --enable-win64 \
    --enable-archs=i386,x86_64 \
    --without-alsa \
    --without-capi \
    --with-coreaudio \
    --with-cups \
    --without-dbus \
    --without-fontconfig \
    --with-freetype \
    --with-gettext \
    --without-gettextpo \
    --without-gphoto \
    --with-gnutls \
    --without-gssapi \
    --without-gstreamer \
    --without-inotify \
    --without-krb5 \
    --with-mingw \
    --without-netapi \
    --with-opencl \
    --without-opengl \
    --without-oss \
    --with-pcap \
    --with-pthread \
    --without-pulse \
    --without-sane \
    --with-sdl \
    --without-udev \
    --with-unwind \
    --without-usb \
    --without-v4l2 \
    --with-vulkan \
    --without-x
popd
endgroup


cpu_count() {
    local detected=""
    if command -v sysctl >/dev/null 2>&1; then
        detected=$(sysctl -n hw.ncpu 2>/dev/null || true)
    fi
    if [[ -z "$detected" ]] && command -v nproc >/dev/null 2>&1; then
        detected=$(nproc)
    fi
    echo "${detected:-1}"
}

begingroup "Build winecx-${CROSS_OVER_VERSION}"
pushd "${BUILDROOT}/winecx-${CROSS_OVER_VERSION}"
make -j"$(cpu_count)"
popd
endgroup


begingroup "Install winecx-${CROSS_OVER_VERSION}"
pushd "${BUILDROOT}/winecx-${CROSS_OVER_VERSION}"
make install-lib DESTDIR="${INSTALLROOT}/${WINE_INSTALLATION}"
popd
endgroup
