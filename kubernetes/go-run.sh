#!/bin/bash

# This will help start/stop Game On services using in a Kubernetes cluster.
#
# `eval $(kubernetes/go-run.sh env)` will set aliases to more easily invoke
# this script's actions from the command line.
#

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $SCRIPTDIR/k8s-functions

# Ensure we're executing from project root directory
cd "${GO_DIR}"

GO_DEPLOYMENT=kubernetes
COREPROJECTS="auth map mediator player proxy room swagger webapp"

#set the action, default to help if none passed.
ACTION=help
if [ $# -ge 1 ]; then
  ACTION=$1
  shift
fi

platform_up() {
  if [ ! -f .gameontext.kubernetes ] || [ ! -f .gameontext.cert.pem ]; then
    setup
  else
    check_cluster
    get_cluster_ip
    check_global_cert
  fi

  if [ -f .gameontext.helm ];  then
    wrap_helm install --name go-system ./kubernetes/chart/gameon-system/
  else
    wrap_kubectl apply -R -f kubernetes/kubectl
  fi

  echo 'To wait for readiness: ./kubernetes/go-run.sh wait'
  echo 'To type less: eval $(./kubernetes/go-run.sh env)'
}

platform_down() {
  if kubectl get namespace gameon-system > /dev/null 2>&1; then
    if [ -f .gameontext.helm ];  then
      wrap_helm delete --purge gameon-system
    else
      wrap_kubectl delete -R -f kubernetes/kubectl
    fi
    wrap_kubectl delete namespace gameon-system
  else
    ok "gameon-system stopped"
  fi
  
  if [ -f .gameontext.istio ]; then
    if kubectl get namespace istio-system > /dev/null 2>&1; then
      read -p "Do you want to remove istio? [y] " answer
      if [ -z $answer ] || [[ $answer =~ [Yy] ]]; then
        cd $(cat .gameontext.istio)
        wrap_helm delete --purge istio
        wrap_kubectl delete namespace istio-system
      fi
    else
      ok "istio-system stopped"
    fi
  fi

  if [ -f .gameontext.helm ] && $(get_tiller); then
    read -p "Do you want to reset helm? [y] " answer
    if [ -z $answer ] || [[ $answer =~ [Yy] ]]; then
       wrap_helm reset
    fi
  fi
  echo ""
}

rebuild() {
  PROJECTS=''

  while [[ $# -gt 0 ]]; do
    case "$1" in
      all) PROJECTS="$COREPROJECTS $PROJECTS";;
      *) PROJECTS="$1 $PROJECTS";;
    esac
    shift
  done

  echo "Building projects [$PROJECTS]"
  for project in $PROJECTS
  do
    if [ ! -d "${project}" ]; then
      continue
    fi

    echo
    echo "*****"
    cd "$project"

    if [ -e "build.gradle" ]; then
      echo "Building project ${project} with gradle"
      ./gradlew build --rerun-tasks
      rc=$?
      if [ $rc != 0 ]; then
        echo Gradle build failed. Please investigate, Game On! is unlikely to work until the issue is resolved.
        exit 1
      fi
      echo "Building docker image for ${project}"
      ./gradlew build image
    elif [ "${project}" == "webapp" ] && [ -f build.sh ]; then
      echo "webapp source present:  $(ls -d ${GO_DIR}/webapp/app)"
      ./build.sh
      ./build.sh final
    elif [ -f Dockerfile ]; then
      echo "Re-building docker image for ${project}"
      ${DOCKER_CMD} build -t gameontext/gameon-${project} .
    fi

    cd ${GO_DIR}
  done
}

usage() {
  echo "
  Actions:
    setup    -- set up k8s secrets, prompt for helm
    reset    -- replace generated files (cert, config with cluster IP)
    env      -- eval-compatible commands to create aliases
    host     -- manually set host information about your k8s cluster

    up       -- install/update gameon-system namespace
    down     -- delete the gameon-system namespace
    status   -- return status of gameon-system namespace
    wait     -- wait until the game services are up and ready to play!
  "
}

case "$ACTION" in
  reset)
    reset_go
    setup
  ;;
  setup)
    setup
  ;;
  up)
    platform_up
  ;;
  down)
    platform_down
  ;;
  rebuild)
    rebuild $@
  ;;
  status)
    wrap_kubectl -n gameon-system get all

    get_cluster_ip
    echo "
    When ready, the game is available at https://${GAMEON_INGRESS}/
    "
  ;;
  env)
    echo "alias go-run='${SCRIPTDIR}/go-run.sh';"
    echo "alias go-admin='${GO_DIR}/go-admin.sh'"
  ;;
  wait)
    get_cluster_ip

    if kubectl -n gameon-system get po | grep -q mediator; then
      echo "Waiting for gameon-system pods to start"
      wait_until_ready -n gameon-system get pods
      echo ""
      echo "Game On! You're ready to play: https://${GAMEON_INGRESS}/"
    else
      echo "You haven't started any game services"
    fi
  ;;
  host)
    define_ingress
  ;;
  *)
    usage
  ;;
esac
