#!/usr/bin/env python3
"""Plot ddGbar correlations against experimental ddG for CDK2.

Defaults are set for the current CDK2 analysis:
  CSV: data_in_hb/ddg_analysis/experiment_vs_hpc_fortran_ddgbar.csv

The figure contains two panels:
  1. QGPU ddGbar vs experimental ddG
  2. Fortran ddGbar vs experimental ddG
"""

from __future__ import annotations

import argparse
import csv
import math
import os
from pathlib import Path

from correlate_fortran_gpu import kendall_tau_b, linear_fit, mean, pearson, spearman


DEFAULT_INPUT = Path("data_in_hb/ddg_analysis/experiment_vs_hpc_fortran_ddgbar.csv")
DEFAULT_FIGURE = Path("cdk2_experiment_correlations_ddgbar.png")
DEFAULT_STATS = Path("data_in_hb/ddg_analysis/experiment_correlation_stats.csv")


METHODS = [
    {
        "key": "qgpu",
        "label": "QGPU",
        "value_column": "hpc_ddGbar",
        "sem_column": "hpc_sem",
    },
    {
        "key": "fortran",
        "label": "Fortran",
        "value_column": "fortran_ddGbar",
        "sem_column": "fortran_sem",
    },
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Calculate and plot QGPU/Fortran ddGbar correlations against experiment."
    )
    parser.add_argument(
        "--input",
        default=DEFAULT_INPUT,
        type=Path,
        help="CSV with exp_ddG, hpc_ddGbar, fortran_ddGbar and optional SEM columns.",
    )
    parser.add_argument(
        "--figure",
        default=DEFAULT_FIGURE,
        type=Path,
        help="Figure output path. Use '' to skip plotting.",
    )
    parser.add_argument(
        "--stats",
        default=DEFAULT_STATS,
        type=Path,
        help="Stats CSV output path. Use '' to skip writing.",
    )
    return parser.parse_args()


def optional_float(value: object) -> float | None:
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def load_rows(path: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            exp_ddg = optional_float(row.get("exp_ddG"))
            if exp_ddg is None:
                continue

            loaded = {
                "fep_id": row.get("fep_id", ""),
                "from": row.get("from", ""),
                "to": row.get("to", ""),
                "exp_ddG": exp_ddg,
            }
            missing_method = False
            for method in METHODS:
                value = optional_float(row.get(method["value_column"]))
                if value is None:
                    missing_method = True
                    break
                loaded[method["key"]] = value
                loaded[f"{method['key']}_sem"] = optional_float(
                    row.get(method["sem_column"])
                )
            if not missing_method:
                rows.append(loaded)

    if not rows:
        raise ValueError(f"No complete experiment/method rows found in {path}")
    return rows


def stats_for_method(rows: list[dict[str, object]], method: dict[str, str]) -> dict[str, object]:
    xs = [float(row["exp_ddG"]) for row in rows]
    ys = [float(row[method["key"]]) for row in rows]
    diffs = [y - x for x, y in zip(xs, ys)]
    abs_diffs = [abs(diff) for diff in diffs]
    slope, intercept = linear_fit(xs, ys)
    max_index = max(range(len(rows)), key=lambda idx: abs_diffs[idx])

    return {
        "method": method["label"],
        "n": len(rows),
        "pearson_r": pearson(xs, ys),
        "spearman_rho": spearman(xs, ys),
        "kendall_tau_b": kendall_tau_b(xs, ys),
        "slope": slope,
        "intercept": intercept,
        "mean_error": mean(diffs),
        "mae_mue": mean(abs_diffs),
        "rmse": math.sqrt(mean(diff * diff for diff in diffs)),
        "max_abs_error": abs_diffs[max_index],
        "max_abs_error_edge": rows[max_index]["fep_id"],
    }


def write_stats(path: Path, stats_rows: list[dict[str, object]]) -> None:
    if not str(path):
        return

    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "method",
        "n",
        "pearson_r",
        "spearman_rho",
        "kendall_tau_b",
        "slope",
        "intercept",
        "mean_error",
        "mae_mue",
        "rmse",
        "max_abs_error",
        "max_abs_error_edge",
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in stats_rows:
            formatted = {}
            for key, value in row.items():
                if isinstance(value, float):
                    formatted[key] = f"{value:.6f}"
                else:
                    formatted[key] = value
            writer.writerow(formatted)


def plot_rows(path: Path, rows: list[dict[str, object]], stats_rows: list[dict[str, object]]) -> None:
    if not str(path):
        return

    cache_dir = Path("/tmp/matplotlib-cache")
    cache_dir.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("MPLCONFIGDIR", str(cache_dir))
    os.environ.setdefault("XDG_CACHE_HOME", str(cache_dir))

    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import Normalize

    exp_values = [float(row["exp_ddG"]) for row in rows]
    calc_values = [
        float(row[method["key"]])
        for method in METHODS
        for row in rows
    ]
    low = math.floor(min(exp_values + calc_values) - 1.0)
    high = math.ceil(max(exp_values + calc_values) + 1.0)
    grid = [low + (high - low) * i / 200 for i in range(201)]

    all_abs_errors = [
        abs(float(row[method["key"]]) - float(row["exp_ddG"]))
        for method in METHODS
        for row in rows
    ]
    vmax = max(1.0, math.ceil(max(all_abs_errors)))
    norm = Normalize(vmin=0.0, vmax=vmax)

    fig = plt.figure(figsize=(11.0, 5.0), dpi=180)
    grid_spec = fig.add_gridspec(1, 3, width_ratios=[1.0, 1.0, 0.08], wspace=0.18)
    axes = [fig.add_subplot(grid_spec[0, 0]), fig.add_subplot(grid_spec[0, 1])]
    cax = fig.add_subplot(grid_spec[0, 2])

    scatter = None
    stats_by_method = {row["method"]: row for row in stats_rows}
    for ax, method in zip(axes, METHODS):
        method_key = method["key"]
        method_label = method["label"]
        xs = exp_values
        ys = [float(row[method_key]) for row in rows]
        yerr_values = [row.get(f"{method_key}_sem") for row in rows]
        yerr = [float(value) if value is not None else 0.0 for value in yerr_values]
        use_yerr = any(value is not None and float(value) > 0 for value in yerr_values)
        abs_errors = [abs(y - x) for x, y in zip(xs, ys)]

        ax.fill_between(
            grid,
            [x - 2.0 for x in grid],
            [x + 2.0 for x in grid],
            color="0.93",
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

        if use_yerr:
            ax.errorbar(
                xs,
                ys,
                yerr=yerr,
                fmt="none",
                ecolor="0.45",
                elinewidth=1.0,
                capsize=2.0,
                alpha=0.85,
                zorder=3,
            )

        scatter = ax.scatter(
            xs,
            ys,
            c=abs_errors,
            cmap="coolwarm",
            norm=norm,
            s=42,
            edgecolors="black",
            linewidths=0.45,
            zorder=4,
        )

        stats = stats_by_method[method_label]
        stats_text = (
            rf"$r$ = {float(stats['pearson_r']):.2f}" "\n"
            rf"$\rho$ = {float(stats['spearman_rho']):.2f}" "\n"
            rf"$\tau$ = {float(stats['kendall_tau_b']):.2f}" "\n"
            rf"RMSE = {float(stats['rmse']):.2f} kcal/mol" "\n"
            rf"MUE = {float(stats['mae_mue']):.2f} kcal/mol"
        )
        ax.text(
            0.04,
            0.96,
            stats_text,
            transform=ax.transAxes,
            ha="left",
            va="top",
            fontsize=9,
            bbox={"facecolor": "white", "edgecolor": "0.80", "alpha": 0.82, "pad": 4},
        )

        ax.set_xlim(low, high)
        ax.set_ylim(low, high)
        ax.set_aspect("equal", adjustable="box")
        ax.grid(True, linestyle="--", linewidth=0.35, color="0.75", alpha=0.7)
        ax.set_title(f"{method_label} vs experiment (N = {len(rows)})")
        ax.set_xlabel(r"Experimental $\Delta\Delta G$ (kcal/mol)")
        if ax is axes[0]:
            ax.set_ylabel(r"Calculated $\Delta\Delta G_{calc}$ (kcal/mol)")

    if scatter is not None:
        cbar = fig.colorbar(scatter, cax=cax)
        cbar.set_label("Absolute error |kcal/mol|", rotation=270, labelpad=18)

    handles, labels = axes[0].get_legend_handles_labels()
    order = ["Identity line", "Within 1 kcal/mol", "Within 2 kcal/mol"]
    by_label = dict(zip(labels, handles))
    fig.legend(
        [by_label[label] for label in order if label in by_label],
        [label for label in order if label in by_label],
        loc="lower center",
        ncol=3,
        frameon=False,
        bbox_to_anchor=(0.5, -0.02),
    )

    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)


def print_stats(source: Path, stats_rows: list[dict[str, object]]) -> None:
    print(f"Source = {source}")
    print("X = experiment, Y = calculated")
    for stats in stats_rows:
        print()
        print(f"{stats['method']} (N = {stats['n']})")
        print(f"Pearson r     = {float(stats['pearson_r']):.6f}")
        print(f"Spearman rho  = {float(stats['spearman_rho']):.6f}")
        print(f"Kendall tau-b = {float(stats['kendall_tau_b']):.6f}")
        print(
            "Linear fit    = "
            f"calc = {float(stats['slope']):.6f} * exp + {float(stats['intercept']):.6f}"
        )
        print(f"Mean error    = {float(stats['mean_error']):.6f} kcal/mol")
        print(f"MAE/MUE       = {float(stats['mae_mue']):.6f} kcal/mol")
        print(f"RMSE          = {float(stats['rmse']):.6f} kcal/mol")
        print(
            "Max abs error = "
            f"{stats['max_abs_error_edge']} {float(stats['max_abs_error']):.6f} kcal/mol"
        )


def main() -> int:
    args = parse_args()
    rows = load_rows(args.input)
    stats_rows = [stats_for_method(rows, method) for method in METHODS]

    print_stats(args.input, stats_rows)

    if str(args.stats):
        write_stats(args.stats, stats_rows)
        print(f"\nWrote {args.stats}")

    if str(args.figure):
        plot_rows(args.figure, rows, stats_rows)
        print(f"Wrote {args.figure}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
