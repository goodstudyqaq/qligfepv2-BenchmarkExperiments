export QDYN="$HOME/code/Q2/bin/qdyn"
export QFEP="$HOME/code/Q2/src/q6/bin/q6/qfep"
export CLEAN_AFTER="0"
export QGPU_MODULES=""
./run_qgpu_mps_local.sh \
--only thrombin/2.protein/FEP_1a_1c \
--replicates 1