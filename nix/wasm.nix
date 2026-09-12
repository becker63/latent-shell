{
  stdenv,
  lib,
  mojo,
  llvmPackages,
  mojoJson,
  wasiLibcSource,
  compilerRtSource,
  userspace,
  wasmTools,
  writeText,
}:

let
  # wasi-libc carries a WebAssembly-tuned dlmalloc. Its public WASI headers are
  # wasm32-only, so compile the width-independent allocator core over the small
  # memory64 substrate below instead of importing a WASI runtime.
  runtimeSource = writeText "latent-wasm-runtime.c" ''
    #include <stddef.h>
    #include <stdint.h>

    enum { LATENT_INPUT_CAPACITY = 512 * 1024 };
    static unsigned char latent_input[LATENT_INPUT_CAPACITY]
        __attribute__((aligned(16)));

    uint64_t shell_input_ptr(void) { return (uint64_t)(uintptr_t)latent_input; }
    uint32_t shell_input_capacity(void) { return LATENT_INPUT_CAPACITY; }

    extern char __heap_end;
    static uintptr_t heap_break;

    static void *latent_morecore(ptrdiff_t increment) {
        const uintptr_t page = 65536;
        if (heap_break == 0)
            heap_break = (uintptr_t)&__heap_end;
        if (increment == 0)
            return (void *)heap_break;
        if (increment < 0 || (uintptr_t)increment > UINTPTR_MAX - heap_break)
            return (void *)-1;

        uintptr_t old = heap_break;
        uintptr_t next = old + (uintptr_t)increment;
        uintptr_t memory_end =
            (uintptr_t)__builtin_wasm_memory_size(0) * page;
        if (next > memory_end) {
            uintptr_t pages = (next - memory_end + page - 1) / page;
            if (__builtin_wasm_memory_grow(0, pages) == SIZE_MAX)
                return (void *)-1;
        }
        heap_break = next;
        return (void *)old;
    }

    static void *latent_memset(void *destination, int value, size_t size) {
        unsigned char *bytes = (unsigned char *)destination;
        for (size_t index = 0; index < size; ++index)
            bytes[index] = (unsigned char)value;
        return destination;
    }

    static void *latent_memcpy(void *destination, const void *source, size_t size) {
        unsigned char *out = (unsigned char *)destination;
        const unsigned char *in = (const unsigned char *)source;
        for (size_t index = 0; index < size; ++index)
            out[index] = in[index];
        return destination;
    }

    #define HAVE_MMAP 0
    #define HAVE_MORECORE 1
    #define MORECORE latent_morecore
    #define MORECORE_CONTIGUOUS 1
    #define MORECORE_CANNOT_TRIM 1
    #define USE_LOCKS 0
    #define ABORT __builtin_trap()
    #define LACKS_TIME_H 1
    #define LACKS_ERRNO_H 1
    #define LACKS_STDLIB_H 1
    #define LACKS_STRING_H 1
    #define LACKS_STRINGS_H 1
    #define LACKS_UNISTD_H 1
    #define LACKS_SYS_TYPES_H 1
    #define LACKS_SYS_PARAM_H 1
    #define LACKS_SCHED_H 1
    #define NO_MALLINFO 1
    #define NO_MALLOC_STATS 1
    #define MALLOC_ALIGNMENT 16
    #define USE_DL_PREFIX 1
    #define DLMALLOC_EXPORT static
    #define MALLOC_FAILURE_ACTION
    #define EINVAL 22
    #define ENOMEM 12
    #define memset latent_memset
    #define memcpy latent_memcpy
    #include "${wasiLibcSource}/dlmalloc/src/malloc.c"

    void *KGEN_CompilerRT_AlignedAlloc(uint64_t alignment, uint64_t size) {
        if (alignment < 16)
            alignment = 16;
        if ((alignment & (alignment - 1)) != 0)
            return 0;
        return dlmemalign((size_t)alignment, (size_t)size);
    }

    void KGEN_CompilerRT_AlignedFree(void *pointer) { dlfree(pointer); }

    void *malloc(size_t size) { return dlmalloc(size); }
    void *calloc(size_t count, size_t size) { return dlcalloc(count, size); }
    void *realloc(void *pointer, size_t size) {
        return dlrealloc(pointer, size);
    }
    void free(void *pointer) { dlfree(pointer); }

    uint64_t KGEN_CompilerRT_GetStackTrace(void *buffer, uint64_t capacity) {
        (void)buffer;
        (void)capacity;
        return 0;
    }

    __attribute__((noreturn)) static void unavailable(void) {
        __builtin_trap();
    }

    int64_t write(int64_t descriptor, const void *buffer, int64_t size) {
        (void)descriptor;
        (void)buffer;
        (void)size;
        unavailable();
    }
    int dup(int descriptor) { (void)descriptor; unavailable(); }
    uint64_t fdopen(int descriptor, const void *mode) {
        (void)descriptor;
        (void)mode;
        unavailable();
    }
    int fflush(uint64_t stream) { (void)stream; unavailable(); }
    int fclose(uint64_t stream) { (void)stream; unavailable(); }
    int KGEN_CompilerRT_fprintf(uint64_t stream, const void *format, ...) {
        (void)stream;
        (void)format;
        unavailable();
    }
  '';
in
stdenv.mkDerivation {
  pname = "latent-shell-wasm";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = ../shell;
  };
  nativeBuildInputs = [
    mojo
    llvmPackages.clang-unwrapped
    llvmPackages.llvm
    llvmPackages.lld
    wasmTools
  ];

  buildPhase = ''
    export MODULAR_CACHE_DIR="$TMPDIR"
    export HOME="$TMPDIR"
    ulimit -c 0
    mkdir -p build

    # Mojo 1.0 has no registered WASM target. Generic x86-64 IR preserves the
    # 64-bit layout and avoids the ARM-specific intrinsics in the native stdlib.
    mojo build shell/wasm.mojo -I shell -I ${mojoJson} \
      --target-triple x86_64-unknown-linux-gnu --target-cpu x86-64 \
      --emit llvm -o build/native.ll

    # Bridge LLVM 24's printed IR to pinned LLVM 21. Lifetime markers and the
    # removed attribute are optimization hints, not runtime operations. Keep
    # the exact floating-point bit patterns when translating new literal syntax.
    sed -E \
      -e 's/nocreateundeforpoison //g' \
      -e '/(call|declare) void @llvm.lifetime\.(start|end)\.p0/d' \
      -e 's/"target-cpu"="[^"]*"/"target-cpu"="generic"/g' \
      -e 's/"target-features"="[^"]*"//g' \
      -e 's/(^|[[:space:]])\+inf([,[:space:]]|$)/\10x7FF0000000000000\2/g' \
      -e 's/(^|[[:space:]])-inf([,[:space:]]|$)/\10xFFF0000000000000\2/g' \
      -e 's/\+nan\(0x7FFFFFFFFFFFF\)/0x7FF7FFFFFFFFFFFF/g' \
      build/native.ll > build/compatible.ll

    opt -mtriple=wasm64-unknown-unknown -passes='default<O2>' -S \
      build/compatible.ll -o build/optimized.ll
    llc -mtriple=wasm64-unknown-unknown -mcpu=generic \
      -mattr=+simd128,+bulk-memory,+sign-ext -filetype=obj \
      build/optimized.ll -o build/shell.o

    clang --target=wasm64-unknown-unknown -O2 -ffreestanding \
      -fno-exceptions -mbulk-memory -c ${runtimeSource} -o build/runtime.o
    clang --target=wasm64-unknown-unknown -O2 -ffreestanding \
      -I${compilerRtSource}/compiler-rt/lib/builtins \
      -c ${compilerRtSource}/compiler-rt/lib/builtins/multi3.c \
      -o build/multi3.o

    wasm-ld -mwasm64 --no-entry --export-memory \
      --max-memory=67108864 -z stack-size=1048576 \
      --export=shell_input_ptr --export=shell_input_capacity \
      --export=shell_init --export=shell_eval \
      --export=shell_complete --export=shell_history \
      --export=shell_result_ptr --export=shell_result_len \
      build/shell.o ${userspace}/lib/liblatent-userspace.a \
      build/runtime.o build/multi3.o -o build/shell.wasm

    wasm-tools validate build/shell.wasm
    if wasm-tools print build/shell.wasm | grep -q '^  (import '; then
      echo "shell.wasm must not import host capabilities" >&2
      wasm-tools print build/shell.wasm | grep '^  (import ' >&2
      exit 1
    fi
  '';

  installPhase = ''
    mkdir -p "$out"
    cp build/shell.wasm "$out/shell.wasm"
  '';
}
