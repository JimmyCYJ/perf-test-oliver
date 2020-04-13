#!/bin/bash

VER=1.4.6-asm.0

echo "Performance tests."

NEW_ASM_SEC_CLUSTER=1
PROJECT_ID=yonggangl-istio
CLUSTER_NAME=cluster-2
CLUSTER_ZONE=us-central1-a
IDNS=${PROJECT_ID}.svc.id.goog
MESH_ID="${PROJECT_ID}_${CLUSTER_ZONE}_${CLUSTER_NAME}"
CTX=gke_${PROJECT_ID}_${CLUSTER_ZONE}_${CLUSTER_NAME}

echo
echo PROJECT_ID=$PROJECT_ID
echo CLUSTER_NAME=$CLUSTER_NAME
echo CLUSTER_ZONE=$CLUSTER_ZONE
echo IDNS="$IDNS"
echo

pushd ..

source perf.sh

#init
#cleanup_cluster
#sleep 900
#setup_asm
static_dynamic "c1" 100 120 120 1
#workload_restarts 80 240 120

#baseline
#validate_authn
#deploy_bookinfo
#validate_bookinfo

popd
