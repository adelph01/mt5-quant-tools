#!/usr/bin/env python3
"""mt5_csv_to_parquet.py — Fast MetaTrader 5 Tick CSV -> Zstd Parquet Converter & Spread Auditor.

100% Polars (fast Rust-backed columnar engine). Supports both:
  - CSV files exported by `Azimuth_Tick_Audit_Exporter.mq5` (`#AZIMUTH_META:v=1;...` UTF-8)
  - Native MetaTrader 5 `Symbols -> Ticks -> Export` files (`UTF-16 LE` or `UTF-8` TSV)

Usage:
    pip install polars
    python python/mt5_csv_to_parquet.py Azimuth_EURUSD_TICKS_20261117.csv
    python python/mt5_csv_to_parquet.py EURUSD_ticks.csv --pip-size 0.0001 -o EURUSD.parquet
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

import polars as pl


def parse_azimuth_meta(raw_header_line: str) -> dict[str, str]:
    """Extract key=value metadata from `#AZIMUTH_META:v=1;symbol=EURUSD;...` if present."""
    if not raw_header_line.startswith("#AZIMUTH_META:"):
        return {}
    body = raw_header_line.split(":", 1)[1].strip()
    meta: dict[str, str] = {}
    for part in body.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            meta[k.strip().lower()] = v.strip()
    return meta


def read_mt5_tick_csv_bytes(csv_path: Path) -> tuple[bytes, dict[str, str]]:
    """Normalize UTF-16 LE/BE BOM or UTF-8 BOM to clean UTF-8 bytes and extract `#AZIMUTH_META`."""
    raw = csv_path.read_bytes()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        text = raw.decode("utf-16")
        utf8_bytes = text.encode("utf-8")
    elif raw.startswith(b"\xef\xbb\xbf"):
        utf8_bytes = raw[3:]
    else:
        utf8_bytes = raw

    first_newline = utf8_bytes.find(b"\n")
    first_line = (
        utf8_bytes[:first_newline].decode("utf-8", errors="replace").strip()
        if first_newline > 0
        else ""
    )
    meta = parse_azimuth_meta(first_line)
    return utf8_bytes, meta


def infer_pip_size(meta: dict[str, str], explicit_pip: float | None) -> float:
    if explicit_pip and explicit_pip > 0:
        return explicit_pip
    digits = int(meta.get("digits", "5") or "5")
    point = float(meta.get("point", "0") or "0")
    if point > 0:
        return point * 10.0 if digits in (3, 5) else point
    return 0.01 if digits in (2, 3) else 0.0001


def convert_and_audit_ticks(
    csv_path: Path,
    out_parquet: Path | None = None,
    pip_size: float | None = None,
) -> dict[str, float | int | str]:
    utf8_bytes, meta = read_mt5_tick_csv_bytes(csv_path)
    pip = infer_pip_size(meta, pip_size)

    raw_df = pl.read_csv(
        utf8_bytes,
        separator="\t",
        comment_prefix="#",
        infer_schema_length=2000,
        ignore_errors=True,
    )

    col_map = {c: c.strip().strip("<>").lower() for c in raw_df.columns}
    df = raw_df.rename(col_map)

    if not {"date", "time", "bid", "ask"}.issubset(set(df.columns)):
        raise ValueError(
            f"Expected columns <DATE>, <TIME>, <BID>, <ASK> (found: {list(df.columns)})"
        )

    vol_expr = (
        pl.col("volume").cast(pl.Int64, strict=False).fill_null(0)
        if "volume" in df.columns
        else (
            pl.col("tickvol").cast(pl.Int64, strict=False).fill_null(0)
            if "tickvol" in df.columns
            else pl.lit(0, dtype=pl.Int64)
        )
    )

    clean_df = (
        df.with_columns(
            pl.concat_str([pl.col("date"), pl.lit(" "), pl.col("time")])
            .str.strptime(pl.Datetime("ms"), "%Y.%m.%d %H:%M:%S%.3f", strict=False)
            .alias("dt"),
            pl.col("bid").cast(pl.Float64, strict=False).alias("bid"),
            pl.col("ask").cast(pl.Float64, strict=False).alias("ask"),
            vol_expr.alias("volume"),
        )
        .filter(pl.col("dt").is_not_null() & (pl.col("bid") > 0) & (pl.col("ask") > 0))
        .sort("dt")
        .with_columns(
            pl.col("dt").dt.epoch("ms").alias("timestamp_ms"),
            ((pl.col("ask") - pl.col("bid")) / pip).alias("spread_pips"),
            pl.col("dt").dt.hour().alias("hour"),
            pl.col("dt").dt.minute().alias("minute"),
        )
    )

    total_rows = clean_df.height
    if total_rows == 0:
        raise ValueError(f"Zero valid Bid/Ask tick rows parsed from {csv_path}")

    inverted_count = clean_df.filter(pl.col("ask") < pl.col("bid")).height

    london_df = clean_df.filter((pl.col("hour") >= 7) & (pl.col("hour") < 12))
    rollover_df = clean_df.filter(
        (pl.col("hour") == 23) | ((pl.col("hour") == 0) & (pl.col("minute") <= 15))
    )

    london_med = float(
        (london_df if london_df.height > 0 else clean_df)
        .select(pl.col("spread_pips").median())
        .item()
        or 0.0
    )
    roll_p95 = float(
        (rollover_df if rollover_df.height > 0 else clean_df)
        .select(pl.col("spread_pips").quantile(0.95))
        .item()
        or 0.0
    )
    roll_max = float(
        (rollover_df if rollover_df.height > 0 else clean_df)
        .select(pl.col("spread_pips").max())
        .item()
        or 0.0
    )
    ref = london_med if london_med > 0.05 else 0.10
    widening_ratio = round(roll_p95 / ref, 2)

    target_parquet = out_parquet or csv_path.with_suffix(".parquet")
    export_df = clean_df.select(["timestamp_ms", "bid", "ask", "volume"])
    export_df.write_parquet(target_parquet, compression="zstd")

    csv_mb = csv_path.stat().st_size / (1024 * 1024)
    pq_mb = target_parquet.stat().st_size / (1024 * 1024)

    return {
        "symbol": meta.get("symbol", csv_path.stem),
        "rows": total_rows,
        "inverted_quotes": inverted_count,
        "london_median_pips": round(london_med, 2),
        "rollover_p95_pips": round(roll_p95, 2),
        "rollover_max_pips": round(roll_max, 2),
        "rollover_widening_x": widening_ratio,
        "csv_mb": round(csv_mb, 2),
        "parquet_mb": round(pq_mb, 2),
        "parquet_path": str(target_parquet),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Convert MT5 real tick CSV into Zstd Parquet + audit rollover spreads (Polars)."
    )
    parser.add_argument("csv_file", type=Path, help="Input MT5 tick CSV file")
    parser.add_argument("-o", "--output", type=Path, default=None, help="Output .parquet path")
    parser.add_argument("--pip-size", type=float, default=None, help="Override pip size (e.g. 0.0001)")
    args = parser.parse_args(argv)

    summary = convert_and_audit_ticks(args.csv_file, args.output, args.pip_size)
    print("====================================================================")
    print(f" MT5 TICK PARQUET CONVERSION & ROLLOVER AUDIT ({summary['symbol']})")
    print("====================================================================")
    print(f"  Ticks processed          : {summary['rows']:,}")
    print(f"  Inverted quotes (Ask<Bid): {summary['inverted_quotes']}")
    print(f"  London median spread     : {summary['london_median_pips']:.2f} pips")
    print(f"  Rollover P95 (23:00-00:15): {summary['rollover_p95_pips']:.2f} pips (Max: {summary['rollover_max_pips']:.2f} pips)")
    print(f"  Rollover widening ratio  : {summary['rollover_widening_x']:.1f}x")
    print(f"  Size compression         : {summary['csv_mb']:.2f} MB -> {summary['parquet_mb']:.2f} MB (.parquet)")
    print(f"  Saved Zstd Parquet       : {summary['parquet_path']}")
    print("--------------------------------------------------------------------")
    print("  Ready for Polars research or ~0.6s/combo compiled-CPU Walk-Forward")
    print("  at https://azimuthstudio.app/?utm_source=github_mt5_tools")
    print("====================================================================")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
