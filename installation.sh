#!/bin/bash

KCTL="kubectl --context=$CTX"
if [ -z $CTX ]
then
  KCTL="kubectl"
fi

function init {
	echo "Set gcloud"
	gcloud config set project ${PROJECT_ID}
	gcloud config set compute/zone ${CLUSTER_ZONE}

	echo "Enabling APIs"
  gcloud services enable \
    container.googleapis.com \
    compute.googleapis.com \
    stackdriver.googleapis.com \
    meshca.googleapis.com \
    meshtelemetry.googleapis.com \
    meshconfig.googleapis.com \
    iamcredentials.googleapis.com \
    anthos.googleapis.com  

  if [ ! -z "$NEW_ASM_SEC_CLUSTER" ]
  then
	  echo "Enable IDNS for existing cluster"
	  gcloud beta container clusters update ${CLUSTER_NAME} \
      --identity-namespace=${IDNS}
  fi

  echo "Set IAM"
  curl --request POST \
    --header "Authorization: Bearer $(gcloud auth print-access-token)" \
    --data '' \
    https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}:initialize  

	gcloud container clusters get-credentials ${CLUSTER_NAME}    

	${KCTL} create clusterrolebinding cluster-admin-binding \
	    --clusterrole=cluster-admin \
	    --user=$(gcloud config get-value core/account)
}
 
function validate_certs {
  echo
  echo "-----------------"
  echo "Verify Pilot certificate..."

  galley_pod=$(${KCTL} get pod -l istio=galley -n istio-system -o \
    jsonpath={.items..metadata.name})

  ${KCTL} exec -it $galley_pod -c istio-proxy -n istio-system -- openssl s_client \
    -connect istio-pilot.istio-system:15011

  echo
  echo "-----------------"
	echo "Verify the certificate of httpbin.foo..."
	pod=$(${KCTL} get pod -l app=sleep -n foo -o jsonpath={.items..metadata.name})

	${KCTL} exec -it $pod -c istio-proxy -n foo -- openssl s_client -connect httpbin.foo:8000
}

function validate_authn {
  echo
  echo "-----------------"
	echo "Verify workload connectivity"

	pod=$(${KCTL} get pod -l app=sleep -n foo -o jsonpath={.items..metadata.name})

	${KCTL} exec $pod -c sleep -n foo -- curl "http://httpbin.foo:8000/ip" -s \
  -o /dev/null -w \
  ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>  sleep.foo to httpbin.foo:%{http_code}  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n"

  echo
  echo "-----------------"
	echo "Verify mTLS configured for workload communication"

	pod=$(${KCTL} get pod -l app=sleep -n foo -o jsonpath={.items..metadata.name})
	istio-$VER/bin/istioctl authn tls-check $pod.foo httpbin.foo.svc.cluster.local
	istio-$VER/bin/istioctl authn tls-check $pod.foo
}

# deploy_replica_workloads takes two parameters: namespace_name, num_of_workloads
function deploy_replica_workloads { 
  pushd files

  if [ "$#" -ne "2" ]
  then
    echo "ERROR: $0 needs 2 parameters: namespace_name, num_of_workloads"; exit 1
  fi

  re='^[0-9]+$'
  if ! [[ $2 =~ $re ]] ; then
    echo "error: Parameter 2 is not a number" >&2; exit 1
  fi

	${KCTL} create ns $1
	${KCTL} label namespace $1 istio-injection=enabled --overwrite

  # Single httpbin workload
  ${KCTL} apply -f httpbin.yaml -n $1 > /dev/null

  # Create a serviceaccount sleep-replicas-X for each sleep
  cp sleep.yaml sleep-replicas-$2.yaml > /dev/null
  sed -i "s/replicas\: 1/replicas\: $2/g" sleep-replicas-$2.yaml
  ${KCTL} apply -f sleep-replicas-$2.yaml -n $1 > /dev/null

  popd
}

# taks two parameters: namespace_name
function validate_replica_workloads {
  echo
  echo "-----------------"
	echo "Verify workload connectivity from sleep replicas to httpbin in namespace $1"

  if [ "$#" -ne "2" ]
  then
    echo "ERROR: validate_replica_workloads needs 2 parameters: namespace, test_id"; exit 1
  fi

  test_id=$4
  errdir=errors-${test_id}
  
  sleep_pods=$(${KCTL} get pods -n $1 -o go-template --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' -l app=sleep)
  pods=()

  while read -r line; do
    pods+=("$line")
  done <<< "${sleep_pods}"

  if [ ${#pods[@]} = 0 ]; then
    echo "no pods found!"
  fi

  for pod in "${pods[@]}"
  do
    resp_code=$(${KCTL} exec ${pod} -n $1 -c sleep -- curl -s -o /dev/null -w "%{http_code}" httpbin.$1:8000/headers)
    if [ ${resp_code} = "200" ]; then
      num_succeed=$((num_succeed+1))
    else
      echo "curl from the pod ${pod} failed"
      ${KCTL} get po ${pod} -n $1 > ${errdir}/log.${pod}.$1
      ${KCTL} describe po ${pod} -n $1 >> ${errdir}/log.${pod}.$1
      ${KCTL} logs ${pod} -n $1 -c istio-proxy >> ${errdir}/log.${pod}.$1
    fi
    num_curl=$((num_curl+1))
    echo "Out of ${num_curl} curl, ${num_succeed} succeeded."
    sleep 1
  done
}



# deploy_workloads takes two paremeters: namespace_name, num_of_workloads
function deploy_workloads {
  pushd files

  if [ "$#" -ne "2" ]
  then
    echo "ERROR: $0 needs 2 parameters: namespace_name, num_of_workloads"; exit 1
  fi

  re='^[0-9]+$'
  if ! [[ $2 =~ $re ]] ; then
    echo "error: Parameter 2 is not a number" >&2; exit 1
  fi

	${KCTL} create ns $1
	${KCTL} label namespace $1 istio-injection=enabled --overwrite

  max=$2
  let "max=max-1"
  # Create a serviceaccount httpbin-X for each httpbin
  for i in $(seq 0 $max)
  do
    #cp httpbin.yaml httpbin-$i.yaml > /dev/null
    #sed -i "s/ httpbin/ httpbin-$i/g" httpbin-$i.yaml
    ${KCTL} apply -f httpbin-$i.yaml -n $1 > /dev/null
  done

  # Create a serviceaccount sleep-X for each sleep
  for i in $(seq 0 $max)
  do
    #cp sleep.yaml sleep-$i.yaml > /dev/null
    #sed -i "s/ sleep/ sleep-$i/g" sleep-$i.yaml
    ${KCTL} apply -f sleep-$i.yaml -n $1 > /dev/null
  done

  popd
}

function validate_workloads {
  echo
  echo "-----------------"
	echo "Verify workload connectivity from namespace $1 to namespace $2"

  if [ "$#" -ne "4" ]
  then
    echo "ERROR: validate_workloads needs 3 parameters: from_namespace, to_namespace, num_pods, test_id"; exit 1
  fi

  max=$3
  let "max=max-1"
  test_id=$4
  errdir=errors-${test_id}
  mkdir ${errdir}

  local i=0
  for i in $(seq 0 $max)
  do
    pod=$(${KCTL} get pod -l app=sleep-$i -n $1 -o jsonpath={.items..metadata.name}) 
    httpbinpod=$(${KCTL} get pod -l app=httpbin-$i -n $2 -o jsonpath={.items..metadata.name}) 
    resp_code=$(${KCTL} exec ${pod} -n $1 -c sleep-$i -- curl -s -o /dev/null -w "%{http_code}" httpbin-$i.$2:8000/headers)
    if [ "${resp_code}" = "200" ]; then
      num_succeed=$((num_succeed+1))
      echo "curl from the pod ${pod}.$1 to httpbin-$i.$2"
    else
      echo "curl from the pod ${pod}.$1 to httpbin-$i.$2 failed. Status written to file."
      ${KCTL} get po ${pod} -n $1 > ${errdir}/log.${pod}.$1
      ${KCTL} describe po ${pod} -n $1 >> ${errdir}/log.${pod}.$1
      ${KCTL} logs ${pod} -n $1 -c istio-proxy >> ${errdir}/log.${pod}.$1
      ${KCTL} get po ${httpbinpod} -n $2 > ${errdir}/log.${httpbinpod}.$2
      ${KCTL} describe po ${httpbinpod} -n $2 >> ${errdir}/log.${httpbinpod}.$2
      ${KCTL} logs ${httpbinpod} -n $2 -c istio-proxy >> ${errdir}/log.${httpbinpod}.$2
    fi
    num_curl=$((num_curl+1))
    echo "Out of ${num_curl} curl, ${num_succeed} succeeded."
    sleep 0.5
    let "i=i+1"
  done
}

function deploy_bookinfo {
  pushd istio-$VER

	${KCTL} label namespace default istio-injection=enabled --overwrite
  ${KCTL} apply -f samples/bookinfo/platform/kube/bookinfo.yaml

	for i in {0..5};
	do
		sleep 10;
		${KCTL} get po;
	done

  ${KCTL} apply -f samples/bookinfo/networking/bookinfo-gateway.yaml

  echo
  echo "-----------------"
	echo "Verify internal connectivity"

  ${KCTL} exec -it $(${KCTL} get pod -l app=ratings -o jsonpath='{.items[0].metadata.name}') -c ratings -- curl productpage:9080/productpage | grep -o "<title>.*</title>"

  echo
  echo "-----------------"
	echo "Verify external connectivity"

  sleep 10

  ${KCTL} get gateway

  popd
  
  validate_bookinfo
}

function validate_bookinfo {
  echo
  echo "-----------------"
	echo "Verify external connectivity"

  export INGRESS_HOST=$(${KCTL} -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  export INGRESS_PORT=$(${KCTL} -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
  export SECURE_INGRESS_PORT=$(${KCTL} -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].port}')

  export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT

  echo $GATEWAY_URL

  curl -s http://${GATEWAY_URL}/productpage | grep -o "<title>.*</title>"
}

function enable_mtls {
  echo "Configure mesh policy for authentication..."
  
  ${KCTL} apply -f - <<EOF
apiVersion: "authentication.istio.io/v1alpha1"
kind: "MeshPolicy"
metadata:
  name: "default"
spec:
  peers:
  - mtls: {}
EOF

  echo "Configure destination policy..."

  ${KCTL} apply -f - <<EOF
apiVersion: "networking.istio.io/v1alpha3"
kind: "DestinationRule"
metadata:
  name: "default"
  namespace: "istio-system"
spec:
  host: "*.local"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
EOF

sleep 10
}

function install_asm_ga {
  echo "Enable Mesh CA GA based on istio-$VER"
  gcloud container clusters get-credentials ${CLUSTER_NAME} --zone ${CLUSTER_ZONE} --project ${PROJECT_ID}

  istio-$VER/bin/istioctl manifest apply --set profile=asm \
      --set values.global.trustDomain=${IDNS} \
      --set values.global.sds.token.aud=${IDNS} \
      --set values.nodeagent.env.GKE_CLUSTER_URL=https://container.googleapis.com/v1/projects/${PROJECT_ID}/locations/${CLUSTER_ZONE}/clusters/${CLUSTER_NAME} \
      --set values.nodeagent.env.SECRET_TTL=10m \
      --set values.nodeagent.env.SECRET_GRACE_DURATION=5m \
      --set values.nodeagent.env.SECRET_JOB_RUN_INTERVAL=1m \
      --set values.global.proxy.resources.limits.cpu=200m \
      --set values.global.proxy.resources.limits.memory=256Mi \
      --set values.global.meshID=${MESH_ID} \
      --set values.global.proxy.env.GCP_METADATA="${PROJECT_ID}|${PROJECT_NUMBER}|${CLUSTER_NAME}|${CLUSTER_ZONE}" \
      --set values.global.mtls.enabled=true

  sleep 30
}

function cleanup_cluster {
  ${KCTL} delete mutatingwebhookconfiguration --all
  ${KCTL} delete validatingwebhookconfiguration --all
  ${KCTL} delete psp --all
  ${KCTL} delete deploy --all
  ${KCTL} delete configmap --all
  ${KCTL} delete service --all
  ${KCTL} delete ingress --all
  ${KCTL} delete namespace --all
  ${KCTL} delete rule --all
  ${KCTL} delete denier --all
  ${KCTL} delete checknothing --all
  ${KCTL} delete serviceaccount --all
  ${KCTL} delete secret --all
  ${KCTL} delete EgressRules --all
  ${KCTL} delete MeshPolicy --all
  ${KCTL} delete serviceentry --all
  ${KCTL} delete virtualservice --all
  ${KCTL} delete gateway --all
  ${KCTL} delete destinationrule --all
  ${KCTL} delete poddisruptionbudgets --all
  sleep 50
}
