#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
g++ -std=c++17 -Wall -Wextra -Werror -fsanitize=undefined -fno-sanitize-recover=all tests/core_tests.cpp -o build/core_tests
./build/core_tests
python3 tests/protobuf_parity.py
python3 tools/check_repository.py
export IOS_TOOLCHAIN_ROOT="${IOS_TOOLCHAIN_ROOT:-/opt/ios-toolchain}"
source "$IOS_TOOLCHAIN_ROOT/env.sh"
python3 tools/verify_macho.py build/DNYouTubeVOT.dylib > build/macho-verification.json
python3 tools/verify_macho.py build/DNYouTubeVOTProbe.dylib > build/probe-verification.json
