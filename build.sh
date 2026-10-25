#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export IOS_TOOLCHAIN_ROOT="${IOS_TOOLCHAIN_ROOT:-/opt/ios-toolchain}"
source "$IOS_TOOLCHAIN_ROOT/env.sh"
mkdir -p build
for source in src/DNVOTClient.mm src/DNVOTController.mm src/Hooks.mm; do
  clang++ --target=arm64-apple-ios16.0 -isysroot "$IOS_SDK" \
    -isystem "$IOS_SDK/usr/include/c++/v1" -std=c++17 -stdlib=libc++ \
    -fobjc-arc -fblocks -fvisibility=hidden -O2 -Wall -Wextra -Werror \
    -c "$source" -o "build/$(basename "$source" .mm).o"
done
ld64.lld -dylib -arch arm64 -platform_version ios 16.0 16.4 \
  -syslibroot "$IOS_SDK" build/DNVOTClient.o build/DNVOTController.o build/Hooks.o \
  -lc++ -lobjc -lSystem -framework Foundation -framework UIKit \
  -framework AVFoundation -framework CoreMedia -framework CoreGraphics \
  -install_name @rpath/DNYouTubeVOT.dylib -adhoc_codesign -fatal_warnings -no_uuid \
  -o build/DNYouTubeVOT.dylib
file build/DNYouTubeVOT.dylib
llvm-objdump --macho --dylibs-used build/DNYouTubeVOT.dylib > build/dependencies.txt
cat build/dependencies.txt
