#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOCAL_DIR="${ROOT_DIR}/.local"
BUILD_DIR="${LOCAL_DIR}/build"
INSTALL_DIR="${LOCAL_DIR}/install"
ARTIFACT_DIR="${ROOT_DIR}/artifacts/arm64-v8a"
LOG_DIR="${LOCAL_DIR}/logs"

FREERDP_VERSION="${FREERDP_VERSION:-3.10.3}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.0.15}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.2}"

ENV_FILE="${LOCAL_DIR}/ohos-env.sh"
if [[ -z "${OHOS_NDK_HOME:-}" ]]; then
  if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
  fi
fi

if [[ -z "${OHOS_NDK_HOME:-}" ]]; then
  echo "ERROR: OHOS_NDK_HOME not set. Run scripts/linux-setup.sh first."
  exit 1
fi

mkdir -p "${BUILD_DIR}" "${INSTALL_DIR}" "${ARTIFACT_DIR}" "${LOG_DIR}"

OHOS_CLANG="${OHOS_NDK_HOME}/llvm/bin/clang"
OHOS_CLANGXX="${OHOS_NDK_HOME}/llvm/bin/clang++"
OHOS_AR="${OHOS_NDK_HOME}/llvm/bin/llvm-ar"
OHOS_RANLIB="${OHOS_NDK_HOME}/llvm/bin/llvm-ranlib"
OHOS_STRIP="${OHOS_NDK_HOME}/llvm/bin/llvm-strip"
OHOS_SYSROOT="${OHOS_NDK_HOME}/sysroot"
OHOS_TARGET="aarch64-linux-ohos"

TOOLS_DIR="${LOCAL_DIR}/ohos-tools"
mkdir -p "${TOOLS_DIR}"

cat > "${TOOLS_DIR}/ohos-clang" <<EOF2
#!/usr/bin/env bash
exec "${OHOS_CLANG}" --target=${OHOS_TARGET} --sysroot=${OHOS_SYSROOT} "\$@"
EOF2
chmod +x "${TOOLS_DIR}/ohos-clang"

cat > "${TOOLS_DIR}/ohos-clang++" <<EOF2
#!/usr/bin/env bash
exec "${OHOS_CLANGXX}" --target=${OHOS_TARGET} --sysroot=${OHOS_SYSROOT} "\$@"
EOF2
chmod +x "${TOOLS_DIR}/ohos-clang++"

export OHOS_CC="${TOOLS_DIR}/ohos-clang"
export OHOS_CXX="${TOOLS_DIR}/ohos-clang++"
export OHOS_AR
export OHOS_RANLIB
export OHOS_STRIP
export OHOS_SYSROOT
export OHOS_TARGET

# Test compiler
"${OHOS_CC}" -x c - -c -o /tmp/ohos-test.o <<< 'int main(){return 0;}'

log() {
  echo "[$(date +"%H:%M:%S")] $*"
}

ensure_tarball() {
  local url="$1"
  local out="$2"
  if [[ ! -f "$out" ]]; then
    log "Downloading $url"
    curl -L --retry 3 --retry-delay 5 -o "$out" "$url"
  fi
}

build_zlib() {
  log "Building zlib ${ZLIB_VERSION}"
  local src_dir="${BUILD_DIR}/zlib-${ZLIB_VERSION}"
  local tarball="${BUILD_DIR}/zlib-${ZLIB_VERSION}.tar.gz"
  ensure_tarball "https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz" "$tarball"
  if [[ ! -d "$src_dir" ]]; then
    tar xzf "$tarball" -C "${BUILD_DIR}"
  fi
  pushd "$src_dir" >/dev/null
  CC="$OHOS_CC" AR="$OHOS_AR" RANLIB="$OHOS_RANLIB" CFLAGS="-fPIC -O2" \
    ./configure --prefix="${INSTALL_DIR}/zlib" --static
  make -j"$(nproc)" >"${LOG_DIR}/zlib-build.log" 2>&1
  make install >>"${LOG_DIR}/zlib-build.log" 2>&1
  popd >/dev/null
}

build_openssl() {
  log "Building OpenSSL ${OPENSSL_VERSION}"
  local src_dir="${BUILD_DIR}/openssl-${OPENSSL_VERSION}"
  local tarball="${BUILD_DIR}/openssl-${OPENSSL_VERSION}.tar.gz"
  ensure_tarball "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" "$tarball"
  if [[ ! -d "$src_dir" ]]; then
    tar xzf "$tarball" -C "${BUILD_DIR}"
  fi
  pushd "$src_dir" >/dev/null
  CC="$OHOS_CC" CXX="$OHOS_CXX" AR="$OHOS_AR" RANLIB="$OHOS_RANLIB" \
  ./Configure linux-aarch64 \
    --prefix="${INSTALL_DIR}/openssl" \
    --openssldir=/dev/null \
    --libdir=lib \
    no-shared no-tests no-asm \
    no-dso \
    no-engine \
    no-module \
    no-autoload-config \
    -fPIC -O2 \
    -DOPENSSL_NO_AUTOLOAD_CONFIG=1

  make -j"$(nproc)" >"${LOG_DIR}/openssl-build.log" 2>&1 || make -j2 >>"${LOG_DIR}/openssl-build.log" 2>&1
  make install_sw >>"${LOG_DIR}/openssl-build.log" 2>&1
  popd >/dev/null

  if [[ ! -f "${INSTALL_DIR}/openssl/lib/libssl.a" ]]; then
    echo "ERROR: libssl.a missing"
    exit 1
  fi
  if [[ ! -f "${INSTALL_DIR}/openssl/lib/libcrypto.a" ]]; then
    echo "ERROR: libcrypto.a missing"
    exit 1
  fi
}

clone_freerdp() {
  log "Cloning FreeRDP ${FREERDP_VERSION}"
  local src_dir="${BUILD_DIR}/FreeRDP"
  if [[ ! -d "$src_dir/.git" ]]; then
    git clone --depth 1 --branch "${FREERDP_VERSION}" \
      https://github.com/FreeRDP/FreeRDP.git "$src_dir"
  fi
}

patch_freerdp() {
  log "Patching FreeRDP for OHOS/musl"
  local src_dir="${BUILD_DIR}/FreeRDP"
  local thread_file="${src_dir}/winpr/libwinpr/thread/thread.c"
  if [[ -f "$thread_file" ]]; then
    sed -i 's/#ifndef ANDROID/#if !defined(ANDROID) \&\& !defined(__OHOS__)/g' "$thread_file"
  fi

  find "${src_dir}/channels" -name "*.h" -o -name "*.c" | \
    xargs sed -i 's/#include <SLES\/OpenSLES_Android.h>/#include <SLES\/OpenSLES.h>/g' || true
  find "${src_dir}/channels" -name "*.h" -o -name "*.c" | \
    xargs sed -i 's/#include <SLES\/OpenSLES_AndroidConfiguration.h>/#include <SLES\/OpenSLES.h>/g' || true

  find "${src_dir}/channels" -name "*.h" -o -name "*.c" | \
    xargs sed -i 's/SL_IID_ANDROIDSIMPLEBUFFERQUEUE/SL_IID_BUFFERQUEUE/g' || true
  find "${src_dir}/channels" -name "*.h" -o -name "*.c" | \
    xargs sed -i 's/SLAndroidSimpleBufferQueueItf/SLBufferQueueItf/g' || true
  find "${src_dir}/channels" -name "*.h" -o -name "*.c" | \
    xargs sed -i 's/SLDataLocator_AndroidSimpleBufferQueue/SLDataLocator_BufferQueue/g' || true
  find "${src_dir}/channels" -name "*.h" -o -name "*.c" | \
    xargs sed -i 's/SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE/SL_DATALOCATOR_BUFFERQUEUE/g' || true

  local client_cmake="${src_dir}/client/common/CMakeLists.txt"
  if [[ -f "$client_cmake" ]]; then
    sed -i 's/addtargetwithresourcefile(${MODULE_NAME} FALSE/addtargetwithresourcefile(${MODULE_NAME} SHARED/g' "$client_cmake"
  fi
}

build_freerdp() {
  log "Building FreeRDP"
  local src_dir="${BUILD_DIR}/FreeRDP"
  local build_dir="${src_dir}/build"
  mkdir -p "$build_dir"
  pushd "$build_dir" >/dev/null

  local openssl_lib="${INSTALL_DIR}/openssl/lib"
  if [[ -d "${INSTALL_DIR}/openssl/lib64" ]]; then
    openssl_lib="${INSTALL_DIR}/openssl/lib64"
  fi

  cat > /tmp/ohos-toolchain.cmake << EOF2
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER "${OHOS_CC}")
set(CMAKE_CXX_COMPILER "${OHOS_CXX}")
set(CMAKE_AR "${OHOS_AR}" CACHE FILEPATH "Archiver")
set(CMAKE_RANLIB "${OHOS_RANLIB}" CACHE FILEPATH "Ranlib")
set(CMAKE_STRIP "${OHOS_STRIP}" CACHE FILEPATH "Strip")
set(CMAKE_C_FLAGS_INIT "-fPIC -O2 -D__OHOS__=1")
set(CMAKE_CXX_FLAGS_INIT "-fPIC -O2 -D__OHOS__=1")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-Wl,--allow-shlib-undefined")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
EOF2

  cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=/tmp/ohos-toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-O2 -DNDEBUG" \
    -DCMAKE_CXX_FLAGS="-O2 -DNDEBUG" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}/freerdp" \
    -DZLIB_LIBRARY="${INSTALL_DIR}/zlib/lib/libz.a" \
    -DZLIB_INCLUDE_DIR="${INSTALL_DIR}/zlib/include" \
    -DOPENSSL_ROOT_DIR="${INSTALL_DIR}/openssl" \
    -DOPENSSL_INCLUDE_DIR="${INSTALL_DIR}/openssl/include" \
    -DOPENSSL_CRYPTO_LIBRARY="${openssl_lib}/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="${openssl_lib}/libssl.a" \
    -DWITH_SERVER=OFF \
    -DWITH_SAMPLE=OFF \
    -DWITH_CLIENT=ON \
    -DWITH_CLIENT_COMMON=ON \
    -DWITH_CLIENT_INTERFACE=OFF \
    -DWITH_PROXY=OFF \
    -DWITH_SHADOW=OFF \
    -DWITH_CUPS=OFF \
    -DWITH_PULSE=OFF \
    -DWITH_ALSA=OFF \
    -DWITH_OSS=OFF \
    -DWITH_FFMPEG=OFF \
    -DWITH_SWSCALE=OFF \
    -DWITH_X11=OFF \
    -DWITH_WAYLAND=OFF \
    -DWITH_GSTREAMER_0_10=OFF \
    -DWITH_GSTREAMER_1_0=OFF \
    -DWITH_LIBSYSTEMD=OFF \
    -DWITH_PCSC=OFF \
    -DWITH_JPEG=OFF \
    -DWITH_OPENSLES=ON \
    -DOpenSLES_INCLUDE_DIR="${OHOS_NDK_HOME}/sysroot/usr/include" \
    -DOpenSLES_LIBRARY="${OHOS_NDK_HOME}/sysroot/usr/lib/aarch64-linux-ohos/libOpenSLES.so" \
    -DWITH_OPENH264=OFF \
    -DWITH_GSM=OFF \
    -DWITH_LAME=OFF \
    -DWITH_FAAD2=OFF \
    -DWITH_FAAC=OFF \
    -DWITH_SOXR=OFF \
    -DWITH_OPUS=OFF \
    -DWITH_PKCS11=OFF \
    -DWITH_ICU=OFF \
    -DWITH_KRB5=OFF \
    -DWITH_UNICODE_BUILTIN=ON \
    -DWITH_INTERNAL_RC4=ON \
    -DWITH_INTERNAL_MD4=ON \
    -DWITH_INTERNAL_MD5=ON \
    -DWITH_FUSE=OFF \
    -DWITH_CLIENT_SDL=OFF \
    -DWITH_MANPAGES=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DWITH_CHANNELS=ON \
    -DWITH_CLIENT_CHANNELS=ON \
    -DBUILTIN_CHANNELS=ON \
    -DWITH_CAIRO=OFF \
    -DWITH_SDL_IMAGE_DIALOGS=OFF \
    -DWITH_WEBVIEW=OFF \
    -DWITH_PLATFORM_SERVER=OFF \
    -DWITH_PROGRESS_BAR=OFF \
    -DWITH_SIMD=OFF \
    -DWITH_NEON=OFF \
    -DWITH_AAD=OFF \
    -DWITH_SMARTCARD=OFF \
    -DWITH_KEYBOARD_LAYOUT_FROM_FILE=OFF \
    -DCHANNEL_AUDIN=ON \
    -DCHANNEL_ENCOMSP=OFF \
    -DCHANNEL_RAIL=OFF \
    -DCHANNEL_REMDESK=OFF \
    -DCHANNEL_TELEMETRY=OFF \
    -DCHANNEL_URBDRC=OFF \
    -DCHANNEL_SMARTCARD=OFF \
    -DCHANNEL_CLIPRDR=ON \
    -DCHANNEL_RDPDR=ON \
    -DCHANNEL_RDPSND=ON \
    -DCHANNEL_RDPSND_CLIENT=ON \
    -DCHANNEL_DRDYNVC=ON \
    -DCHANNEL_DISP=ON \
    -DCHANNEL_RDPGFX=ON \
    -DCHANNEL_RDPEI=ON \
    -DCHANNEL_GEOMETRY=OFF \
    -DCHANNEL_VIDEO=OFF \
    -DWITH_WINPR_TOOLS=OFF \
    -DWITH_BINARY_VERSIONING=OFF \
    -DCMAKE_SKIP_INSTALL_RPATH=ON \
    2>&1 | tee "${LOG_DIR}/freerdp-cmake.log"

  cmake --build . --parallel "$(nproc)" 2>&1 | tee "${LOG_DIR}/freerdp-build.log"
  cmake --build . --target freerdp-client --parallel "$(nproc)" 2>&1 | tee "${LOG_DIR}/freerdp-client-build.log" || true

  local actual_lib
  actual_lib=$(find . -type f -name "libfreerdp-client*.so*" -size +100k | head -1 || true)
  if [[ -z "$actual_lib" ]]; then
    actual_lib=$(find . -type f -name "libfreerdp-client*.a" -size +100k | head -1 || true)
  fi

  if [[ -z "$actual_lib" ]]; then
    echo "ERROR: No valid client library found (>100KB)"
    exit 1
  fi

  local client_dir="client/common"
  mkdir -p "${client_dir}"
  if [[ "$actual_lib" == *.so* ]]; then
    local abs_actual
    abs_actual=$(readlink -f "$actual_lib")
    for target_name in libfreerdp-client3.so libfreerdp-client.so; do
      local target_path="${client_dir}/${target_name}"
      if [[ -f "$target_path" ]]; then
        local abs_target
        abs_target=$(readlink -f "$target_path")
        if [[ "$abs_actual" == "$abs_target" ]]; then
          continue
        fi
      fi
      cp -f "$actual_lib" "$target_path"
    done
  else
    local freerdp3_so
    local winpr3_so
    freerdp3_so=$(find . -name "libfreerdp3.so*" | head -1)
    winpr3_so=$(find . -name "libwinpr3.so*" | head -1)
    "$OHOS_CXX" -shared -o "${client_dir}/libfreerdp-client3.so" \
      -Wl,--whole-archive "$actual_lib" -Wl,--no-whole-archive \
      -L"$(dirname "$freerdp3_so")" -L"$(dirname "$winpr3_so")" \
      -lfreerdp3 -lwinpr3 -lOpenSLES -Wl,--allow-shlib-undefined
    cp "${client_dir}/libfreerdp-client3.so" "${client_dir}/libfreerdp-client.so"
  fi

  local install_lib_dir="${INSTALL_DIR}/freerdp/lib"
  mkdir -p "${install_lib_dir}"
  cp "${client_dir}/libfreerdp-client3.so" "${install_lib_dir}/"

  cmake --install . --prefix "${INSTALL_DIR}/freerdp"
  popd >/dev/null
}

build_napi() {
  log "Building NAPI wrapper"
  local napi_dir="${BUILD_DIR}/napi_build"
  rm -rf "$napi_dir"
  mkdir -p "$napi_dir"
  pushd "$napi_dir" >/dev/null

  cp "${ROOT_DIR}/entry/src/main/cpp/"*.c . 2>/dev/null || true
  cp "${ROOT_DIR}/entry/src/main/cpp/"*.cpp . 2>/dev/null || true
  cp "${ROOT_DIR}/entry/src/main/cpp/"*.h . 2>/dev/null || true

  local openssl_lib="${INSTALL_DIR}/openssl/lib"
  if [[ -d "${INSTALL_DIR}/openssl/lib64" ]]; then
    openssl_lib="${INSTALL_DIR}/openssl/lib64"
  fi

  local include_dirs
  include_dirs="-I${INSTALL_DIR}/freerdp/include \
    -I${INSTALL_DIR}/freerdp/include/freerdp3 \
    -I${INSTALL_DIR}/freerdp/include/winpr3 \
    -I${INSTALL_DIR}/openssl/include \
    -I${OHOS_NDK_HOME}/sysroot/usr/include"

  local cflags
  cflags="-fPIC -O2 -D__OHOS__=1 -DOHOS_PLATFORM -DWITH_OPENSSL"

  for f in *.c; do
    [[ -f "$f" ]] || continue
    "$OHOS_CC" -c "$f" -o "${f%.c}.o" $cflags $include_dirs
  done

  for f in *.cpp; do
    [[ -f "$f" ]] || continue
    "$OHOS_CXX" -c "$f" -o "${f%.cpp}.o" -std=c++17 -DNAPI_VERSION=8 $cflags $include_dirs \
      -I"${OHOS_NDK_HOME}/sysroot/usr/include/napi"
  done

  local objs
  objs=$(ls *.o 2>/dev/null | tr '\n' ' ')
  if [[ -n "$objs" ]]; then
    "$OHOS_CXX" -shared -o libfreerdp_harmonyos.so $objs \
      -fPIC \
      -L"${INSTALL_DIR}/freerdp/lib" \
      -lfreerdp-client3 \
      -lfreerdp3 \
      -lwinpr3 \
      -lOpenSLES \
      "${openssl_lib}/libssl.a" \
      "${openssl_lib}/libcrypto.a" \
      "${INSTALL_DIR}/zlib/lib/libz.a" \
      -Wl,--allow-shlib-undefined \
      -Wl,-rpath,'$ORIGIN'
  fi

  if [[ ! -f "libfreerdp_harmonyos.so" ]]; then
    echo "ERROR: libfreerdp_harmonyos.so not created"
    exit 1
  fi
  popd >/dev/null
}

collect_artifacts() {
  log "Collecting artifacts"
  rm -rf "${ARTIFACT_DIR}"
  mkdir -p "${ARTIFACT_DIR}"

  find "${INSTALL_DIR}/freerdp" -name "*.so*" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
  if [[ -f "${BUILD_DIR}/napi_build/libfreerdp_harmonyos.so" ]]; then
    cp "${BUILD_DIR}/napi_build/libfreerdp_harmonyos.so" "${ARTIFACT_DIR}/"
  fi

  pushd "${ARTIFACT_DIR}" >/dev/null
  for f in *.so*; do
    if [[ -L "$f" ]]; then
      local target
      target=$(readlink -f "$f")
      rm "$f"
      [[ -f "$target" ]] && cp "$target" "$(basename "$f")"
    fi
  done

  for f in *.so.*.*; do
    local base="${f%.*.*}"
    [[ ! -f "$base" && -f "$f" ]] && cp "$f" "$base"
  done

  "$OHOS_STRIP" --strip-unneeded *.so* 2>/dev/null || true

  cat > README.txt <<EOF2
FreeRDP HarmonyOS Libraries (local build)
Built: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
FreeRDP: ${FREERDP_VERSION}
OpenSSL: ${OPENSSL_VERSION} (static, TLS fully functional)
zlib: ${ZLIB_VERSION} (static)
Toolchain: OpenHarmony NDK (musl libc)
Target: arm64-v8a
EOF2
  popd >/dev/null

  log "Artifacts ready: ${ARTIFACT_DIR}"
}

build_zlib
build_openssl
clone_freerdp
patch_freerdp
build_freerdp
build_napi
collect_artifacts

log "Done"
