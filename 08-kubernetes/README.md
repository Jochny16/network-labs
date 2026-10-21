# Lab 08 – Kubernetes basics: Pods, Deployment, Service

A single-node Kubernetes cluster (k3s) on the laptop runs nginx as a Deployment with 3 replicas behind a Service. The lab shows the three objects every junior DevOps / admin role asks about – **Pod, Deployment, Service** – and what Kubernetes does on its own: replacing a dead pod, spreading traffic, and replacing pods one by one on a config change.

## Topology

       curl localhost:30080
              |
        Service "web"  (NodePort 30080, ClusterIP 10.43.x.x)
         /       |       \
      pod       pod       pod      Deployment "web": 3 x nginx:1.27
    10.42.0.x  10.42.0.x  10.42.0.x  (pod network 10.42.0.0/24 on this node)

| Object | What it is | In this lab |
|---|---|---|
| Pod | smallest unit: one or more containers with one IP | nginx container, IP from 10.42.0.0/24 |
| Deployment | desired state "N copies of this pod", kept true all the time | `replicas: 3`, rolling updates |
| Service | stable address + load balancing in front of pods chosen by label | `selector: app=web`, NodePort 30080 |

## Run

    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --disable=metrics-server --write-kubeconfig-mode=644" sh -
    kubectl get nodes                 # think14 Ready
    ./k8s-lab.sh up                   # kubectl apply -f web.yaml
    ./k8s-lab.sh status               # pods, Service, curl
    ./k8s-lab.sh heal                 # delete a pod, watch it come back
    ./k8s-lab.sh spread               # 6 requests - which pods answered?
    ./k8s-lab.sh scale 5
    ./k8s-lab.sh down
    sudo k3s-uninstall.sh             # remove k3s completely

## Results

| Step | Observation |
|---|---|
| 3 replicas | Every pod gets its own IP: 10.42.0.4, .5, .6 – from the cluster's pod network, not from the home LAN |
| Delete one pod | Within seconds a **new** pod (new name, new IP .7) replaces it – the Deployment keeps 3 running |
| Service | Stable ClusterIP 10.43.x.x (separate service network) and NodePort 30080 on the laptop |
| 6 requests via the Service | 3 / 1 / 2 per pod – **each request goes to one pod**, chosen per connection (not to all of them) |
| First curl right after `up` | `no answer` for a few seconds – the container started, nginx was not ready yet |
| Add readinessProbe + `kubectl apply` | **Rolling update**: "1 of 3 updated… 2 of 3… old replicas pending termination" – pods replaced one by one, new names (new ReplicaSet hash), the Service stayed `unchanged` |

## What I learned

1. **Pods are disposable.** Their names and IPs change whenever they are recreated – never point anything at a pod IP.
2. **A Deployment is a desired state kept continuously.** Like an Ansible playbook, but Kubernetes enforces it all the time, not only when you run it – a deleted pod is replaced in seconds.
3. **A Service gives a stable address** (ClusterIP / NodePort) and load-balances to every pod matching its label selector – one connection, one pod.
4. **Two address pools in k3s:** pods 10.42.0.0/16 (each node gets a /24), Services 10.43.0.0/16.
5. **Running is not ready.** `rollout status` waits for containers, not the application; a **readinessProbe** makes Kubernetes send traffic only to pods that answer.
6. **Declarative YAML in Git** beats one-off `kubectl create` commands: `kubectl apply -f` changes only what differs (`deployment configured`, `service unchanged`).
7. **Rolling update** replaces pods one by one, so the application keeps answering during a change.

## Imperative vs declarative

| Imperative (what I typed first) | Declarative (what goes in Git) |
|---|---|
| `kubectl create deployment web --image=nginx:1.27 --replicas=3` | `Deployment` in `web.yaml` |
| `kubectl expose deployment web --port=80 --type=NodePort` | `Service` in `web.yaml` |
| `kubectl scale deployment web --replicas=5` | change `replicas:` and `kubectl apply -f web.yaml` |

## Next steps

- Liveness probe vs readiness probe; resource limits and what happens when a pod runs out of memory.
- ConfigMap with a custom start page, Ingress instead of NodePort.
- Rollback with `kubectl rollout undo`; deploy with Helm; run the same app on Azure AKS.
