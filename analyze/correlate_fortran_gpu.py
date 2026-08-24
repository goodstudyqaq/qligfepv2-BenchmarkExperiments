#!/usr/bin/env python3
"""Compare Fortran and GPU/HPC ddG values and report correlations/plots.

Defaults are set for the current CDK2 analysis:
  CSV: cdk2_fortran_gpu_ddgbar_comparision.csv

The comparison CSV is expected to use the semicolon-delimited schema from
cdk2_fortran_gpu_ddg_comparision_old.csv. By default the script reads ddGbar
rows and plots Fortran ddGbar on x against GPU/HPC ddGbar on y.

The older JSON + GPU-summary path is still available with --from-json.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
from typing import Iterable


DEFAULT_FORTRAN_JSON = Path(
    "/home/mcpi-02/code/qligfepv2-BenchmarkExperiments/results/cdk2/cdk2_FEP_results.json"
)
DEFAULT_GPU_SUMMARY = Path("data_in_hb/ddg_analysis/ddg_summary.csv")
DEFAULT_COMPARISON_CSV = Path("cdk2_fortran_gpu_ddgbar_comparision.csv")
DEFAULT_FIGURE = Path("cdk2_fortran_gpu_ddgbar_comparision.png")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Calculate correlations between Fortran and GPU ddG values."
    )
    parser.add_argument(
        "--comparison-csv",
        default=DEFAULT_COMPARISON_CSV,
        type=Path,
        help=(
            "Semicolon-delimited comparison CSV. Expected columns include "
            "metric, edge, fortran_avg, gpu_avg, fortran_sem, gpu_sem."
        ),
    )
    parser.add_argument(
        "--from-json",
        action="store_true",
        help="Build comparison rows from Fortran JSON and GPU summary instead of reading --comparison-csv.",
    )
    parser.add_argument(
        "--fortran-json",
        default=DEFAULT_FORTRAN_JSON,
        type=Path,
        help="Fortran cdk2_FEP_results.json path.",
    )
    parser.add_argument(
        "--gpu-summary",
        default=DEFAULT_GPU_SUMMARY,
        type=Path,
        help="GPU/HPC summary CSV path, for example data_in_hb/ddg_analysis/ddg_summary.csv.",
    )
    parser.add_argument(
        "--metric",
        default="ddGbar",
        help="Fortran result metric to compare, e.g. ddGbar, ddG, ddGf, ddGr, ddGos.",
    )
    parser.add_argument(
        "--figure",
        default=DEFAULT_FIGURE,
        type=Path,
        help="Figure output path. Use '' to skip plotting.",
    )
    parser.add_argument(
        "--out",
        default="data_in_hb/ddg_analysis/fortran_gpu_correlation_rows.csv",
        type=Path,
        help="Optional joined-row CSV output path. Use '' to disable.",
    )
    return parser.parse_args()


def mean(values: Iterable[float]) -> float:
    values = list(values)
    return sum(values) / len(values)


def pearson(xs: list[float], ys: list[float]) -> float:
    if len(xs) != len(ys) or len(xs) < 2:
        raise ValueError("Pearson correlation needs at least two paired values.")
    xbar = mean(xs)
    ybar = mean(ys)
    numerator = sum((x - xbar) * (y - ybar) for x, y in zip(xs, ys))
    denom_x = math.sqrt(sum((x - xbar) ** 2 for x in xs))
    denom_y = math.sqrt(sum((y - ybar) ** 2 for y in ys))
    if denom_x == 0 or denom_y == 0:
        return float("nan")
    return numerator / (denom_x * denom_y)


def average_ranks(values: list[float]) -> list[float]:
    indexed = sorted(enumerate(values), key=lambda item: item[1])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(indexed):
        j = i + 1
        while j < len(indexed) and indexed[j][1] == indexed[i][1]:
            j += 1
        avg_rank = (i + 1 + j) / 2.0
        for k in range(i, j):
            ranks[indexed[k][0]] = avg_rank
        i = j
    return ranks


def spearman(xs: list[float], ys: list[float]) -> float:
    return pearson(average_ranks(xs), average_ranks(ys))


def kendall_tau_b(xs: list[float], ys: list[float]) -> float:
    concordant = 0
    discordant = 0
    tie_x = 0
    tie_y = 0

    for i in range(len(xs) - 1):
        for j in range(i + 1, len(xs)):
            dx = (xs[i] > xs[j]) - (xs[i] < xs[j])
            dy = (ys[i] > ys[j]) - (ys[i] < ys[j])
            if dx == 0 and dy == 0:
                continue
            if dx == 0:
                tie_x += 1
            elif dy == 0:
                tie_y += 1
            elif dx == dy:
                concordant += 1
            else:
                discordant += 1

    denom = math.sqrt(
        (concordant + discordant + tie_x) * (concordant + discordant + tie_y)
    )
    if denom == 0:
        return float("nan")
    return (concordant - discordant) / denom


def linear_fit(xs: list[float], ys: list[float]) -> tuple[float, float]:
    xbar = mean(xs)
    ybar = mean(ys)
    denom = sum((x - xbar) ** 2 for x in xs)
    if denom == 0:
        return float("nan"), float("nan")
    slope = sum((x - xbar) * (y - ybar) for x, y in zip(xs, ys)) / denom
    intercept = ybar - slope * xbar
    return slope, intercept


def first_present(row: dict[str, str], names: list[str]) -> str | None:
    for name in names:
        value = row.get(name)
        if value not in (None, ""):
            return value
    return None


def finite_float(value: object) -> float | None:
    """Return a finite float, treating missing, NaN, and infinity as invalid."""
    if value in (None, ""):
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def finite_optional_value(value: object) -> object:
    """Keep a numeric uncertainty only when it is finite."""
    return value if finite_float(value) is not None else ""


def load_fortran(path: Path, metric: str) -> dict[str, dict[str, object]]:
    with path.open() as handle:
        data = json.load(handle)
    if "result" not in data or metric not in data["result"]:
        available = sorted(data.get("result", {}).keys())
        raise KeyError(f"Metric {metric!r} not found. Available metrics: {available}")

    avg_key = f"{metric}_avg"
    sem_key = f"{metric}_sem"
    std_key = f"{metric}_std"
    rows: dict[str, dict[str, object]] = {}
    excluded: list[str] = []
    for fep_id, item in data["result"][metric].items():
        value = finite_float(item.get(avg_key))
        if value is None:
            excluded.append(fep_id)
            continue
        rows[fep_id] = {
            "fep_id": fep_id,
            "from": item.get("from", ""),
            "to": item.get("to", ""),
            "fortran": value,
            "fortran_sem": finite_optional_value(item.get(sem_key, "")),
            "fortran_std": finite_optional_value(item.get(std_key, "")),
        }
    if excluded:
        print(
            f"Excluded {len(excluded)} non-finite Fortran {metric} edge(s): "
            + ", ".join(sorted(excluded))
        )
    return rows


def load_gpu(path: Path) -> dict[str, dict[str, object]]:
    value_columns = ["Q_ddG_avg", "hpc_ddGbar_avg", "gpu_ddGbar_avg", "ddG_avg"]
    sem_columns = ["Q_ddG_sem", "hpc_sem", "gpu_sem", "ddG_sem"]
    std_columns = ["Q_ddG_std", "hpc_std", "gpu_std", "ddG_std"]

    rows: dict[str, dict[str, object]] = {}
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            fep_id = row.get("fep_id")
            value = finite_float(first_present(row, value_columns))
            if not fep_id or value is None:
                continue
            rows[fep_id] = {
                "fep_id": fep_id,
                "from": row.get("from", ""),
                "to": row.get("to", ""),
                "gpu": value,
                "gpu_sem": finite_optional_value(first_present(row, sem_columns)),
                "gpu_std": finite_optional_value(first_present(row, std_columns)),
            }
    return rows


def load_comparison_csv(path: Path, metric: str) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle, delimiter=";")
        for row in reader:
            if row.get("metric") != metric:
                continue
            fortran = finite_float(row.get("fortran_avg"))
            gpu = finite_float(row.get("gpu_avg"))
            if fortran is None or gpu is None:
                continue
            diff = gpu - fortran
            rows.append(
                {
                    "fep_id": row["edge"],
                    "from": row.get("from", ""),
                    "to": row.get("to", ""),
                    "fortran": f"{fortran:.6f}",
                    "gpu": f"{gpu:.6f}",
                    "gpu_minus_fortran": f"{diff:.6f}",
                    "abs_diff": f"{abs(diff):.6f}",
                    "fortran_sem": row.get("fortran_sem", ""),
                    "gpu_sem": row.get("gpu_sem", ""),
                    "fortran_std": row.get("fortran_std", ""),
                    "gpu_std": row.get("gpu_std", ""),
                }
            )
    if not rows:
        raise ValueError(f"No {metric!r} rows found in {path}")
    return rows


def build_rows_from_json(args: argparse.Namespace) -> list[dict[str, object]]:
    fortran_rows = load_fortran(args.fortran_json, args.metric)
    gpu_rows = load_gpu(args.gpu_summary)

    common = sorted(set(fortran_rows) & set(gpu_rows))
    if not common:
        raise SystemExit("No common FEP IDs found between Fortran and GPU inputs.")

    rows: list[dict[str, object]] = []
    for fep_id in common:
        f = fortran_rows[fep_id]
        g = gpu_rows[fep_id]
        diff = float(g["gpu"]) - float(f["fortran"])
        rows.append(
            {
                "fep_id": fep_id,
                "from": g["from"] or f["from"],
                "to": g["to"] or f["to"],
                "fortran": f"{float(f['fortran']):.6f}",
                "gpu": f"{float(g['gpu']):.6f}",
                "gpu_minus_fortran": f"{diff:.6f}",
                "abs_diff": f"{abs(diff):.6f}",
                "fortran_sem": f["fortran_sem"],
                "gpu_sem": g["gpu_sem"],
                "fortran_std": f["fortran_std"],
                "gpu_std": g["gpu_std"],
            }
        )
    return rows


def write_joined_rows(path: Path, rows: list[dict[str, object]]) -> None:
    if not str(path):
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "fep_id",
        "from",
        "to",
        "fortran",
        "gpu",
        "gpu_minus_fortran",
        "abs_diff",
        "fortran_sem",
        "gpu_sem",
        "fortran_std",
        "gpu_std",
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def optional_float(value: object) -> float | None:
    return finite_float(value)


def plot_rows(path: Path, rows: list[dict[str, object]], metric: str) -> None:
    import os

    cache_dir = Path("/tmp/matplotlib-cache")
    cache_dir.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("MPLCONFIGDIR", str(cache_dir))
    os.environ.setdefault("XDG_CACHE_HOME", str(cache_dir))

    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import Normalize

    xs = [float(row["fortran"]) for row in rows]
    ys = [float(row["gpu"]) for row in rows]
    diffs = [abs(y - x) for x, y in zip(xs, ys)]
    xerr_values = [optional_float(row.get("fortran_sem")) for row in rows]
    yerr_values = [optional_float(row.get("gpu_sem")) for row in rows]
    xerr = [value or 0.0 for value in xerr_values]
    yerr = [value or 0.0 for value in yerr_values]
    use_xerr = any(value is not None and value > 0 for value in xerr_values)
    use_yerr = any(value is not None and value > 0 for value in yerr_values)

    diffs_signed = [y - x for x, y in zip(xs, ys)]
    rmse = math.sqrt(mean(diff * diff for diff in diffs_signed))
    mue = mean(abs(diff) for diff in diffs_signed)
    tau = kendall_tau_b(xs, ys)

    low = math.floor(min(xs + ys) - 1.0)
    high = math.ceil(max(xs + ys) + 1.0)
    grid = [low + (high - low) * i / 200 for i in range(201)]

    fig = plt.figure(figsize=(7.4, 5.2), dpi=180)
    grid_spec = fig.add_gridspec(1, 2, width_ratios=[1.0, 0.34], wspace=0.08)
    ax = fig.add_subplot(grid_spec[0, 0])
    side_ax = fig.add_subplot(grid_spec[0, 1])
    side_ax.axis("off")

    ax.fill_between(
        grid,
        [x - 2.0 for x in grid],
        [x + 2.0 for x in grid],
        color="0.92",
        label="Within 2 kcal/mol",
        zorder=0,
    )
    ax.fill_between(
        grid,
        [x - 1.0 for x in grid],
        [x + 1.0 for x in grid],
        color="0.84",
        label="Within 1 kcal/mol",
        zorder=1,
    )
    ax.plot(grid, grid, color="black", linewidth=1.2, label="Identity line", zorder=2)

    if use_xerr or use_yerr:
        ax.errorbar(
            xs,
            ys,
            xerr=xerr if use_xerr else None,
            yerr=yerr if use_yerr else None,
            fmt="none",
            ecolor="0.45",
            elinewidth=1.0,
            capsize=2.0,
            alpha=0.85,
            zorder=3,
        )

    vmax = max(1.0, math.ceil(max(diffs)))
    scatter = ax.scatter(
        xs,
        ys,
        c=diffs,
        cmap="coolwarm",
        norm=Normalize(vmin=0.0, vmax=vmax),
        s=42,
        edgecolors="black",
        linewidths=0.45,
        zorder=4,
    )

    cax = side_ax.inset_axes([0.05, 0.56, 0.18, 0.38])
    cbar = fig.colorbar(scatter, cax=cax)
    cbar.set_label("Deviation |kcal/mol|", rotation=270, labelpad=16)

    ax.set_xlim(low, high)
    ax.set_ylim(low, high)
    ax.set_aspect("equal", adjustable="box")
    ax.grid(True, linestyle="--", linewidth=0.35, color="0.75", alpha=0.7)
    ax.set_title(rf"$\Delta\Delta G_{{{metric.upper().replace('DDG', '')}}}$ (N = {len(rows)})")
    ax.set_xlabel(r"Fortran $\Delta\Delta G_{calc}$ (kcal/mol)")
    ax.set_ylabel(r"GPU $\Delta\Delta G_{calc}$ (kcal/mol)")

    stats_text = (
        rf"$\tau$ = {tau:.2f}" "\n"
        rf"RMSE = {rmse:.2f} kcal/mol" "\n"
        rf"MUE = {mue:.2f} kcal/mol"
    )
    side_ax.text(
        0.0,
        0.45,
        stats_text,
        transform=side_ax.transAxes,
        ha="left",
        va="top",
        fontsize=10,
    )

    handles, labels = ax.get_legend_handles_labels()
    order = ["Identity line", "Within 1 kcal/mol", "Within 2 kcal/mol"]
    by_label = dict(zip(labels, handles))
    side_ax.legend(
        [by_label[label] for label in order if label in by_label],
        [label for label in order if label in by_label],
        loc="lower left",
        bbox_to_anchor=(0.0, 0.04),
        frameon=False,
        fontsize=8,
    )

    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def main() -> int:
    args = parse_args()
    if args.from_json:
        rows = build_rows_from_json(args)
        source = f"{args.fortran_json} + {args.gpu_summary}"
    else:
        rows = load_comparison_csv(args.comparison_csv, args.metric)
        source = str(args.comparison_csv)

    xs = [float(row["fortran"]) for row in rows]
    ys = [float(row["gpu"]) for row in rows]
    diffs = [y - x for x, y in zip(xs, ys)]
    slope, intercept = linear_fit(xs, ys)

    print(f"N = {len(rows)}")
    print(f"Metric = {args.metric}")
    print(f"Source = {source}")
    print("X = Fortran, Y = GPU/HPC")
    print(f"Pearson r     = {pearson(xs, ys):.6f}")
    print(f"Spearman rho  = {spearman(xs, ys):.6f}")
    print(f"Kendall tau-b = {kendall_tau_b(xs, ys):.6f}")
    print(f"Linear fit    = GPU = {slope:.6f} * Fortran + {intercept:.6f}")
    print(f"Mean diff     = {mean(diffs):.6f} kcal/mol")
    print(f"MAE/MUE       = {mean(abs(d) for d in diffs):.6f} kcal/mol")
    print(f"RMSE          = {math.sqrt(mean(d * d for d in diffs)):.6f} kcal/mol")

    max_row = max(rows, key=lambda row: float(row["abs_diff"]))
    print(
        "Max abs diff  = "
        f"{max_row['fep_id']} {float(max_row['abs_diff']):.6f} kcal/mol"
    )

    if str(args.out):
        write_joined_rows(args.out, rows)
        print(f"Wrote {args.out}")

    if str(args.figure):
        plot_rows(args.figure, rows, args.metric)
        print(f"Wrote {args.figure}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
