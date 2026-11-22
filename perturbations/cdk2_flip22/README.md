# cdk2_flip22 — diagnostic only, not a benchmark input

Ligand 22 (meta-SMe) with its aniline phenyl ring rotated 180 degrees about the
C23(ipso)–C11(para) axis, so the SMe group points to the solvent / His84 side
instead of sitting against Asp86. Everything else is copied unchanged from
`../cdk2/`:

- `22.pdb`, `22.sdf`: flipped coordinates (12 atoms moved: C10 C12 C13 C24 S25
  C26 and their hydrogens). Atom order, names and bonds are unchanged.
- `22.lib`, `22.prm`, `17.*`, `21.*`, `protein.pdb`, `water.pdb`: copies.
- `mapping.json`: only the two benchmark edges that involve 22
  (`21 -> 22`, `22 -> 17`).

The same transform applied to `../cdk2/1h1r.pdb` reproduces the manual PyMOL
flip in `../cdk2_flip/1h1r.pdb` (RMS 0.07 A, max 0.23 A).

Purpose: compare the protein-leg dG of `22(flipped) -> 17` with the benchmark
`22 -> 17`. The end state (17) is the same, so the difference is the free
energy difference between the two poses of 22 in the pocket.

`*.sdf` files are git-ignored: copy `17.sdf`, `21.sdf`, `22.sdf` to the cluster
by hand (they define the ligand–ligand restraint pairing).

Generate inputs (same settings as cdk2, but keep the .inp files):

    setupFEP -FF AMBER14sb -c SNELLIUS -r 25 -b auto --start 0.5 -R 10 -S sigmoidal -ts 2fs -j mapping.json -log info -rest heavyatom_p -rs 42 -wath 1.7
