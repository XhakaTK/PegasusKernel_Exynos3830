#!/usr/bin/env bash

# Build do PegasusKernel (Exynos 850 / a12s): ponto de entrada unico. Carrega
# dependencia e toolchain, compila e coleta Image/Image.gz, System.map e
# .config em out/. O comportamento sai de variaveis de ambiente:
# VARIANT (e|p), DEFCONFIG, JOBS, CLANG_DIR e DEVICE_TARGET.

set -e

SECONDS=0
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$ROOT_DIR/out"
TC_DIR="$ROOT_DIR/toolchains"
# O clang mora em toolchains/ (repo XhakaTK/toolchains); CLANG_DIR no ambiente
# sobrescreve.
TOOLS_DIR="$TC_DIR/build/kernel/build-tools/path/linux-x86"
CLANG_DIR=${CLANG_DIR:-"$TC_DIR/clang/host/linux-x86/clang-r614150"}

DEVICE_TARGET=${DEVICE_TARGET:-"a12s"}
DEFCONFIG=${DEFCONFIG:-"exynos850-${DEVICE_TARGET}_defconfig"}
JOBS=${JOBS:-$(nproc --all)}
CODENAME=$(cat "$ROOT_DIR/codename" 2>/dev/null || echo "PegasusKernel")
# e = selinux enforcing, p = permissive (o defconfig salvo ja vem permissive).
VARIANT=${VARIANT:-"p"}

export TERM=xterm
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
reset='\033[0m'

msg() { echo -e "${blue}INFO: ${reset}$1"; }
error() {
    echo -e "${red}ERROR: ${reset}$1"
    exit 1
}

# --- Dependencias do host ---
setup_deps() {
    local deps=(
        aptitude bc bison ccache cpio curl flex git kmod libelf-dev
        libssl-dev lz4 perl python-is-python3 python3 tar unzip wget
        zlib1g-dev zip zstd
        gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
        gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi
    )
    sudo apt update -y
    sudo apt install "${deps[@]}" -y
}

# --- Toolchain (repo XhakaTK/toolchains; o clang vem do GitHub Release) ---
# toolchains/ nao e mais submodulo: o repo e leve (README + fetch-clang.sh)
# porque o GitHub recusa arquivos >100 MB, e o clang (~3,8 GB) vive como
# asset de Release. --fetch-toolchains clona o repo e baixa o clang.
_setup_toolchain() {
    msg "Clonando toolchains (main)..."
    rm -rf "$TC_DIR"
    git clone --depth 1 --single-branch -b main \
        https://github.com/XhakaTK/toolchains.git "$TC_DIR" \
        || error "Falha ao clonar o toolchains."
    [ -x "$CLANG_DIR/bin/clang" ] || {
        case "$CLANG_DIR" in
        "$TC_DIR"/*)
            msg "Baixando $(basename "$CLANG_DIR") do Release..."
            "$TC_DIR/fetch-clang.sh" "$(basename "$CLANG_DIR")" \
                || error "Falha ao baixar o clang."
            ;;
        esac
    }
    [ -x "$CLANG_DIR/bin/clang" ] || error "clang nao esta em $CLANG_DIR/bin."
    msg "Toolchain pronta em $TC_DIR"
}

setup_toolchain() {
    if [ "$UPDATE_TOOLCHAINS" = "true" ]; then
        msg "Limpando cache antigo do toolchain.."
        rm -rf "$TC_DIR"
        [ -d ~/.ccache ] && rm -rf ~/.ccache
    fi
    if [ ! -x "$CLANG_DIR/bin/clang" ]; then
        _setup_toolchain
    else
        msg "Toolchain ja existe em $TC_DIR"
    fi
}

# --- Regenerar o defconfig salvo ---
regen_defconfig() {
    msg "Gerando defconfig minimo para $DEVICE_TARGET..."
    make $MAKE_ARGS "$DEFCONFIG"
    make $MAKE_ARGS savedefconfig
    msg "defconfig gerado em $(pwd)/defconfig (compare com arch/arm64/configs/${DEFCONFIG})"
}

# --- Variante do selinux ---
# Mexe no defconfig salvo do trabalho: deixe o arquivo limpo depois de
# construir uma variante (git checkout -- arch/arm64/configs/<defconfig>).
apply_variant() {
    local conf="arch/arm64/configs/$DEFCONFIG" permissive=y
    case "$VARIANT" in
        e|enforcing) VARIANT_SLUG=en; permissive=n ;;
        p|permissive) VARIANT_SLUG=per ;;
        *) error "VARIANT invalido: $VARIANT (use e ou p)" ;;
    esac
    if [ "$permissive" = y ]; then
        "$ROOT_DIR/scripts/config" --file "$conf" -e SECURITY_SELINUX_ALWAYS_PERMISSIVE
    else
        "$ROOT_DIR/scripts/config" --file "$conf" -d SECURITY_SELINUX_ALWAYS_PERMISSIVE
    fi
}

export PATH="$CLANG_DIR/bin:$TOOLS_DIR:$PATH"

# Tudo fica no lld, kernel e ferramentas de build. Mold nao serve para o kernel:
# o "man mold" diz que ele implementa so o minimo de SECTIONS/INPUT que o
# libc.so precisa, e o primeiro link aborta com "unknown linker script token".
MAKE_ARGS="ARCH=arm64 CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
HOSTCC=clang HOSTCXX=clang++ HOSTAR=llvm-ar HOSTLD=ld.lld \
CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
CLANG_TRIPLE=aarch64-linux-gnu- LLVM=1 LLVM_IAS=1"

case "$1" in
"--setup-deps")
    setup_deps
    exit 0
    ;;
"--fetch-toolchains")
    setup_toolchain
    exit 0
    ;;
"--clean")
    msg "Limpando..."
    rm -rf "$OUT_DIR"
    make $MAKE_ARGS clean
    exit 0
    ;;
"--regen-defconfig")
    regen_defconfig
    exit 0
    ;;
"")
    ;;
*)
    DEFCONFIG=$1
    ;;
esac

# --- Ambiente de build ---
export KBUILD_BUILD_USER="PegasusKernel"
export KBUILD_BUILD_HOST="pegasus-lab"
export ARCH=arm64
# Estes dois viram macro de compilacao: TARGET_SOC no nanohub (-DTARGET_SOC) e
# PLATFORM_VERSION no SCSC (SCSC_SEP_VERSION). Nao sao ruido do Android.
export TARGET_SOC=s5e3830
export PLATFORM_VERSION=13
export CC=clang
export LD=ld.lld
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
export CLANG_TRIPLE=aarch64-linux-gnu-
export KCFLAGS=-w
export CONFIG_SECTION_MISMATCH_WARN_ONLY=y

# Sem menu: alvo e defconfig vem do ambiente (DEVICE_TARGET/DEFCONFIG) ou do
# argumento, e o default ja e a12s.

apply_variant

COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "untracked")
BUILD_DETAILS="${CODENAME}-${DEVICE_TARGET}-$(date +%Y%m%d)_${COMMIT_HASH}-NIGHTLY"

msg "Compilando $DEFCONFIG para $DEVICE_TARGET com $JOBS jobs (linker: ld.lld, variante $VARIANT_SLUG)..."
mkdir -p "$OUT_DIR/arch/arm64/boot"

make $MAKE_ARGS "$DEFCONFIG"
make $MAKE_ARGS -j"$JOBS"

[ -f arch/arm64/boot/Image ] || error "Compilacao falhou! Image nao encontrado."

msg "Kernel compilada! Coletando artefatos..."
cp arch/arm64/boot/Image arch/arm64/boot/Image.gz "$OUT_DIR/arch/arm64/boot/"
cp System.map "$OUT_DIR/"
cp .config "$OUT_DIR/.config"

for f in Image Image.gz; do
    printf '%-10s %12s bytes\n' "$f" "$(stat -c %s "$OUT_DIR/arch/arm64/boot/$f")"
done

echo -e "\n${green}Build $BUILD_DETAILS concluido em $((SECONDS / 60)) minuto(s)!${reset}"
msg "Artefatos: $OUT_DIR/arch/arm64/boot"
