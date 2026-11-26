# Vendored from Zywz95/ponwrt-action (scripts/patch-airoha-xpon.py),
# invoked by Scripts/Inject-PON.sh during the PON (airoha) build.
# Kept verbatim so the idempotent anchors stay in sync with upstream.
#!/usr/bin/env python3
"""Idempotently apply the AN7583 XG-PON BWmap compatibility patch (Option A).

Modifies an OpenWrt `airoha-xpon` package directory in place:
  - src/airoha-xpon-regs.h: define AIROHA_XGPON_BWM_CHK_CTRL_STOCK (0x00820000)
  - src/airoha-xpon-xgpon.c: add read-only bool module_param `xgpon_stock_bwmap`
    and write AIROHA_XGPON_DBG_BWM_CHK_CTRL when enabled, anchored solely on
    `airoha_xgpon_write(xpon, AIROHA_XGPON_US_PROF_VLD, 0);`
  - src/airoha-xpon-diagnostics.c: expose bwmap_check_control/status in debugfs
  - Makefile: enable MODPARAMS:=xgpon_stock_bwmap=1 on AN7583 only, strictly
    guarded on `module_param(xgpon_stock_bwmap, ...)` existing in driver source

All checks and edits are computed in memory before writing any file so that a
missing anchor aborts cleanly with a non-zero exit code and zero partial edits.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

BWM_STOCK_MACRO = "AIROHA_XGPON_BWM_CHK_CTRL_STOCK"
BWM_STOCK_VALUE = "0x00820000"
AN7583_MODPARAMS_EXPR = "$(if $(CONFIG_TARGET_airoha_an7583),xgpon_stock_bwmap=1)"


class PatchError(RuntimeError):
    """Raised when an expected source file or anchor cannot be matched safely."""


def _find_matching_brace(text: str, open_idx: int) -> int:
    """Return the index of the '}' matching text[open_idx] == '{', skipping C comments/strings."""
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            i += 2
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "/" and nxt == "*":
            end = text.find("*/", i + 2)
            if end == -1:
                raise PatchError("Unterminated C block comment while scanning function body")
            i = end + 2
            continue
        if ch in ('"', "'"):
            quote = ch
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise PatchError("Unbalanced braces while scanning C function body")


def extract_function_body_span(text: str, func_name: str) -> tuple[int, int]:
    """Return (body_start, body_end_exclusive) for C function definition `func_name`."""
    pattern = re.compile(rf"\b{re.escape(func_name)}\s*\(")
    found: list[tuple[int, int]] = []
    for match in pattern.finditer(text):
        # Walk past balanced parameter list (...) to distinguish definitions from calls/prototypes.
        paren_depth = 0
        i = match.end() - 1
        n = len(text)
        while i < n:
            if text[i] == "(":
                paren_depth += 1
            elif text[i] == ")":
                paren_depth -= 1
                if paren_depth == 0:
                    i += 1
                    break
            i += 1
        else:
            continue

        # Skip whitespace and comments between ')' and '{' (or ';').
        while i < n:
            if text[i].isspace():
                i += 1
            elif text.startswith("//", i):
                nl = text.find("\n", i)
                i = n if nl == -1 else nl + 1
            elif text.startswith("/*", i):
                end = text.find("*/", i + 2)
                if end == -1:
                    raise PatchError(f"Unterminated comment after {func_name}()")
                i = end + 2
            else:
                break

        if i < n and text[i] == "{":
            close_idx = _find_matching_brace(text, i)
            found.append((i, close_idx + 1))

    if len(found) != 1:
        raise PatchError(
            f"Expected exactly 1 definition of {func_name}(), found {len(found)}"
        )
    return found[0]


def _require_single_match(pattern: str, text: str, label: str, flags: int = 0) -> re.Match[str]:
    matches = list(re.finditer(pattern, text, flags))
    if len(matches) != 1:
        raise PatchError(f"Expected exactly 1 match for {label}, found {len(matches)}")
    return matches[0]


def _has_xgpon_stock_bwmap_param(text: str) -> bool:
    return bool(re.search(r"\bmodule_param\s*\(\s*xgpon_stock_bwmap\b", text))


def patch_xgpon_c(text: str) -> tuple[str, str]:
    body_start, body_end = extract_function_body_span(
        text, "airoha_xpon_xgpon_start_control"
    )
    body = text[body_start:body_end]

    if re.search(
        r"\b(?:airoha_xgpon_(?:write|update_bits)|writel)\s*\([^;]*\bAIROHA_XGPON_DBG_BWM_CHK_CTRL\b",
        body,
    ):
        return (
            text,
            "skipped (airoha_xpon_xgpon_start_control already writes AIROHA_XGPON_DBG_BWM_CHK_CTRL)",
        )

    anchor = _require_single_match(
        r"^([ \t]*)airoha_xgpon_write\(xpon,\s*AIROHA_XGPON_US_PROF_VLD,\s*0\);[ \t]*$",
        body,
        "airoha_xgpon_write(xpon, AIROHA_XGPON_US_PROF_VLD, 0); in airoha_xpon_xgpon_start_control",
        flags=re.MULTILINE,
    )
    indent = anchor.group(1)
    injection = (
        f"\n{indent}if (xgpon_stock_bwmap)"
        f"\n{indent}\tairoha_xgpon_write(xpon, AIROHA_XGPON_DBG_BWM_CHK_CTRL,"
        f"\n{indent}\t                   {BWM_STOCK_MACRO});"
    )
    new_body = body[: anchor.end()] + injection + body[anchor.end() :]
    updated = text[:body_start] + new_body + text[body_end:]

    if not re.search(r"^\s*#\s*include\s*<linux/module\.h>\s*$", updated, re.MULTILINE):
        workqueue_inc = re.search(
            r"^#include\s+<linux/workqueue\.h>[ \t]*$", updated, re.MULTILINE
        )
        if workqueue_inc:
            updated = (
                updated[: workqueue_inc.start()]
                + "#include <linux/module.h>\n"
                + updated[workqueue_inc.start() :]
            )
        else:
            linux_incs = list(
                re.finditer(r"^#include\s+<linux/[^>]+>[ \t]*$", updated, re.MULTILINE)
            )
            if not linux_incs:
                raise PatchError(
                    "Could not find any #include <linux/...> anchor in airoha-xpon-xgpon.c"
                )
            last_inc = linux_incs[-1]
            updated = (
                updated[: last_inc.end()]
                + "\n#include <linux/module.h>"
                + updated[last_inc.end() :]
            )

    if not _has_xgpon_stock_bwmap_param(updated):
        if re.search(r"\bxgpon_stock_bwmap\b", updated[:body_start]):
            raise PatchError(
                "Found existing xgpon_stock_bwmap symbol without module_param in airoha-xpon-xgpon.c"
            )
        local_incs = list(
            re.finditer(r'^#include\s+"[^"]+"[ \t]*$', updated, re.MULTILINE)
        )
        if not local_incs:
            raise PatchError(
                'Could not find any local #include "..." anchor in airoha-xpon-xgpon.c'
            )
        last_local = local_incs[-1]
        param_block = (
            "\n\nstatic bool xgpon_stock_bwmap;"
            "\nmodule_param(xgpon_stock_bwmap, bool, 0444);"
            "\nMODULE_PARM_DESC("
            "\n\txgpon_stock_bwmap,"
            '\n\t"Use stock AN7583 XG-PON BWmap check control 0x00820000 (default: preserve inherited value)");'
        )
        updated = (
            updated[: last_local.end()] + param_block + updated[last_local.end() :]
        )

    return updated, "patched (added xgpon_stock_bwmap module_param and BWmap write)"


def patch_regs_h(text: str, needs_stock_macro: bool) -> tuple[str, str]:
    if re.search(
        rf"^\s*#\s*define\s+{re.escape(BWM_STOCK_MACRO)}\b", text, re.MULTILINE
    ):
        return text, f"skipped ({BWM_STOCK_MACRO} already defined)"

    if not needs_stock_macro:
        return text, "skipped (xgpon.c does not require AIROHA_XGPON_BWM_CHK_CTRL_STOCK)"

    anchor = _require_single_match(
        r"^#define\s+AIROHA_XGPON_BWM_O2349_CONTINUOUS_GRANT\b.*$",
        text,
        "AIROHA_XGPON_BWM_O2349_CONTINUOUS_GRANT in airoha-xpon-regs.h",
        flags=re.MULTILINE,
    )
    insertion = (
        "\n/* Stock AN7583 BWmap check baseline: optional grant filters disabled. */"
        f"\n#define {BWM_STOCK_MACRO} {BWM_STOCK_VALUE}"
    )
    updated = text[: anchor.end()] + insertion + text[anchor.end() :]
    return updated, f"patched (defined {BWM_STOCK_MACRO} = {BWM_STOCK_VALUE})"


def patch_diagnostics_c(text: str) -> tuple[str, str]:
    body_start, body_end = extract_function_body_span(text, "pon_mac_debug_show")
    body = text[body_start:body_end]

    if "bwmap_check_control" in body:
        return text, "skipped (bwmap_check_control already exposed in pon_mac_debug_show)"

    fmt_anchor = _require_single_match(
        r'^([ \t]*)"rx_error: 0x%08x\\n"[ \t]*$',
        body,
        '"rx_error: 0x%08x\\n" format line in pon_mac_debug_show',
        flags=re.MULTILINE,
    )
    arg_anchor = _require_single_match(
        r"^([ \t]*)airoha_xgpon_read\(xpon,\s*AIROHA_XGPON_RX_ERR_STS\),[ \t]*$",
        body,
        "AIROHA_XGPON_RX_ERR_STS read argument in pon_mac_debug_show",
        flags=re.MULTILINE,
    )

    fmt_indent = fmt_anchor.group(1)
    arg_indent = arg_anchor.group(1)

    fmt_insert = (
        f'\n{fmt_indent}"bwmap_check_control: 0x%08x\\n"'
        f'\n{fmt_indent}"bwmap_check_status: 0x%08x\\n"'
    )
    arg_insert = (
        f"\n{arg_indent}airoha_xgpon_read(xpon, AIROHA_XGPON_DBG_BWM_CHK_CTRL),"
        f"\n{arg_indent}airoha_xgpon_read(xpon, AIROHA_XGPON_DBG_BWM_CHK_STS),"
    )

    if fmt_anchor.end() >= arg_anchor.start():
        raise PatchError(
            "Unexpected order of format string and argument in pon_mac_debug_show"
        )

    new_body = (
        body[: fmt_anchor.end()]
        + fmt_insert
        + body[fmt_anchor.end() : arg_anchor.end()]
        + arg_insert
        + body[arg_anchor.end() :]
    )
    updated = text[:body_start] + new_body + text[body_end:]
    return updated, "patched (exposed bwmap_check_control and bwmap_check_status)"


def patch_makefile(text: str, has_module_param: bool) -> tuple[str, str]:
    if not has_module_param:
        return (
            text,
            "skipped (xgpon_stock_bwmap module_param not present; refusing to add MODPARAMS)",
        )

    pkg_block = _require_single_match(
        r"^define KernelPackage/airoha-xpon[ \t]*\n.*?^endef[ \t]*$",
        text,
        "define KernelPackage/airoha-xpon block in Makefile",
        flags=re.MULTILINE | re.DOTALL,
    )
    block = pkg_block.group(0)

    if re.search(r"^[ \t]*MODPARAMS(?:\.[^\s:=]+)?\s*[:+]?=.*\bxgpon_stock_bwmap=", block, re.MULTILINE):
        return text, "skipped (MODPARAMS already configures xgpon_stock_bwmap)"

    existing_modparams = list(
        re.finditer(r"^([ \t]*MODPARAMS\s*:=)(.*)$", block, re.MULTILINE)
    )
    if len(existing_modparams) > 1:
        raise PatchError("Found multiple MODPARAMS definitions in KernelPackage/airoha-xpon")

    if len(existing_modparams) == 1:
        m = existing_modparams[0]
        rhs = m.group(2).strip()
        new_line = (
            f"{m.group(1)}{rhs} {AN7583_MODPARAMS_EXPR}"
            if rhs
            else f"{m.group(1)}{AN7583_MODPARAMS_EXPR}"
        )
        new_block = block[: m.start()] + new_line + block[m.end() :]
    else:
        autoload = _require_single_match(
            r"^([ \t]*)AUTOLOAD:=.*$",
            block,
            "AUTOLOAD:= in KernelPackage/airoha-xpon",
            flags=re.MULTILINE,
        )
        indent = autoload.group(1)
        new_block = (
            block[: autoload.end()]
            + f"\n{indent}MODPARAMS:={AN7583_MODPARAMS_EXPR}"
            + block[autoload.end() :]
        )

    updated = text[: pkg_block.start()] + new_block + text[pkg_block.end() :]
    return updated, "patched (added AN7583-only MODPARAMS:=xgpon_stock_bwmap=1)"


def apply_patch(pkg_dir: Path) -> dict[str, str]:
    regs_path = pkg_dir / "src" / "airoha-xpon-regs.h"
    xgpon_path = pkg_dir / "src" / "airoha-xpon-xgpon.c"
    diag_path = pkg_dir / "src" / "airoha-xpon-diagnostics.c"
    makefile_path = pkg_dir / "Makefile"

    for path in (regs_path, xgpon_path, diag_path, makefile_path):
        if not path.is_file():
            raise PatchError(f"Required file not found: {path}")

    regs_orig = regs_path.read_text(encoding="utf-8")
    xgpon_orig = xgpon_path.read_text(encoding="utf-8")
    diag_orig = diag_path.read_text(encoding="utf-8")
    makefile_orig = makefile_path.read_text(encoding="utf-8")

    # Compute all changes in memory first so failures never leave partial writes.
    xgpon_new, xgpon_status = patch_xgpon_c(xgpon_orig)
    needs_stock_macro = bool(re.search(rf"\b{re.escape(BWM_STOCK_MACRO)}\b", xgpon_new))
    regs_new, regs_status = patch_regs_h(regs_orig, needs_stock_macro=needs_stock_macro)
    diag_new, diag_status = patch_diagnostics_c(diag_orig)

    has_module_param = _has_xgpon_stock_bwmap_param(xgpon_new)
    if not has_module_param:
        for other_c in sorted((pkg_dir / "src").glob("*.c")):
            if other_c == xgpon_path:
                continue
            if _has_xgpon_stock_bwmap_param(other_c.read_text(encoding="utf-8")):
                has_module_param = True
                break

    makefile_new, makefile_status = patch_makefile(
        makefile_orig, has_module_param=has_module_param
    )

    writes = [
        (regs_path, regs_orig, regs_new),
        (xgpon_path, xgpon_orig, xgpon_new),
        (diag_path, diag_orig, diag_new),
        (makefile_path, makefile_orig, makefile_new),
    ]
    for path, orig, new in writes:
        if new != orig:
            path.write_text(new, encoding="utf-8", newline="\n")

    return {
        "src/airoha-xpon-regs.h": regs_status,
        "src/airoha-xpon-xgpon.c": xgpon_status,
        "src/airoha-xpon-diagnostics.c": diag_status,
        "Makefile": makefile_status,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Idempotently patch airoha-xpon with AN7583 XG-PON BWmap Option A support."
    )
    parser.add_argument(
        "pkg_dir",
        type=Path,
        help="Path to the airoha-xpon package directory (e.g. feeds/pon_drivers/airoha-xpon)",
    )
    args = parser.parse_args(argv)

    try:
        results = apply_patch(args.pkg_dir)
    except PatchError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    for rel_path, status in results.items():
        print(f"airoha-xpon/{rel_path}: {status}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
