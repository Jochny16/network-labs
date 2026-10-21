# Lab 07 – Ansible: one playbook, three servers

Three clean Debian "servers" (Docker containers) are configured by one Ansible playbook: admin tools, a user and a login banner on every server, plus nginx with a generated start page on the web servers. The lab shows the core idea of configuration management – **describe the desired state, let Ansible fix whatever differs** – including idempotency and configuration drift.

## Topology

    laptop (Ansible control node)
       |  docker connection (in real life: SSH)
       +-- web1  172.30.0.11   group: web
       +-- web2  172.30.0.12   group: web
       +-- db1   172.30.0.21   group: db

| File | Role |
|---|---|
| `inventory.ini` | who is managed, grouped as `web` and `db` |
| `site.yml` | the playbook – desired state of every group |
| `templates/*.j2` | Jinja2 templates filled with host facts (name, IP, groups) |
| `ansible.cfg` | points Ansible at the inventory |
| `Dockerfile`, `ansible-lab.sh` | build and run the lab "servers" |

## Run

    sudo apt install -y ansible docker.io
    sudo ./ansible-lab.sh up
    sudo ansible all -m ping              # can Ansible log in and run Python?
    sudo ansible-playbook site.yml        # configure everything
    sudo ./ansible-lab.sh status          # curl both web servers
    sudo ansible-playbook site.yml        # second run: nothing to do
    sudo ./ansible-lab.sh down

## Results

| Step | Observation |
|---|---|
| `ansible all -m ping` | `"ping": "pong"` from all 3 – not ICMP: Ansible connected, ran a Python module and got JSON back |
| First playbook run | db1 `changed=3`, web1/web2 `changed=8` – packages, user, banner, nginx, config, start page |
| Web check | `Hello from web1 (172.30.0.11)` / `Hello from web2 (172.30.0.12)` – values filled in from Ansible facts |
| Second run | `changed=0` everywhere – **idempotent**, the servers already match the playbook |
| Manual edit of `/etc/motd` on db1, then a run | only db1 `changed=1` – the drift is detected and reverted, everything else untouched |

## What I learned

1. **Declarative, not imperative.** A task says "nginx *is* installed", not "install nginx". Ansible checks the current state and changes only what differs.
2. **Idempotency.** Running the same playbook again is safe and reports `changed=0`. A bash script would redo everything (and often fail on "already exists").
3. **Configuration drift.** Manual changes on a server are found and reverted on the next run – the playbook is the source of truth, so it belongs in Git.
4. **`ansible -m ping` is not ICMP.** It proves Ansible can connect (SSH in production) and run Python on the target – that is why the image ships `python3`.
5. **Inventory groups** let one playbook give every server a baseline and add roles per group (`hosts: web`).
6. **Templates + facts** generate per-host files (`{{ inventory_hostname }}`, `{{ ansible_default_ipv4.address }}`) from one source.
7. **Handlers** run only when a task changed something – nginx is reloaded only when its config or page actually changed.
8. **`command` always reports changed** – it cannot know what the command did. Prefer real modules (`apt`, `user`, `template`) and guard commands with `creates`.

## Real servers vs this lab

| This lab | Production |
|---|---|
| `ansible_connection=community.docker.docker` | SSH: `ansible_host=10.0.0.11 ansible_user=admin` + SSH keys |
| `sudo ansible ...` on the laptop | `become: true` in the playbook, sudo on the target |
| `command: nginx` + `creates` (no systemd in containers) | `ansible.builtin.service: name=nginx state=started enabled=true` |
| one `site.yml` | roles (`roles/nginx/...`), group_vars, Ansible Vault for secrets |

## Next steps

- Turn the web part into a role and add `group_vars`.
- Manage the same playbook against Proxmox VMs over SSH.
- Push network config (VLANs, ACLs) to Cisco IOS with the `cisco.ios` collection.
