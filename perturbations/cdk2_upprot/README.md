# cdk2_upprot — diagnostic only, not a benchmark input

Same as `../cdk2/`, except that three binding-site residues of CDK2 are put
back to the coordinates of the published OpenFE protein file
(`IndustryBenchmarks2024/.../prepared_structures/jacs_set/cdk2/protein.pdb`,
which matches the Schrödinger benchmark, the PMX/PLB 0.2.1 input and crystal
1H1Q for these residues):

| residue (crystal) | residue (this repo) | largest shift vs `../cdk2/protein.pdb` |
|---|---|---|
| Asp86  | ASP88  | 1.2 A (OD2) |
| Lys89  | LYS91  | 3.8 A (side chain; NZ 2.8 A) |
| Leu134 | LEU136 | 2.2 A (side chain) |

53 atoms changed (coordinates only; names, order, protonation and every other
residue are identical to `../cdk2/protein.pdb`). The other residues that differ
from upstream (cyclin A Val175/Pro176/Asp177 and the two ACE caps) are more
than 25 A from the sphere centre and were left as they are.

Resulting geometry in the generated topology:

- Lys89 NZ – Asp86 OD2: 4.3 A (was 7.2 A)
- Lys89 NZ – Cl(1h1r) / S(22): 4.4 A (was 6.5 A)
- Cl(1h1r) / S(22) – Asp86 OD: 2.1 A (was 2.7 A) — a tight starting contact,
  the same as in the upstream and PMX inputs; it is relaxed by minimisation.

Ligand files (`1h1r`, `1h1q`, `22`, `17`), `water.pdb`: unchanged copies.
`mapping.json`: the two benchmark edges `1h1r -> 1h1q` and `22 -> 17`.

Purpose: test whether the binding-site side-chain positions explain the
difference between our result for `1h1r -> 1h1q` (-2.63, no EP) and the value
implied by PMX with OpenFF 2.0 (+0.44); experiment is -0.51.
Baseline protein-leg dG to compare with: `1h1r -> 1h1q` and `22 -> 17` from the
normal `cdk2` runs.

`*.sdf` files are git-ignored: copy `1h1r.sdf`, `1h1q.sdf`, `22.sdf`, `17.sdf`
to the cluster by hand (they define the ligand–ligand restraint pairing).

Generate inputs:

    setupFEP -FF AMBER14sb -c SNELLIUS -r 25 -b auto --start 0.5 -R 10 -S sigmoidal -ts 2fs -clean dcd inp -j mapping.json -log info -rest heavyatom_p -rs 42 -wath 1.7
