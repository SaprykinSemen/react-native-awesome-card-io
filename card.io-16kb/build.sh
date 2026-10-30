#!/usr/bin/env bash
# Перезбирає нативні бібліотеки card.io Android SDK 5.5.1 під 16 KB page size
# і складає AAR io.card:android-sdk:5.5.1-16kb у android/local-maven.
#
# Потрібно: git, curl, unzip, zip, python3, Android SDK з NDK r27 та cmake 3.22.1 (з ninja).
# Використання:  ./card.io-16kb/build.sh
# Змінні (необов'язкові): ANDROID_HOME, NDK_VERSION, CMAKE_VERSION, WORK_DIR
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
NDK_VERSION="${NDK_VERSION:-27.1.12297006}"
CMAKE_VERSION="${CMAKE_VERSION:-3.22.1}"
WORK_DIR="${WORK_DIR:-$HERE/.build}"

CARDIO_VERSION="5.5.1"
OUT_VERSION="5.5.1-16kb"
CARDIO_SRC_COMMIT="339a3ce7a47804a5924a365aa3594ed945a2fccf"
CARDIO_DMZ_COMMIT="0aac4a0546261030509f1b712f09f269e8fe7e9b"
OPENCV_VERSION="2.4.13.7"
ABIS=(arm64-v8a x86_64)

NDK="$ANDROID_HOME/ndk/$NDK_VERSION"
CMAKE_BIN="$ANDROID_HOME/cmake/$CMAKE_VERSION/bin"
case "$(uname -s)" in
  Darwin) HOST_TAG="darwin-x86_64" ;;
  Linux)  HOST_TAG="linux-x86_64" ;;
  *) echo "Непідтримувана ОС"; exit 1 ;;
esac
LLVM_BIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"

for p in "$NDK" "$CMAKE_BIN/cmake" "$CMAKE_BIN/ninja"; do
  [ -e "$p" ] || { echo "Не знайдено: $p"; exit 1; }
done

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "== 1/6 Сирці card.io"
if [ ! -d card.io-Android-source ]; then
  git clone https://github.com/card-io/card.io-Android-source.git
fi
cd card.io-Android-source
git checkout -q --force "$CARDIO_SRC_COMMIT"
git submodule update --init --recursive
(cd card.io/src/main/jni/card.io-dmz && git checkout -q --force "$CARDIO_DMZ_COMMIT")
# повертаємо чистий стан (на випадок повторного запуску) і накладаємо патчі
git checkout -q -- card.io/src/main/jni/Application.mk card.io/src/main/jni/Android.mk
(cd card.io/src/main/jni/card.io-dmz && git checkout -q -- .)
git apply "$HERE/patches/card.io-Android-source.patch"
(cd card.io/src/main/jni/card.io-dmz && git apply "$HERE/patches/card.io-dmz.patch")
JNI="$PWD/card.io/src/main/jni"
cd "$WORK_DIR"

echo "== 2/6 OpenCV $OPENCV_VERSION"
if [ ! -d "opencv-$OPENCV_VERSION" ]; then
  curl -fsSL -o "opencv-$OPENCV_VERSION.tar.gz" \
    "https://github.com/opencv/opencv/archive/refs/tags/$OPENCV_VERSION.tar.gz"
  tar xzf "opencv-$OPENCV_VERSION.tar.gz"
fi

echo "== 3/6 Збірка OpenCV core + imgproc (16 KB)"
CV_MODULES_OFF=""
for m in apps calib3d contrib features2d flann gpu highgui legacy ml nonfree objdetect ocl photo \
         stitching superres ts video videostab java python world androidcamera dynamicuda viz; do
  CV_MODULES_OFF="$CV_MODULES_OFF -DBUILD_opencv_$m=OFF"
done
for ABI in "${ABIS[@]}"; do
  BUILD="cvbuild-$ABI"
  mkdir -p "$BUILD"
  (
    cd "$BUILD"
    # shellcheck disable=SC2086
    "$CMAKE_BIN/cmake" -G Ninja -DCMAKE_MAKE_PROGRAM="$CMAKE_BIN/ninja" \
      -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI="$ABI" -DANDROID_PLATFORM=android-21 -DANDROID_STL=c++_static \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON $CV_MODULES_OFF \
      -DBUILD_opencv_core=ON -DBUILD_opencv_imgproc=ON \
      -DBUILD_EXAMPLES=OFF -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_DOCS=OFF \
      -DBUILD_ANDROID_EXAMPLES=OFF -DBUILD_ANDROID_SERVICE=OFF -DBUILD_PACKAGE=OFF \
      -DBUILD_ZLIB=ON -DBUILD_JPEG=OFF -DBUILD_PNG=OFF -DBUILD_TIFF=OFF -DBUILD_JASPER=OFF -DBUILD_OPENEXR=OFF \
      -DWITH_CUDA=OFF -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF -DWITH_IPP=OFF -DWITH_JASPER=OFF \
      -DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_TIFF=OFF -DWITH_OPENEXR=OFF -DWITH_EIGEN=OFF \
      -DWITH_TBB=OFF -DWITH_OPENCL=OFF -DWITH_OPENMP=OFF -DWITH_PTHREADS_PF=OFF \
      -DCMAKE_CXX_FLAGS="-std=gnu++11" \
      -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "../opencv-$OPENCV_VERSION" > cmake.log
    "$CMAKE_BIN/ninja" opencv_core opencv_imgproc > ninja.log
  )
  mkdir -p "$JNI/lib/$ABI"
  for l in core imgproc; do
    cp "$BUILD/lib/$ABI/libopencv_$l.so" "$JNI/lib/$ABI/"
    "$LLVM_BIN/llvm-strip" --strip-unneeded "$JNI/lib/$ABI/libopencv_$l.so"
  done
done

echo "== 4/6 ndk-build card.io"
(
  cd "$JNI/.."
  "$NDK/ndk-build" NDK_PROJECT_PATH=. APP_BUILD_SCRIPT=jni/Android.mk \
    NDK_APPLICATION_MK=jni/Application.mk NDK_LIBS_OUT=./built/libs NDK_OUT=./built/obj -j8 > "$WORK_DIR/ndk-build.log"
)
BUILT="$JNI/../built/libs"

echo "== 5/6 Складання AAR"
OFFICIAL="$WORK_DIR/official"
rm -rf "$OFFICIAL" && mkdir -p "$OFFICIAL"
curl -fsSL -o "$OFFICIAL/android-sdk-$CARDIO_VERSION.aar" \
  "https://repo1.maven.org/maven2/io/card/android-sdk/$CARDIO_VERSION/android-sdk-$CARDIO_VERSION.aar"
curl -fsSL -o "$OFFICIAL/android-sdk-$CARDIO_VERSION.pom" \
  "https://repo1.maven.org/maven2/io/card/android-sdk/$CARDIO_VERSION/android-sdk-$CARDIO_VERSION.pom"
(
  cd "$OFFICIAL"
  mkdir aar && cd aar && unzip -q "../android-sdk-$CARDIO_VERSION.aar"
  for ABI in "${ABIS[@]}"; do
    rm -f "jni/$ABI/"*.so
    cp "$BUILT/$ABI/"*.so "jni/$ABI/"
  done
)
DEST="$REPO_ROOT/android/local-maven/io/card/android-sdk/$OUT_VERSION"
mkdir -p "$DEST"
rm -f "$DEST/android-sdk-$OUT_VERSION.aar"
(cd "$OFFICIAL/aar" && zip -qr -X "$DEST/android-sdk-$OUT_VERSION.aar" .)
sed "s#<version>$CARDIO_VERSION</version>#<version>$OUT_VERSION</version>#" \
  "$OFFICIAL/android-sdk-$CARDIO_VERSION.pom" > "$DEST/android-sdk-$OUT_VERSION.pom"

echo "== 6/6 Перевірка вирівнювання"
CHECK="$WORK_DIR/check"
rm -rf "$CHECK" && mkdir -p "$CHECK" && cd "$CHECK"
unzip -q "$DEST/android-sdk-$OUT_VERSION.aar" 'jni/*'
FAIL=0
for ABI in "${ABIS[@]}"; do
  for f in jni/$ABI/*.so; do
    ALIGN="$("$LLVM_BIN/llvm-readelf" -lW "$f" | awk '/LOAD/{print $NF}' | sort -u | tr '\n' ' ')"
    echo "$f $ALIGN"
    [ "$ALIGN" = "0x4000 " ] || FAIL=1
  done
done
[ "$FAIL" = 0 ] || { echo "ПОМИЛКА: не всі .so вирівняні під 16 KB"; exit 1; }
echo "Готово: $DEST"
