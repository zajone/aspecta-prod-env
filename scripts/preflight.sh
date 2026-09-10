#!/usr/bin/env bash
# Checks that the machine can host the environment before anything is created.
#
# A failed bootstrap halfway through is much harder to diagnose than a refusal
# up front, so every requirement that can be measured is measured here.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Measured requirement of the full stack: kind (3 nodes), Argo CD, ingress-nginx,
# kube-prometheus-stack, metrics-server and the application.
MIN_RAM_GB=6
RECOMMENDED_RAM_GB=8
MIN_CPUS=2
RECOMMENDED_CPUS=4
MIN_DISK_GB=20

problems=0
note_problem() { fail "$1"; problems=$((problems + 1)); }

total_ram_gb() {
  case "$(host_os)" in
    linux)
      awk '/MemTotal/ {printf "%d", $2 / 1048576}' /proc/meminfo
      ;;
    darwin)
      echo $(( $(sysctl -n hw.memsize) / 1073741824 ))
      ;;
  esac
}

cpu_count() {
  case "$(host_os)" in
    linux) getconf _NPROCESSORS_ONLN ;;
    darwin) sysctl -n hw.ncpu ;;
  esac
}

free_disk_gb() {
  # POSIX df output, in 1 kB blocks, for the directory holding docker's data.
  df -Pk "${REPO_ROOT}" | awk 'NR == 2 {printf "%d", $4 / 1048576}'
}

port_in_use() {
  # Uses bash's own TCP support so no netcat or lsof is required.
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
}

# published_beyond_loopback reports a listener bound to something other than
# 127.0.0.1 on this port. The cluster publishes Prometheus and Alertmanager
# with no authentication, so binding them to every interface would put them
# on whatever network this machine is attached to - which is why
# clusters/kind/cluster.yaml pins listenAddress.
published_beyond_loopback() {
  local port="$1"
  have ss || return 1
  ss -Hltn "sport = :${port}" 2>/dev/null \
    | awk '{print $4}' \
    | grep -qvE '^(127\.0\.0\.1|\[::1\]):'
}

log "preflight checks"

# --- container runtime ------------------------------------------------------
if ! have docker; then
  note_problem "docker is not installed. Install Docker Desktop (macOS) or docker-ce (WSL/Linux)."
elif ! docker info >/dev/null 2>&1; then
  note_problem "docker is installed but the daemon is not reachable. Start Docker and retry."
else
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
fi

if have kubectl; then
  ok "kubectl present"
else
  note_problem "kubectl is not installed."
fi

# --- capacity ---------------------------------------------------------------
ram="$(total_ram_gb)"
cpus="$(cpu_count)"
disk="$(free_disk_gb)"

if [ "${ram}" -lt "${MIN_RAM_GB}" ]; then
  note_problem "${ram} GB of RAM detected, at least ${MIN_RAM_GB} GB is required."
elif [ "${ram}" -lt "${RECOMMENDED_RAM_GB}" ]; then
  warn "${ram} GB of RAM detected; ${RECOMMENDED_RAM_GB} GB is recommended for the full stack."
  dim "      Reduce the load with: make up MONITORING=off"
else
  ok "${ram} GB RAM"
fi

if [ "${cpus}" -lt "${MIN_CPUS}" ]; then
  note_problem "${cpus} CPU(s) detected, at least ${MIN_CPUS} are required."
elif [ "${cpus}" -lt "${RECOMMENDED_CPUS}" ]; then
  warn "${cpus} CPUs detected; ${RECOMMENDED_CPUS} are recommended."
else
  ok "${cpus} CPUs"
fi

if [ "${disk}" -lt "${MIN_DISK_GB}" ]; then
  note_problem "${disk} GB free disk, at least ${MIN_DISK_GB} GB is required for the node and container images."
else
  ok "${disk} GB free disk"
fi

# --- host ports -------------------------------------------------------------
# kind publishes the Ingress controller on host ports 80 and 443. If something
# else already holds them, the cluster comes up but nothing is reachable, which
# is a confusing failure to debug later.
for port in 80 443; do
  if port_in_use "${port}"; then
    if docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -q "${CLUSTER_NAME}-control-plane"; then
      if published_beyond_loopback "${port}"; then
        note_problem "port ${port} is published beyond 127.0.0.1, so Prometheus and Alertmanager - which have no authentication - are reachable from other machines. Recreate the cluster after checking listenAddress in clusters/kind/cluster.yaml."
      else
        ok "port ${port} is held by the existing ${CLUSTER_NAME} cluster, on loopback only"
      fi
    else
      note_problem "port ${port} on 127.0.0.1 is already in use by another process. Stop it, or set an alternative port mapping in clusters/kind/cluster.yaml."
    fi
  else
    ok "port ${port} is free"
  fi
done

# --- WSL specifics ----------------------------------------------------------
if [ -f /proc/version ] && grep -qi microsoft /proc/version; then
  dim "      running under WSL2"
  if [ "${ram}" -ge "${MIN_RAM_GB}" ]; then
    dim "      the VM memory ceiling comes from .wslconfig on the Windows host"
  fi
fi

# --- DNS for the demo hostnames --------------------------------------------
# *.localtest.me resolves to 127.0.0.1 in public DNS. If that resolution fails
# (offline machine, split-horizon DNS), the hostnames need an /etc/hosts entry.
if have getent; then
  if ! getent hosts "${APP_HOST}" >/dev/null 2>&1; then
    warn "${APP_HOST} does not resolve. Run 'make hosts-entry' for the /etc/hosts line to add."
  else
    ok "${APP_HOST} resolves"
  fi
fi

echo
if [ "${problems}" -ne 0 ]; then
  die "${problems} problem(s) must be fixed before bootstrapping."
fi
ok "machine is ready"
