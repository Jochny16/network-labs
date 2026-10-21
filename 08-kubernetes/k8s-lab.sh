#!/usr/bin/env bash
# k8s-lab.sh - Kubernetes basics on k3s: Deployment, Service, self-healing, scaling
#
#   curl localhost:30080
#          |
#     Service "web" (NodePort 30080, ClusterIP 10.43.x.x)
#      /        |        \
#   pod      pod      pod        Deployment "web": 3 x nginx, IPs from 10.42.0.0/24
#
# Usage:
#   ./k8s-lab.sh up         apply web.yaml (Deployment + Service), wait until ready
#   ./k8s-lab.sh status     pods with IPs, the Service, one curl
#   ./k8s-lab.sh heal       delete one pod and watch Kubernetes replace it
#   ./k8s-lab.sh spread     6 requests through the Service - which pods answered?
#   ./k8s-lab.sh scale N    change the number of replicas
#   ./k8s-lab.sh down       delete everything from web.yaml
#
# Needs k3s: curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik
#   --disable=metrics-server --write-kubeconfig-mode=644" sh -
# Remove k3s completely: sudo k3s-uninstall.sh
set -euo pipefail

command -v kubectl >/dev/null || { echo "Missing kubectl - install k3s first (see header)"; exit 1; }
cd "$(dirname "$0")"
URL=http://localhost:30080

up() {
  kubectl apply -f web.yaml
  kubectl rollout status deployment/web --timeout=120s
}

status() {
  kubectl get pods -l app=web -o wide
  kubectl get svc web
  printf 'curl %s -> %s\n' "$URL" "$(curl -s --max-time 3 "$URL" | grep -o '<title>.*</title>' || echo 'no answer')"
}

heal() {
  local victim
  victim=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
  echo "Deleting pod $victim ..."
  kubectl delete pod "$victim" --wait=false
  kubectl rollout status deployment/web --timeout=120s
  kubectl get pods -l app=web -o wide
}

spread() {
  local since i
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  sleep 1
  for i in 1 2 3 4 5 6; do curl -s -o /dev/null "$URL"; done
  sleep 1
  echo "Requests per pod (6 sent):"
  kubectl logs -l app=web --prefix --since-time="$since" | grep '"GET /' \
    | cut -d']' -f1 | sed 's/.*pod\///; s/\/nginx//' | sort | uniq -c
}

scale() {
  kubectl scale deployment web --replicas="${1:?usage: scale N}"
  kubectl rollout status deployment/web --timeout=120s
  kubectl get pods -l app=web -o wide
}

down() { kubectl delete -f web.yaml --ignore-not-found; }

case "${1:-}" in
  up) up ;; status) status ;; heal) heal ;; spread) spread ;;
  scale) scale "${2:-}" ;; down) down ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
