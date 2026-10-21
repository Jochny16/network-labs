#!/usr/bin/env bash
# ansible-lab.sh - three "servers" (Docker containers) managed by Ansible
#
#   laptop (Ansible control node)
#      |  docker connection (in real life: SSH)
#      +-- web1  172.30.0.11   group: web
#      +-- web2  172.30.0.12   group: web
#      +-- db1   172.30.0.21   group: db
#
# Usage (as root):
#   ./ansible-lab.sh up       build the image and start web1, web2, db1
#   ./ansible-lab.sh status   containers and their IPs, curl the web servers
#   ./ansible-lab.sh reset    recreate the containers (clean servers again)
#   ./ansible-lab.sh down     remove containers, network and image
#
# Then, in this folder:
#   sudo ansible all -m ping
#   sudo ansible-playbook site.yml
#
# Needs: apt install -y ansible docker.io
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo ./ansible-lab.sh ...)"; exit 1; }
for b in docker ansible; do
  command -v "$b" >/dev/null || { echo "Missing $b: apt install -y ansible docker.io"; exit 1; }
done
cd "$(dirname "$0")"

NET=labnet
IMAGE=ansible-lab-node
declare -A HOSTS=([web1]=172.30.0.11 [web2]=172.30.0.12 [db1]=172.30.0.21)
BASE_IMAGE=${BASE_IMAGE:-debian:trixie-slim}

start_nodes() {
  local h
  for h in web1 web2 db1; do
    docker run -d --name "$h" --hostname "$h" --network "$NET" --ip "${HOSTS[$h]}" "$IMAGE" >/dev/null
  done
}

up() {
  docker build -q --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$IMAGE" . >/dev/null
  docker network inspect "$NET" >/dev/null 2>&1 || \
    docker network create --subnet 172.30.0.0/24 "$NET" >/dev/null
  start_nodes
  echo "Up: web1 web2 db1 (clean Debian, only python3 installed)."
}

status() {
  docker ps --filter network="$NET" --format '  {{.Names}}\t{{.Status}}'
  local h out
  for h in web1 web2; do
    out=$(curl -s --max-time 2 "http://${HOSTS[$h]}/" | grep -o '<h1>.*</h1>' || true)
    printf '  curl %-4s %-13s %s\n' "$h" "${HOSTS[$h]}" "${out:-no web server}"
  done
}

reset() {
  docker rm -f web1 web2 db1 >/dev/null 2>&1 || true
  start_nodes
  echo "Containers recreated - all servers are clean again."
}

down() {
  docker rm -f web1 web2 db1 >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker rmi "$IMAGE" >/dev/null 2>&1 || true
  echo "Lab removed."
}

case "${1:-}" in
  up) up ;; status) status ;; reset) reset ;; down) down ;;
  *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
