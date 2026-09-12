{
  stdenv,
  lib,
  llvmPackages,
  gnumake,
  toyboxSource,
  muslSource,
  writeText,
}:

let
  bridgeHeader = writeText "latent-toybox.h" ''
    #ifndef LATENT_TOYBOX_H
    #define LATENT_TOYBOX_H

    #include <limits.h>
    #include <stddef.h>
    #include <stdint.h>
    #include <stdarg.h>

    struct arg_list { struct arg_list *next; char *arg; };
    struct toy_list {
      char *name;
      void (*toy_main)(void);
      char *options;
      unsigned flags;
    };
    struct toy_context {
      struct toy_list *which;
      char **argv;
      char **optargs;
      unsigned long long optflags;
      int optc;
      short toycount;
      char exitval;
      char wasroot;
      void *rebound;
      struct arg_list *xexit;
      void *stacktop;
      int envc;
      int old_umask;
      short signal;
      int signalfd;
    };

    extern struct toy_context toys;
    extern char toybuf[4096], libbuf[4096];

    #define GLOBALS(...)
    #define ARRAY_LEN(array) (sizeof(array) / sizeof(*(array)))
    #define FLAG(flag) (!!(toys.optflags & FLAG_ ## flag))
    #define FORCED_FLAG 1LL
    #define FLOAT double
    #define NULL ((void *)0)
    #define FLAGS_NODASH (1ULL << 63)
    #define CFG_TOYBOX_FLOAT 0
    #define CFG_TOYBOX_DEBUG 0
    #define CFG_TOYBOX_FREE 1
    #define O_RDONLY 0
    #define O_CLOEXEC 0x80000
    #define SEEK_CUR 1
    #define write latent_write
    #define open latent_open
    #define read latent_read
    #define close latent_close
    #define lseek latent_lseek
    #define puts latent_puts
    #define printf latent_printf
    #define sprintf latent_sprintf

    #include "generated/globals.h"
    extern union global_union this;
    #include "generated/flags.h"

    void *malloc(size_t);
    void *calloc(size_t, size_t);
    void *realloc(void *, size_t);
    void free(void *);
    void *memset(void *, int, size_t);
    void *memcpy(void *, const void *, size_t);
    void *memmove(void *, const void *, size_t);
    size_t strlen(const char *);
    int strcmp(const char *, const char *);
    int strncmp(const char *, const char *, size_t);
    char *strchr(const char *, int);
    char *strrchr(const char *, int);
    char *strcpy(char *, const char *);
    long strtol(const char *, char **, int);
    double strtod(const char *, char **);
    int ispunct(int);
    char *basename(char *);
    char *dirname(char *);
    int puts(const char *);
    int printf(const char *, ...);
    int sprintf(char *, const char *, ...);
    int open(const char *, int, ...);
    long read(int, void *, size_t);
    long write(int, const void *, size_t);
    int close(int);
    long lseek(int, long, int);

    void get_optflags(void);
    void check_help(char **);
    void error_exit(char *, ...);
    void help_exit(char *, ...);
    void *xmalloc(size_t);
    void *xzalloc(size_t);
    long atolx(char *);
    long long xparsemillitime(char *);
    int stridx(char *, int);
    void llist_traverse(void *, void (*)(void *));
    char *strend(char *, char *);
    void loopfiles(char **, void (*)(int, char *));
    void xwrite(int, const void *, size_t);
    void xputc(char);
    void xprintf(char *, ...);
    void perror_msg_raw(char *);

    char **latent_arguments(const unsigned char *, uint32_t);
    void latent_begin(void);
    void latent_prepare(struct toy_list *, char **);
    void latent_set_filesystem(uint64_t);

    #endif
  '';

  bridgeSource = writeText "latent-toybox.c" ''
    #include "latent_toybox.h"

    struct toy_context toys;
    union global_union this;
    char toybuf[4096], libbuf[4096];

    enum {
      LATENT_ARGUMENT_BYTES = 4096,
      LATENT_ARGUMENT_COUNT = 64,
      LATENT_OUTPUT_BYTES = 65536,
    };

    static char argument_bytes[LATENT_ARGUMENT_BYTES];
    static char *argument_vector[LATENT_ARGUMENT_COUNT + 1];
    static char output[LATENT_OUTPUT_BYTES];
    static size_t output_length;
    static uint64_t active_filesystem;

    struct latent_file {
      unsigned char *contents;
      size_t length;
      size_t offset;
    };
    static struct latent_file open_files[16];

    extern int64_t latent_fs_size(uint64_t, uint64_t, uint32_t);
    extern int64_t latent_fs_copy(
      uint64_t, uint64_t, uint32_t, uint64_t, uint64_t
    );

    void *memset(void *pointer, int value, size_t length) {
      unsigned char *bytes = pointer;
      while (length--) *bytes++ = (unsigned char)value;
      return pointer;
    }

    void *memcpy(void *destination, const void *source, size_t length) {
      unsigned char *out = destination;
      const unsigned char *in = source;
      while (length--) *out++ = *in++;
      return destination;
    }

    void *memmove(void *destination, const void *source, size_t length) {
      unsigned char *out = destination;
      const unsigned char *in = source;
      if (out < in) {
        while (length--) *out++ = *in++;
      } else {
        out += length;
        in += length;
        while (length--) *--out = *--in;
      }
      return destination;
    }

    size_t strlen(const char *text) {
      const char *end = text;
      while (*end) ++end;
      return (size_t)(end - text);
    }

    int strcmp(const char *left, const char *right) {
      while (*left && *left == *right) ++left, ++right;
      return *(const unsigned char *)left - *(const unsigned char *)right;
    }

    int strncmp(const char *left, const char *right, size_t length) {
      while (length && *left && *left == *right) ++left, ++right, --length;
      if (!length) return 0;
      return *(const unsigned char *)left - *(const unsigned char *)right;
    }

    char *strchr(const char *text, int character) {
      for (;;) {
        if (*text == character) return (char *)text;
        if (!*text) return 0;
        ++text;
      }
    }

    char *strrchr(const char *text, int character) {
      const char *found = 0;
      do {
        if (*text == character) found = text;
      } while (*text++);
      return (char *)found;
    }

    char *strcpy(char *destination, const char *source) {
      char *start = destination;
      while ((*destination++ = *source++));
      return start;
    }

    static void emit(const char *text, size_t length) {
      size_t available = sizeof(output) - output_length;
      if (length > available) length = available;
      memcpy(output + output_length, text, length);
      output_length += length;
    }

    int puts(const char *text) {
      emit(text, strlen(text));
      emit("\n", 1);
      return 0;
    }

    static int emit_format(const char *format, va_list arguments) {
      int written = 0;
      while (*format) {
        const char *literal = format;
        while (*format && *format != '%') ++format;
        emit(literal, (size_t)(format - literal));
        written += (int)(format - literal);
        if (!*format) break;

        ++format;
        if (*format == 's') {
          const char *text = va_arg(arguments, const char *);
          size_t length = strlen(text);
          emit(text, length);
          written += (int)length;
        } else if (*format == 'c') {
          char character = (char)va_arg(arguments, int);
          emit(&character, 1);
          ++written;
        } else if (*format == '%') {
          emit("%", 1);
          ++written;
        }
        if (*format) ++format;
      }
      return written;
    }

    int printf(const char *format, ...) {
      va_list arguments;
      va_start(arguments, format);
      int written = emit_format(format, arguments);
      va_end(arguments);
      return written;
    }

    int sprintf(char *buffer, const char *format, ...) {
      (void)buffer;
      (void)format;
      return 0;
    }

    void *xmalloc(size_t length) {
      void *pointer = malloc(length);
      if (!pointer) __builtin_trap();
      return pointer;
    }

    void *xzalloc(size_t length) {
      void *pointer = xmalloc(length);
      memset(pointer, 0, length);
      return pointer;
    }

    void check_help(char **arguments) { (void)arguments; }
    void error_exit(char *format, ...) { (void)format; __builtin_trap(); }
    void help_exit(char *format, ...) { (void)format; __builtin_trap(); }

    int stridx(char *text, int character) {
      char *found = strchr(text, character);
      return found ? (int)(found - text) : -1;
    }

    long strtol(const char *text, char **end, int base) {
      long value = 0;
      int negative = 0;
      (void)base;
      if (*text == '-') negative = 1, ++text;
      while (*text >= '0' && *text <= '9') value = value * 10 + *text++ - '0';
      if (end) *end = (char *)text;
      return negative ? -value : value;
    }

    long atolx(char *text) { return strtol(text, 0, 10); }
    long long xparsemillitime(char *text) { return atolx(text); }
    double strtod(const char *text, char **end) {
      if (end) *end = (char *)text;
      return 0;
    }

    int ispunct(int character) {
      int number = character >= '0' && character <= '9';
      int upper = character >= 'A' && character <= 'Z';
      int lower = character >= 'a' && character <= 'z';
      return character > 32 && character < 127 && !(number || upper || lower);
    }

    void llist_traverse(void *list, void (*function)(void *)) {
      struct arg_list *node = list;
      while (node) {
        struct arg_list *next = node->next;
        function(node);
        node = next;
      }
    }

    char *strend(char *text, char *suffix) {
      size_t text_length = strlen(text);
      size_t suffix_length = strlen(suffix);
      if (text_length < suffix_length) return 0;
      char *candidate = text + text_length - suffix_length;
      return strcmp(candidate, suffix) ? 0 : candidate;
    }

    void latent_set_filesystem(uint64_t handle) {
      active_filesystem = handle;
    }

    int open(const char *path, int flags, ...) {
      (void)flags;
      size_t path_length = strlen(path);
      int64_t length = latent_fs_size(
        active_filesystem,
        (uint64_t)(uintptr_t)path,
        (uint32_t)path_length
      );
      if (length < 0) return -1;

      for (int index = 0; index < 16; ++index) {
        if (open_files[index].contents) continue;
        size_t allocation = length ? (size_t)length : 1;
        unsigned char *contents = malloc(allocation);
        if (!contents) return -1;
        int64_t copied = latent_fs_copy(
          active_filesystem,
          (uint64_t)(uintptr_t)path,
          (uint32_t)path_length,
          (uint64_t)(uintptr_t)contents,
          (uint64_t)length
        );
        if (copied != length) {
          free(contents);
          return -1;
        }
        open_files[index].contents = contents;
        open_files[index].length = (size_t)length;
        open_files[index].offset = 0;
        return index + 3;
      }
      return -1;
    }

    long read(int descriptor, void *buffer, size_t length) {
      if (descriptor == 0) return 0;
      int index = descriptor - 3;
      if (index < 0 || index >= 16 || !open_files[index].contents) return -1;
      size_t available = open_files[index].length - open_files[index].offset;
      if (length > available) length = available;
      memcpy(
        buffer,
        open_files[index].contents + open_files[index].offset,
        length
      );
      open_files[index].offset += length;
      return (long)length;
    }

    long write(int descriptor, const void *buffer, size_t length) {
      if (descriptor != 1 && descriptor != 2) return -1;
      emit(buffer, length);
      return (long)length;
    }

    int close(int descriptor) {
      int index = descriptor - 3;
      if (index < 0 || index >= 16 || !open_files[index].contents) return -1;
      free(open_files[index].contents);
      memset(&open_files[index], 0, sizeof(open_files[index]));
      return 0;
    }

    long lseek(int descriptor, long offset, int origin) {
      int index = descriptor - 3;
      if (origin != SEEK_CUR || index < 0 || index >= 16) return -1;
      long next = (long)open_files[index].offset + offset;
      if (next < 0 || (size_t)next > open_files[index].length) return -1;
      open_files[index].offset = (size_t)next;
      return next;
    }

    void xwrite(int descriptor, const void *buffer, size_t length) {
      if (write(descriptor, buffer, length) != (long)length) __builtin_trap();
    }

    void xputc(char character) { xwrite(1, &character, 1); }

    void xprintf(char *format, ...) {
      va_list arguments;
      va_start(arguments, format);
      emit_format(format, arguments);
      va_end(arguments);
    }

    void perror_msg_raw(char *path) {
      xprintf("%s: unavailable\n", path);
      toys.exitval = 1;
    }

    void loopfiles(char **arguments, void (*function)(int, char *)) {
      if (!*arguments) {
        function(0, "-");
        return;
      }
      for (; *arguments; ++arguments) {
        int descriptor = !strcmp(*arguments, "-") ? 0 : open(*arguments, O_RDONLY);
        if (descriptor < 0) {
          perror_msg_raw(*arguments);
          continue;
        }
        function(descriptor, *arguments);
        if (descriptor > 0) close(descriptor);
      }
    }

    char **latent_arguments(const unsigned char *encoded, uint32_t length) {
      if (!length || length > sizeof(argument_bytes) || encoded[length - 1]) return 0;
      memcpy(argument_bytes, encoded, length);

      size_t count = 0;
      argument_vector[count++] = argument_bytes;
      for (size_t index = 0; index + 1 < length; ++index) {
        if (!argument_bytes[index]) {
          if (count == LATENT_ARGUMENT_COUNT) return 0;
          argument_vector[count++] = argument_bytes + index + 1;
        }
      }
      argument_vector[count] = 0;
      return argument_vector;
    }

    void latent_begin(void) {
      output_length = 0;
      for (int index = 0; index < 16; ++index) {
        if (open_files[index].contents) close(index + 3);
      }
    }

    void latent_prepare(struct toy_list *specification, char **arguments) {
      memset(&toys, 0, sizeof(toys));
      memset(&this, 0, sizeof(this));
      toys.which = specification;
      toys.argv = arguments;
      get_optflags();
    }

    uint64_t latent_output_ptr(void) {
      return (uint64_t)(uintptr_t)output;
    }

    uint32_t latent_output_len(void) { return (uint32_t)output_length; }
  '';
in
stdenv.mkDerivation {
  pname = "latent-toybox-userspace";
  version = "0.8.13";
  src = toyboxSource;

  nativeBuildInputs = [
    gnumake
    llvmPackages.clang-unwrapped
    llvmPackages.llvm
  ];

  configurePhase = ":";

  buildPhase = ''
    runHook preBuild

    patchShebangs scripts

    cat > miniconfig <<'EOF'
    CONFIG_TOYBOX=y
    CONFIG_BASENAME=y
    CONFIG_CAT=y
    CONFIG_DIRNAME=y
    CONFIG_HEAD=y
    EOF
    KCONFIG_ALLCONFIG="$PWD/miniconfig" make allnoconfig
    make toybox

    cp ${bridgeHeader} latent_toybox.h
    cp ${bridgeSource} latent_toybox.c
    cp toys/posix/basename.c basename.c
    cp toys/posix/cat.c cat.c
    cp toys/posix/dirname.c dirname.c
    cp toys/posix/head.c head.c
    cp lib/args.c args.c
    sed -i 's/#include "toys.h"/#include "latent_toybox.h"/' \
      basename.c cat.c dirname.c head.c args.c

    cat >> basename.c <<'EOF'
    int latent_invoke_basename(const unsigned char *encoded, uint32_t length) {
      char **arguments = latent_arguments(encoded, length);
      if (!arguments) return 2;
      static struct toy_list specification = {
        "basename", basename_main, OPTSTR_basename, 0
      };
      latent_begin();
      latent_prepare(&specification, arguments);
      basename_main();
      free(toys.optargs);
      return toys.exitval;
    }
    EOF

    cat >> dirname.c <<'EOF'
    int latent_invoke_dirname(const unsigned char *encoded, uint32_t length) {
      char **arguments = latent_arguments(encoded, length);
      if (!arguments) return 2;
      static struct toy_list specification = {
        "dirname", dirname_main, OPTSTR_dirname, 0
      };
      latent_begin();
      latent_prepare(&specification, arguments);
      dirname_main();
      free(toys.optargs);
      return toys.exitval;
    }
    EOF

    cat >> cat.c <<'EOF'
    int latent_invoke_cat(const unsigned char *encoded, uint32_t length) {
      char **arguments = latent_arguments(encoded, length);
      if (!arguments) return 2;
      static struct toy_list specification = {
        "cat", cat_main, OPTSTR_cat, 0
      };
      latent_begin();
      latent_prepare(&specification, arguments);
      cat_main();
      free(toys.optargs);
      return toys.exitval;
    }
    EOF

    cat >> head.c <<'EOF'
    int latent_invoke_head(const unsigned char *encoded, uint32_t length) {
      char **arguments = latent_arguments(encoded, length);
      if (!arguments) return 2;
      static struct toy_list specification = {
        "head", head_main, OPTSTR_head, 0
      };
      latent_begin();
      latent_prepare(&specification, arguments);
      head_main();
      free(toys.optargs);
      return toys.exitval;
    }
    EOF

    tar --wildcards -xOf ${muslSource} '*/src/misc/basename.c' \
      | sed '/^#include/d; /weak_alias/d' > musl_basename.c
    tar --wildcards -xOf ${muslSource} '*/src/misc/dirname.c' \
      | sed '/^#include/d' > musl_dirname.c
    sed -i '1i#include "latent_toybox.h"' musl_basename.c musl_dirname.c

    for source in \
      latent_toybox args basename cat dirname head musl_basename musl_dirname
    do
      clang --target=wasm64-unknown-unknown -O2 -ffreestanding \
        -fno-builtin -fno-exceptions -I. -c "$source.c" -o "$source.o"
      clang -O2 -ffreestanding -fno-builtin -fno-exceptions \
        -I. -c "$source.c" -o "$source.native.o"
    done
    llvm-ar rcs liblatent-userspace.a \
      latent_toybox.o args.o basename.o cat.o dirname.o head.o \
      musl_basename.o musl_dirname.o
    llvm-ar rcs liblatent-userspace-native.a \
      latent_toybox.native.o args.native.o basename.native.o cat.native.o \
      dirname.native.o head.native.o musl_basename.native.o musl_dirname.native.o

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p "$out/lib" "$out/share/licenses/latent-userspace"
    cp liblatent-userspace.a liblatent-userspace-native.a "$out/lib/"
    cp LICENSE "$out/share/licenses/latent-userspace/toybox-0BSD"
    tar --wildcards -xOf ${muslSource} '*/COPYRIGHT' \
      > "$out/share/licenses/latent-userspace/musl-COPYRIGHT"
  '';

  meta.license = with lib.licenses; [
    bsd0
    mit
  ];
}
