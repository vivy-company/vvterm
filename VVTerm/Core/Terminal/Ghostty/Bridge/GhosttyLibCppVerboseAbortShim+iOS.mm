#include <TargetConditionals.h>

#if TARGET_OS_IPHONE
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

// Ghostty's current libc++ usage can reference __libcpp_verbose_abort, which
// doesn't exist on older iOS 16 runtimes. Export a compatible fallback so the
// app can launch on those systems instead of failing in dyld.
extern "C" __attribute__((visibility("default"), noreturn))
void vvterm_libcpp_verbose_abort(const char *format, ...) __asm("__ZNSt3__122__libcpp_verbose_abortEPKcz");

extern "C" __attribute__((visibility("default"), noreturn))
void vvterm_libcpp_verbose_abort(const char *format, ...) {
    va_list args;
    va_start(args, format);

    if (format != nullptr) {
        vfprintf(stderr, format, args);
        fputc('\n', stderr);
    }

    va_end(args);
    abort();
}
#endif
