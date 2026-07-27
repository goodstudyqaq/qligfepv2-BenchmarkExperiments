# QligFEP result analysis

This directory contains reusable analysis tools for benchmark targets. Reference
Fortran results and experimental mappings are discovered under:

```text
../results/<target>/
```

## Generate both figures

Pass a copied-data directory followed by its benchmark target:

```bash
./generate_figures.sh /path/to/new_data_in_hb cdk2
./generate_figures.sh /path/to/thrombin_data thrombin
```

The data directory must contain a copied `jobs/` directory. Current MPS and
batch jobs are read directly from:

```text
jobs/<job-id>_<edge>.both/work/{1.water,2.protein}/<edge>/FEP1/<temperature>/<replicate>/qfep.out
```

The older `jobs/*.both/staged_run.tar.gz` layout remains supported. Relative
data paths are resolved from the directory in which you invoke the command.
The driver:

1. validates and analyzes the copied QGPU jobs;
2. loads `results/<target>/mapping_ddG.json`;
3. loads `results/<target>/<target>_FEP_results.json` (or the sole matching
   `*_FEP_results.json` for a result-directory variant);
4. generates QGPU-versus-Fortran and experiment-correlation figures.

To generate only the free-energy CSV files, either the data root or `jobs/`
itself may be passed:

```bash
python3 analyze_staged_jobs.py /path/to/copied_data --mapping ../results/cdk2/mapping_ddG.json
python3 analyze_staged_jobs.py /path/to/copied_data/jobs --mapping ../results/cdk2/mapping_ddG.json
```

The resource-metrics report also recognizes the new job-local `metrics/`
directories:

```bash
python3 analyze_metrics.py /path/to/copied_data
```

Outputs remain with the selected dataset:

```text
DATA_DIR/ddg_analysis/ddg_summary.csv
DATA_DIR/ddg_analysis/ddg_replicates.csv
DATA_DIR/ddg_analysis/job_validation.csv
DATA_DIR/ddg_analysis/fortran_gpu_correlation_rows.csv
DATA_DIR/ddg_analysis/experiment_vs_qgpu_fortran_ddgbar.csv
DATA_DIR/ddg_analysis/experiment_correlation_stats.csv
DATA_DIR/<target>_fortran_gpu_ddgbar_comparison.png
DATA_DIR/<target>_experiment_correlations_ddgbar.png
```

The calculated edge convention must match the authoritative target mapping.
Historical summary files with differently oriented experimental values should
not be substituted for `results/<target>/mapping_ddG.json`.
