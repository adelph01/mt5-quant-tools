#!/usr/bin/env python3
"""mt5_setfile_inspector.py — MetaTrader 5 `.set` File Linter, Diff & UTF-16 LE Sanitizer.

Detects silent MetaTrader 5 `.set` pitfalls that cause EAs to fall back to compiled defaults:
  1. INI `[Section]` headers (silently ignored by MT5).
  2. Strategy Tester optimization step remnants (`value||start||step||stop||Y`).
  3. Duplicate input keys.
  4. Missing Stop-Loss (`0`) or aggressive martingale lot multipliers (`> 1.25`).
  5. Side-by-side parameter diff between two `.set` files, plus clean `UTF-16 LE BOM` export.

Usage:
    python python/mt5_setfile_inspector.py my_strategy.set
    python python/mt5_setfile_inspector.py v1.set v2.set
    python python/mt5_setfile_inspector.py messy.set --clean-out clean_mt5.set
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys


def decode_setfile_bytes(raw: bytes) -> tuple[str, str]:
    if raw.startswith(b"\xff\xfe"):
        return raw[2:].decode("utf-16-le", errors="replace"), "UTF-16 LE (BOM)"
    if raw.startswith(b"\xfe\xff"):
        return raw[2:].decode("utf-16-be", errors="replace"), "UTF-16 BE (BOM)"
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw[3:].decode("utf-8", errors="replace"), "UTF-8 (BOM)"
    return raw.decode("utf-8", errors="replace"), "UTF-8 (no BOM)"


def inspect_setfile(path: Path) -> dict:
    text, encoding_label = decode_setfile_bytes(path.read_bytes())
    params: dict[str, str] = {}
    warnings: list[str] = []
    optimizer_Meta_count = 0

    for line_no, raw_line in enumerate(text.splitlines(), 1):
        s = raw_line.strip()
        if not s or s.startswith(";"):
            continue
        if s.startswith("[") and s.endswith("]"):
            warnings.append(
                f"Line {line_no}: INI section header '{s}' detected — MetaTrader 5 ignores INI sections."
            )
            continue
        if "=" not in s:
            warnings.append(f"Line {line_no}: Malformed line without '=' ('{s[:50]}').")
            continue

        key, raw_val = s.split("=", 1)
        key = key.strip()
        val = raw_val.strip()

        if "||" in val:
            optimizer_Meta_count += 1
            val = val.split("||", 1)[0].strip()

        if key in params:
            warnings.append(f"Line {line_no}: Duplicate key '{key}' overwrites earlier value '{params[key]}'.")
        params[key] = val

        low_k = key.lower()
        try:
            num = float(val)
            if ("sl" in low_k or "stoploss" in low_k) and "trail" not in low_k and num == 0.0:
                warnings.append(f"Risk check: '{key}=0' — zero Stop-Loss detected.")
            if ("mult" in low_k or "martingale" in low_k) and num > 1.25:
                warnings.append(
                    f"Risk check: '{key}={val}' — lot multiplier > 1.25 detected (Prop-Firm drawdown hazard)."
                )
        except ValueError:
            pass

    if optimizer_Meta_count > 0:
        warnings.append(
            f"Info: {optimizer_Meta_count} parameter(s) contain Strategy Tester '||start||step||stop' ranges."
        )

    return {
        "path": str(path),
        "encoding": encoding_label,
        "params": params,
        "warnings": warnings,
    }


def write_clean_utf16le_setfile(params: dict[str, str], out_path: Path) -> None:
    """Write a strict MT5-compliant UTF-16 LE with BOM `.set` file (`key=value\\r\\n`, no sections/comments)."""
    body = "".join(f"{k}={v}\r\n" for k, v in params.items())
    out_path.write_bytes(b"\xff\xfe" + body.encode("utf-16-le"))


def diff_setfiles(p1: dict[str, str], p2: dict[str, str]) -> list[tuple[str, str | None, str | None]]:
    all_keys = sorted(set(p1.keys()) | set(p2.keys()))
    diffs: list[tuple[str, str | None, str | None]] = []
    for k in all_keys:
        v1 = p1.get(k)
        v2 = p2.get(k)
        if v1 != v2:
            diffs.append((k, v1, v2))
    return diffs


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Inspect, lint, diff, and sanitize MetaTrader 5 .set files.")
    parser.add_argument("primary_set", type=Path, help="Primary .set file")
    parser.add_argument("compare_set", type=Path, nargs="?", default=None, help="Optional second .set file to diff")
    parser.add_argument("--clean-out", type=Path, default=None, help="Export sanitized UTF-16 LE BOM .set file")
    args = parser.parse_args(argv)

    r1 = inspect_setfile(args.primary_set)
    print(f"=== MT5 Setfile Inspector : {args.primary_set.name} ===")
    print(f"  Encoding : {r1['encoding']}")
    print(f"  Inputs   : {len(r1['params'])} parameters parsed")
    if r1["warnings"]:
        print("  Diagnostics:")
        for w in r1["warnings"]:
            print(f"    [!] {w}")
    else:
        print("  Diagnostics: [OK] Clean key=value structure, zero warnings.")

    if args.compare_set is not None:
        r2 = inspect_setfile(args.compare_set)
        changes = diff_setfiles(r1["params"], r2["params"])
        print(f"\n=== Parameter Diff : {args.primary_set.name} vs {args.compare_set.name} ({len(changes)} changes) ===")
        for k, v1, v2 in changes:
            print(f"  {k:<28} : {v1 if v1 is not None else '<missing>'}  ->  {v2 if v2 is not None else '<missing>'}")

    if args.clean_out is not None:
        write_clean_utf16le_setfile(r1["params"], args.clean_out)
        print(f"\n  [OK] Clean UTF-16 LE BOM .set written to: {args.clean_out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
