// Disable LeakSanitizer at build time (ASan/UBSan stay on). Weak so a harness that already defines
// the hook (fuzz_parse_expr.C, fuzz_typecheck_expr.C) takes precedence without a duplicate symbol.
extern "C" __attribute__((weak)) int __lsan_is_turned_off() { return 1; }
