#!/bin/bash

KCTL="${KCTL} --context=$CTX"
if [ -z $CTX ]
then
  KCTL="${KCTL}"
fi

source installation.sh

function setup_asm {
  install_asm_ga
  enable_mtls
}

function baseline {
  deploy_workloads test1 5
  sleep 10
  validate_workloads test1 test1 5 "baseline"
}

function static_dynamic {
  if [ "$#" -ne "5" ]
  then
    echo "ERROR: static_dynamic needs 5 parameters: test_id, num_of_wl_per_ns, readytime, waittime, restart_node_agent"; exit 1
  fi

  re='^[0-9]+$'
  if ! [[ $2 =~ $re ]] ; then
   echo "${FUNCNAME[0]}: num_of_workload_per_ns is not a number" >&2; exit 1
  fi

  re='^[0-9]+$'
  if ! [[ $3 =~ $re ]] ; then
    echo "${FUNCNAME[0]}: ready_time is not a number" >&2; exit 1
  fi

  re='^[0-9]+$'
  if ! [[ $4 =~ $re ]] ; then
    echo "${FUNCNAME[0]}: wait_time is not a number" >&2; exit 1
  fi

  re='^[0-9]+$'
  if ! [[ $5 =~ $re ]] ; then
    echo "${FUNCNAME[0]}: restart_node_agent is not a number" >&2; exit 1
  fi

  local testid=$1
  local scale=$2
  local readytime=$3
  local waittime=$4
  local restartna=$5
  echo "$(date): Deploy static --------------"
  deploy_workloads static ${scale}
  sleep ${readytime}
  echo "$(date): Test static --------------"
  validate_workloads static static ${scale} ${testid}
  local nsi=0
  while true
  do
    echo "$(date): Deploy test-${nsi} --------------"
    deploy_workloads test-${nsi} ${scale}
    sleep ${readytime}
    if [ "$restartna" -eq "1" ]; then
      echo "$(date): Restart nodeagent --------------"
      ${KCTL} delete pod -l app=istio-nodeagent -n istio-system
      ${KCTL} get pod -n istio-system
    fi
    echo "$(date): Test test-${nsi} --------------"
    validate_workloads static test-${nsi} ${scale} ${testid}
    validate_workloads test-${nsi} static ${scale} ${testid}
    validate_workloads test-${nsi} test-${nsi} ${scale} ${testid}
    echo "$(date): Delete test-${nsi} --------------"
    while true
    do
      ${KCTL} delete ns test-${nsi}
      sleep 10
      # Make sure the namespace is removed.
      local remainings=$(${KCTL} get ns | grep test)
      if [ -z ${remainings} ]; then
        break
      fi
      echo "testing namespace test-${nsi} is not removed. Retry..."
    done
    echo "testing namespace is removed"
    let "nsi=nsi+1"
    sleep ${waittime}
  done
}

function bursty_workload_restarts {
  if [ "$#" -ne "4" ]
  then
    echo "ERROR: bursty_workload_restarts needs 4 parameters: test_id, num_of_wl_per_ns, readytime, waittime"; exit 1
  fi

  re='^[0-9]+$'
  if ! [[ $2 =~ $re ]] ; then
    echo "error: Parameter 2 is not a number" >&2; exit 1
  fi

  re='^[0-9]+$'
  if ! [[ $3 =~ $re ]] ; then
    echo "error: Parameter 3 is not a number" >&2; exit 1
  fi

  re='^[0-9]+$'
  if ! [[ $4 =~ $re ]] ; then
    echo "error: Parameter 1 is not a number" >&2; exit 1
  fi

  local testid=$1
  local scale=$2
  local readytime=$3
  local waittime=$4
  local testi=0

  while true
  do
    echo "$(date): Deploy $testi --------------"
    deploy_replica_workloads test1 ${scale}
    sleep ${readytime}
    echo "$(date): Test $testi --------------"
    validate_replica_workloads test1 ${testid}
    while true
    do
      ${KCTL} delete ns test1
      sleep 10
      # Make sure the namespace is removed.
      local remainings=$(${KCTL} get ns | grep test)
      if [ -z ${remainings} ]; then
        break
      fi
      echo "testing namespace test1 is not removed. Retry..."
    done
    echo "testing namespace is removed"
    sleep ${waittime}
    let "testi=testi+1"
  done
}
