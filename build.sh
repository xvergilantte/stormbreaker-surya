#!/bin/bash
#
# Compile script for Mjolnir kernel
# Copyright (C) 2020-2021 Adithya R.

set -euo pipefail

trap 'printf "\nInterrupted.\n"; exit 1' INT

WD="$(pwd)"
ZIPNAME="Mjolnir-surya-$(date '+%d%m%Y-%H%M').zip"
DEFCONFIG="surya-perf_defconfig"

GCC64_DIR="$WD/tc/gcc-arm64"
GCC32_DIR="$WD/tc/gcc-arm"
GCC64_DOWNLOAD_URL="https://github.com/xvergilantte/gcc-arm64"
GCC32_DOWNLOAD_URL="https://github.com/xvergilantte/gcc-arm"

AK3_DIR="$WD/AnyKernel3"
AK3_URL="https://github.com/xvergilantte/AnyKernel3"
MKDT_DIR="$WD/libufdt"
MKDT_URL="https://android.googlesource.com/platform/system/libufdt"

if git rev-parse --is-inside-work-tree &>/dev/null; then
	SHA=$(git rev-parse --verify HEAD)
	ZIPNAME="${ZIPNAME::-4}-${SHA:0:8}.zip"
fi

if [ ! -d "$GCC64_DIR" ] || [ ! -d "$GCC32_DIR" ]; then
	if [ ! -d "$GCC64_DIR" ]; then
		printf "Downloading Eva GCC arm64 %s...\n"
		mkdir -p "$GCC64_DIR"
		git clone --depth=1 -b gcc-master "$GCC64_DOWNLOAD_URL" "$GCC64_DIR"
	fi

	if [ ! -d "$GCC32_DIR" ]; then
		printf "Downloading Eva GCC arm %s...\n"
		mkdir -p "$GCC32_DIR"
        git clone --depth=1 -b gcc-master "$GCC32_DOWNLOAD_URL" "$GCC32_DIR"
	fi
fi

if [ ! -d "$AK3_DIR" ]; then
	printf "Cloning AnyKernel3 to %s...\n" "$AK3_DIR"
	git clone --depth=1 -b Mjolnir "$AK3_URL" "$AK3_DIR"
fi

if [ ! -d "$MKDT_DIR" ]; then
    printf "Cloning mkdtboimg script to %s...\n" "$MKDT_DIR"
    git clone --depth=1 "$MKDT_URL" "$MKDT_DIR"
fi

KBUILD_COMPILER_STRING="$("$GCC64_DIR/bin/aarch64-elf-gcc" --version | head -n1)"
PATH="$GCC64_DIR/bin:$GCC32_DIR/bin:$PATH"

export KBUILD_COMPILER_STRING PATH

MAKE=(
	make
	CROSS_COMPILE="aarch64-elf-"
	CROSS_COMPILE_ARM32="arm-eabi-"
	LD="$GCC64_DIR/bin/aarch64-elf-ld"
	AR="aarch64-elf-gcc-ar"
	AS="aarch64-elf-as"
	NM="aarch64-elf-nm"
	OBJDUMP="aarch64-elf-objdump"
	OBJCOPY="aarch64-elf-objcopy"
	CC="aarch64-elf-gcc"
	LLVM=0
	LLVM_IAS=0
)

if [[ ${1:-} == -r || ${1:-} == --regen ]]; then
	"${MAKE[@]}" Surya-stock_defconfig savedefconfig
	cp out/defconfig arch/arm64/configs/Surya-stock_defconfig
	"${MAKE[@]}" $DEFCONFIG savedefconfig
	cp out/defconfig arch/arm64/configs/$DEFCONFIG
	printf "\nSuccessfully regenerated defconfig at %s\n" $DEFCONFIG
	exit
fi

if [[ ${1:-} == -rf || ${1:-} == --regen-full ]]; then
	"${MAKE[@]}" Surya-stock_defconfig
	cp out/.config arch/arm64/configs/Surya-stock_defconfig
	"${MAKE[@]}" $DEFCONFIG
	cp out/.config arch/arm64/configs/$DEFCONFIG
	printf "\nSuccessfully regenerated full defconfig at %s\n" $DEFCONFIG
	exit
fi

CLEAN="false"
LTO="false"
NOKSU="false"

for arg in "$@"; do
	case $arg in
	-c | --clean)
		CLEAN="true"
		;;
	-l | --lto)
		LTO="true"
		;;
	-s | --suoff)
		NOKSU="true"
		;;
	*)
		printf "Unknown argument: %s\n" "$arg"
		exit 1
		;;
	esac
done

if [[ $CLEAN == "true" ]]; then
	printf "Cleaning output directory...\n"
	rm -rf out
fi

printf "Building surya defconfig...\n"
"${MAKE[@]}" $DEFCONFIG

if [[ $LTO == "true" ]]; then
	printf "Building with LTO enabled...\n"
	scripts/config --file out/.config -e LTO -d LTO_NONE -e LTO_CLANG
	"${MAKE[@]}" olddefconfig
fi

if [[ $NOKSU == "true" ]]; then
	printf "Building without KernelSU variant...\n"
	scripts/config --file out/.config -d KSU
	"${MAKE[@]}" olddefconfig
fi

printf "\n"
SECONDS=0
"${MAKE[@]}" -j"$(nproc --all)" |& tee buildlog.txt || exit ${PIPESTATUS[0]}
BUILD_TIME=$SECONDS

python3 "libufdt/utils/src/mkdtboimg.py" \
create "out/arch/arm64/boot/dtbo.img" --page_size=4096 out/arch/arm64/boot/dts/qcom/*.dtbo

kernel="out/arch/arm64/boot/Image.gz-dtb"
dtbo="out/arch/arm64/boot/dtbo.img"

if [ ! -f "$kernel" ] || [ ! -f "$dtbo" ]; then
	printf "\nMissing build artifacts, aborting.\n"
	exit 1
fi

printf "\nKernel compiled successfully! Zipping up...\n"
cp "$kernel" "$dtbo" "$AK3_DIR"
cd "$AK3_DIR"
zip -r9 "../$ZIPNAME" ./* -x .git modules\* patch\* ramdisk\* README.md \*placeholder &>/dev/null
rm -f Image.gz dtbo.img
cd ..
printf "\nCompleted in %d minute(s) and %d second(s)!\n" $((BUILD_TIME / 60)) $((BUILD_TIME % 60))
printf "Zip: %s\n" "$ZIPNAME"
