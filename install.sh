#!/usr/bin/env bash
# Rekognitor installer for Linux and macOS (also used by install-windows.cmd inside WSL).
#
#   ./install.sh [--profile auto|light|full] [--cluster auto|k3s|k3d|existing]
#                        [--yes] [--check] [--timeout SECONDS]
#
# Creates a single-node Kubernetes (Linux: k3s; macOS: k3d on Docker Desktop or
# Colima), installs the rekognitor charts into namespace "rekognitor" and waits
# until every pod is Ready. Idempotent: run it again to upgrade, or to start the
# cluster again (macOS) after a reboot.
#
# Everything it creates is recorded in ~/.rekognitor/state so uninstall.sh
# removes exactly that and nothing it found already installed. Your
# ~/.kube/config is never touched: the cluster's kubeconfig is
# ~/.rekognitor/kubeconfig (`source ~/.rekognitor/env` to use kubectl).
#
# Also works piped (`curl -fsSL .../install.sh | bash`): it then downloads this
# repository to ~/.rekognitor/src and runs from there.
#
# Bash 3.2 compatible (macOS /bin/bash): no associative arrays, no mapfile.
set -euo pipefail

REPO_TARBALL=${REPO_TARBALL:-https://github.com/Rekognitor/rekognitor-setup/archive/refs/heads/main.tar.gz}
REK_HOME=${REKOGNITOR_HOME:-$HOME/.rekognitor}
if ! ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd); then ROOT=""; fi
if [[ ! -d $ROOT/charts ]]; then
  # piped through bash: fetch the whole repository (charts, values) and re-run from it
  echo "Baixando o instalador do Rekognitor..."
  rm -rf "$REK_HOME/src" && mkdir -p "$REK_HOME/src"
  curl -fsSL "$REPO_TARBALL" | tar -xz -C "$REK_HOME/src" --strip-components=1
  # stdin is this script's text: give the prompts the terminal back, when there is one
  if (: </dev/tty) 2>/dev/null; then exec bash "$REK_HOME/src/install.sh" "$@" </dev/tty; fi
  exec bash "$REK_HOME/src/install.sh" "$@"
fi
BIN=$REK_HOME/bin
STATE=$REK_HOME/state
SECRETS=$REK_HOME/secrets
KCFG=$REK_HOME/kubeconfig
NAMESPACE=rekognitor # the streamer's DETECT_SERVICES_URL hardcodes detect.rekognitor.svc
CHARTS=${CHARTS:-"redis mqtt detect vision streamer"}
CLUSTER_NAME=rekognitor
UI_PORT=31881 # streamer NodePort (always works); 8085 = its LoadBalancer port
# ports the stack publishes on the host
APP_PORTS="8085 1883 1882 31881 31882"

HELM_VERSION=${HELM_VERSION:-v3.21.4}
K3D_VERSION=${K3D_VERSION:-v5.9.0}
K3S_CHANNEL=${K3S_CHANNEL:-stable}
K3S_VERSION=${K3S_VERSION:-}
COLIMA_CPU=${COLIMA_CPU:-4}
COLIMA_MEMORY=${COLIMA_MEMORY:-8}
COLIMA_DISK=${COLIMA_DISK:-40}

PROFILE=auto CLUSTER=auto YES=0 CHECK_ONLY=0 TIMEOUT=1200

# ---------------------------------------------------------------- output ----
if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' C=$'\e[36m' N=$'\e[0m'; else B="" G="" Y="" R="" C="" N=""; fi
step() { printf '\n%s==> %s%s\n' "$C$B" "$*" "$N"; }
ok() { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die() { printf '\n%s✘ ERRO:%s %s\n' "$R$B" "$N" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Instalador do Rekognitor (Linux / macOS)

Uso: $0 [opções]

  --profile auto|light|full   recursos dos serviços (padrão: auto)
                                light: 1 réplica do detect, para máquinas com < 6 CPUs
                                full : 3-5 réplicas do detect (autoscaling)
  --cluster auto|k3s|k3d|existing
                              auto: Linux=k3s, macOS=k3d (padrão)
                              existing: usa o cluster do KUBECONFIG atual
  --timeout SEGUNDOS          espera máxima pelos pods (padrão: $TIMEOUT)
  --check                     só verifica os pré-requisitos, não instala nada
  -y, --yes                   não pede confirmação
  -h, --help                  esta ajuda
EOF
}

while (($#)); do
  case $1 in
    --profile) PROFILE=${2:?}; shift ;;
    --cluster) CLUSTER=${2:?}; shift ;;
    --timeout) TIMEOUT=${2:?}; shift ;;
    --check) CHECK_ONLY=1 ;;
    -y | --yes) YES=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage; die "opção desconhecida: $1" ;;
  esac
  shift
done
case $PROFILE in auto | light | full) ;; *) die "--profile deve ser auto, light ou full" ;; esac
case $CLUSTER in auto | k3s | k3d | existing) ;; *) die "--cluster deve ser auto, k3s, k3d ou existing" ;; esac

# ----------------------------------------------------------------- state ----
state_get() { if [[ -f $STATE ]]; then sed -n "s/^$1=//p" "$STATE" | tail -1; fi; }
state_set() {
  mkdir -p "$REK_HOME"
  if [[ -f $STATE ]]; then grep -v "^$1=" "$STATE" >"$STATE.tmp" || true; else : >"$STATE.tmp"; fi
  echo "$1=$2" >>"$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

# ------------------------------------------------------------- platform ----
OS=$(uname -s)
case $(uname -m) in
  x86_64 | amd64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) die "arquitetura $(uname -m) não suportada (use x86_64 ou arm64)" ;;
esac
case $OS in
  Linux) PLAT=linux ;;
  Darwin) PLAT=darwin ;;
  *) die "sistema $OS não suportado por este script (no Windows use install-windows.cmd)" ;;
esac
IS_WSL=0
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1

SUDO=""
if [[ $(id -u) -ne 0 ]]; then SUDO=sudo; fi

have() { command -v "$1" >/dev/null 2>&1; }
cpus() { if [[ $PLAT == darwin ]]; then sysctl -n hw.ncpu; else nproc; fi; }
mem_gb() {
  if [[ $PLAT == darwin ]]; then echo $(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024))
  else awk '/MemTotal/ {printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo; fi
}
disk_free_gb() { df -Pk "$1" | awk 'NR==2 {printf "%d", $4/1024/1024}'; }
sha256() { if have sha256sum; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
# A listening socket, or anything answering a TCP connect: Kubernetes NodePorts
# (iptables/nftables) and WSL mirrored-mode ports are not listening sockets here.
port_in_use() {
  if [[ $PLAT == darwin ]]; then lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  elif have ss; then ss -Hltn "sport = :$1" 2>/dev/null | grep -q . && return 0; fi
  local rc=0
  curl -s -m 2 -o /dev/null "http://127.0.0.1:$1/" 2>/dev/null || rc=$?
  # 7 = connection refused, 28 = timeout (filtered): nothing there
  [[ $rc != 7 && $rc != 28 ]]
}
lan_ip() {
  if [[ $PLAT == darwin ]]; then ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "<IP-desta-máquina>"
  else hostname -I 2>/dev/null | awk '{print $1}'; fi
}
confirm() {
  [[ $YES == 1 ]] && return 0
  local a
  read -r -p "$1 [s/N] " a || true
  [[ $a == s || $a == S || $a == y || $a == Y ]]
}

kc() { KUBECONFIG=$KCFG kubectl "$@"; }
k() { kc -n "$NAMESPACE" "$@"; }

[[ $CLUSTER == auto ]] && { if [[ $PLAT == darwin ]]; then CLUSTER=k3d; else CLUSTER=k3s; fi; }
PREV_CLUSTER=$(state_get CLUSTER)
if [[ -n $PREV_CLUSTER && $PREV_CLUSTER != "$CLUSTER" ]]; then
  die "o Rekognitor já foi instalado aqui com --cluster $PREV_CLUSTER. Rode ./uninstall.sh antes de trocar para $CLUSTER."
fi

# ------------------------------------------------------------ preflight ----
preflight() {
  step "Verificando pré-requisitos"
  local n m d fail=0
  n=$(cpus) m=$(mem_gb) d=$(disk_free_gb "$HOME")
  ok "sistema: $OS $ARCH$([[ $IS_WSL == 1 ]] && echo ' (WSL2)')"
  if ((n < 2)); then warn "CPUs: $n (mínimo 2)"; fail=1; elif ((n < 4)); then warn "CPUs: $n (recomendado 4 ou mais)"; else ok "CPUs: $n"; fi
  if ((m < 4)); then warn "memória: ${m} GB (mínimo 4 GB)"; fail=1; elif ((m < 8)); then warn "memória: ${m} GB (recomendado 8 GB)"; else ok "memória: ${m} GB"; fi
  if ((d < 15)); then warn "disco livre em $HOME: ${d} GB (mínimo 15 GB)"; fail=1; else ok "disco livre: ${d} GB"; fi
  have curl || { warn "curl não encontrado (instale com o gerenciador de pacotes)"; fail=1; }
  if curl -sS -o /dev/null -m 15 https://registry-1.docker.io/v2/ 2>/dev/null; then ok "internet: Docker Hub acessível"
  else warn "sem acesso a https://registry-1.docker.io (as imagens vêm do Docker Hub)"; fail=1; fi

  case $CLUSTER in
    k3s)
      [[ $PLAT == linux ]] || { warn "k3s só roda em Linux; no macOS use --cluster k3d"; fail=1; }
      if [[ -d /run/systemd/system ]]; then ok "systemd ativo"; else warn "systemd não está ativo (o k3s precisa dele; no WSL habilite [boot] systemd=true)"; fail=1; fi
      if [[ -n $SUDO ]]; then
        have sudo || { warn "sudo não encontrado: rode como root"; fail=1; }
        info "o k3s é instalado com sudo: sua senha pode ser pedida"
      fi
      ;;
    k3d)
      if docker_ready; then ok "Docker: $(docker_desc)"
      elif [[ $PLAT == darwin ]]; then
        if have brew; then ok "Homebrew encontrado: Colima (Docker gratuito) será instalado"
        else warn "Docker não encontrado e sem Homebrew. Instale o Homebrew (https://brew.sh) ou o Docker Desktop e rode de novo"; fail=1; fi
      else warn "Docker não está rodando (necessário para --cluster k3d)"; fail=1; fi
      ;;
    existing)
      if have kubectl && kubectl cluster-info >/dev/null 2>&1; then ok "cluster existente: $(kubectl config current-context)"
      else warn "--cluster existing: kubectl não alcança nenhum cluster (KUBECONFIG)"; fail=1; fi
      ;;
  esac

  # A fresh install needs the host ports free. On a re-run our own cluster holds them.
  if [[ -z $PREV_CLUSTER && $CLUSTER != existing ]]; then
    local p busy=""
    for p in $APP_PORTS $([[ $CLUSTER == k3s ]] && echo 6443 10250); do port_in_use "$p" && busy="$busy $p"; done
    if [[ -n $busy ]]; then
      warn "portas já em uso:$busy (outro Kubernetes, Docker ou o próprio Rekognitor já rodando?)"
      fail=1
    else ok "portas livres: $APP_PORTS"; fi
  fi
  return $fail
}

docker_ready() { have docker && docker info >/dev/null 2>&1; }
docker_desc() {
  local n c m
  read -r n c m < <(docker info --format '{{.Name}} {{.NCPU}} {{.MemTotal}}' 2>/dev/null) || true
  if [[ -n ${m:-} ]]; then echo "$n: $c CPUs, $((m / 1073741824)) GB"; else echo ok; fi
}

# ---------------------------------------------------------------- tools ----
# download URL DEST SHA256
download() {
  local tmp sum
  tmp=$(mktemp)
  curl -fsSL --retry 3 -o "$tmp" "$1" || die "falha ao baixar $1"
  sum=$(sha256 "$tmp")
  [[ $sum == "$3" ]] || { rm -f "$tmp"; die "checksum inválido para $1"; }
  mv "$tmp" "$2"
}

ensure_kubectl() {
  if have kubectl; then ok "kubectl: $(command -v kubectl)"; return; fi
  local v sum
  v=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  sum=$(curl -fsSL "https://dl.k8s.io/release/$v/bin/$PLAT/$ARCH/kubectl.sha256")
  download "https://dl.k8s.io/release/$v/bin/$PLAT/$ARCH/kubectl" "$BIN/kubectl" "$sum"
  chmod +x "$BIN/kubectl"
  ok "kubectl $v instalado em $BIN"
}

ensure_helm() {
  if have helm; then ok "helm: $(helm version --short 2>/dev/null)"; return; fi
  local f=helm-$HELM_VERSION-$PLAT-$ARCH.tar.gz sum tmp
  sum=$(curl -fsSL "https://get.helm.sh/$f.sha256sum" | cut -d' ' -f1)
  tmp=$(mktemp -d)
  download "https://get.helm.sh/$f" "$tmp/$f" "$sum"
  tar -xzf "$tmp/$f" -C "$tmp"
  mv "$tmp/$PLAT-$ARCH/helm" "$BIN/helm"
  rm -rf "$tmp"
  ok "helm $HELM_VERSION instalado em $BIN"
}

ensure_k3d() {
  if have k3d; then ok "k3d: $(k3d version | head -1)"; return; fi
  local sum
  sum=$(curl -fsSL "https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION/checksums.txt" | awk -v f="k3d-$PLAT-$ARCH" '$2 ~ "/"f"$" {print $1}')
  download "https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION/k3d-$PLAT-$ARCH" "$BIN/k3d" "$sum"
  chmod +x "$BIN/k3d"
  ok "k3d $K3D_VERSION instalado em $BIN"
}

# -------------------------------------------------------------- clusters ----
wait_cluster() {
  info "aguardando o Kubernetes ficar pronto..."
  local d
  for _ in $(seq 90); do kc get nodes >/dev/null 2>&1 && break; sleep 2; done
  kc wait --for=condition=Ready node --all --timeout=300s >/dev/null
  for d in coredns local-path-provisioner; do
    for _ in $(seq 60); do kc -n kube-system get deploy "$d" >/dev/null 2>&1 && break; sleep 2; done
    kc -n kube-system rollout status deploy/"$d" --timeout=300s >/dev/null
  done
  ok "Kubernetes pronto: $(kc get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
}

cluster_k3s() {
  step "Kubernetes (k3s)"
  if [[ -x /usr/local/bin/k3s ]]; then
    ok "k3s já instalado: $(/usr/local/bin/k3s --version | head -1)"
    $SUDO systemctl start k3s 2>/dev/null || true
  else
    info "instalando k3s (canal $K3S_CHANNEL${K3S_VERSION:+, versão $K3S_VERSION})..."
    # traefik (ingress) is not used by rekognitor; servicelb serves the LoadBalancers,
    # local-path the vision PVC and kube-router enforces the NetworkPolicies.
    curl -sfL https://get.k3s.io | $SUDO env INSTALL_K3S_CHANNEL="$K3S_CHANNEL" ${K3S_VERSION:+INSTALL_K3S_VERSION="$K3S_VERSION"} \
      sh -s - server --disable traefik --write-kubeconfig-mode 600 2>&1 | sed 's/^/    /'
    state_set K3S_INSTALLED 1
    ok "k3s instalado (serviço systemd: inicia sozinho com a máquina)"
  fi
  for _ in $(seq 60); do $SUDO test -f /etc/rancher/k3s/k3s.yaml && break; sleep 2; done
  $SUDO cat /etc/rancher/k3s/k3s.yaml >"$KCFG"
  chmod 600 "$KCFG"
  have kubectl || ln -sf /usr/local/bin/k3s "$BIN/kubectl"
  wait_cluster
}

ensure_docker_mac() {
  docker_ready && { ok "Docker: $(docker_desc)"; return; }
  local colima_sock=$HOME/.colima/$CLUSTER_NAME/docker.sock
  have brew || die "Docker não encontrado. Instale o Homebrew (https://brew.sh) ou o Docker Desktop e rode de novo."
  local pkg added=""
  for pkg in colima docker; do
    if ! brew list --formula "$pkg" >/dev/null 2>&1; then
      info "brew install $pkg..."
      brew install "$pkg" >/dev/null
      added="$added $pkg"
    fi
  done
  [[ -n $added ]] && state_set BREW_INSTALLED "$(state_get BREW_INSTALLED)$added"
  info "iniciando a VM Colima '$CLUSTER_NAME' (${COLIMA_CPU} CPUs, ${COLIMA_MEMORY} GB)..."
  colima start "$CLUSTER_NAME" --cpu "$COLIMA_CPU" --memory "$COLIMA_MEMORY" --disk "$COLIMA_DISK" 2>&1 | sed 's/^/    /'
  state_set COLIMA_PROFILE "$CLUSTER_NAME"
  export DOCKER_HOST=unix://$colima_sock
  docker_ready || die "o Docker do Colima não respondeu"
  ok "Docker (Colima): $(docker_desc)"
}

cluster_k3d() {
  step "Kubernetes (k3d)"
  # a previous run started our Colima VM: point docker at it (and start it after a reboot)
  local colima
  colima=$(state_get COLIMA_PROFILE)
  if [[ -n $colima ]]; then
    export DOCKER_HOST=unix://$HOME/.colima/$colima/docker.sock
    docker_ready || { info "iniciando a VM Colima '$colima'..."; colima start "$colima" 2>&1 | sed 's/^/    /'; }
  fi
  if [[ $PLAT == darwin ]]; then ensure_docker_mac; else docker_ready || die "Docker não está rodando"; fi
  ensure_k3d
  if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
    ok "cluster k3d '$CLUSTER_NAME' já existe"
    k3d cluster start "$CLUSTER_NAME" >/dev/null 2>&1 || true
  else
    info "criando o cluster k3d '$CLUSTER_NAME'..."
    # LoadBalancer ports go through k3d's proxy; NodePorts straight to the server.
    k3d cluster create "$CLUSTER_NAME" --servers 1 --agents 0 --api-port 127.0.0.1:6550 \
      -p "8085:8085@loadbalancer" -p "1883:1883@loadbalancer" -p "1882:1882@loadbalancer" \
      -p "31881:31881@server:0" -p "31882:31882@server:0" \
      --k3s-arg "--disable=traefik@server:0" ${K3S_IMAGE:+--image "$K3S_IMAGE"} \
      --kubeconfig-update-default=false --kubeconfig-switch-context=false --wait --timeout 300s 2>&1 | sed 's/^/    /'
    state_set K3D_CLUSTER "$CLUSTER_NAME"
    ok "cluster k3d criado"
  fi
  k3d kubeconfig get "$CLUSTER_NAME" >"$KCFG"
  chmod 600 "$KCFG"
  wait_cluster
}

cluster_existing() {
  step "Kubernetes (cluster existente)"
  kubectl config view --raw --minify >"$KCFG"
  chmod 600 "$KCFG"
  ok "usando o contexto $(kubectl config current-context)"
}

# --------------------------------------------------------------- deploy ----
pick_profile() {
  [[ $PROFILE != auto ]] && return
  # sum of allocatable CPUs ("4" or "3500m") across nodes
  local cpu
  cpu=$(kc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' |
    awk '/m$/ {sub(/m/,""); s+=$1/1000; next} {s+=$1} END {printf "%d", s}')
  if ((cpu >= 6)); then PROFILE=full; else PROFILE=light; fi
  info "perfil automático: $PROFILE ($cpu CPUs no cluster)"
}

# Per-installation secrets, generated once and reused on upgrades. The charts in
# this public repository only carry placeholders.
rand_hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }
ensure_secrets() {
  if [[ ! -f $SECRETS ]]; then
    local u
    u=$(rand_hex 16)
    (
      umask 077
      {
        echo "# Gerado pelo instalador em $(date '+%Y-%m-%d %H:%M:%S'). Credenciais da API do streamer"
        echo "# (login da interface quando REQUIRE_AUTH=1) e chave das sessões do dashboard MQTT."
        echo "CLIENT_ID=${u:0:8}-${u:8:4}-${u:12:4}-${u:16:4}-${u:20:12}"
        echo "SECRET=$(rand_hex 64 | tr a-f A-F)"
        echo "MQTT_AUTH_SECRET=$(rand_hex 32)"
      } >"$SECRETS"
    )
  fi
  CLIENT_ID=$(sed -n 's/^CLIENT_ID=//p' "$SECRETS")
  API_SECRET=$(sed -n 's/^SECRET=//p' "$SECRETS")
  MQTT_AUTH_SECRET=$(sed -n 's/^MQTT_AUTH_SECRET=//p' "$SECRETS")
}

pods_table() { k get pods -o wide 2>/dev/null | awk '{printf "    %-28s %-7s %-22s %s\n", $1, $2, $3, $4}'; }

deploy() {
  step "Instalando o Rekognitor (perfil $PROFILE)"
  kc create namespace "$NAMESPACE" --dry-run=client -o yaml | kc apply -f - >/dev/null
  if [[ -n ${DOCKERHUB_USERNAME:-} && -n ${DOCKERHUB_TOKEN:-} ]]; then
    k create secret docker-registry dockerhub --docker-server=https://index.docker.io/v1/ \
      --docker-username="$DOCKERHUB_USERNAME" --docker-password="$DOCKERHUB_TOKEN" \
      --dry-run=client -o yaml | kc apply -f - >/dev/null
    until k get sa default >/dev/null 2>&1; do sleep 1; done
    k patch sa default -p '{"imagePullSecrets":[{"name":"dockerhub"}]}' >/dev/null
    ok "pulls autenticados no Docker Hub"
  fi
  ensure_secrets
  local chart args
  for chart in $CHARTS; do
    [[ -d $ROOT/charts/$chart ]] || die "chart $chart não encontrado em $ROOT/charts"
    args=""
    [[ -f $ROOT/values/$PROFILE/$chart.yaml ]] && args="-f $ROOT/values/$PROFILE/$chart.yaml"
    case $chart in
      streamer) args="$args --set-string env.CLIENT_ID=$CLIENT_ID,env.SECRET=$API_SECRET" ;;
      mqtt) args="$args --set-string dashboard.authSecret=$MQTT_AUTH_SECRET" ;;
    esac
    # the customer's own overrides, kept across upgrades: ~/.rekognitor/values/<chart>.yaml
    [[ -f $REK_HOME/values/$chart.yaml ]] && args="$args -f $REK_HOME/values/$chart.yaml"
    # no --wait: helm would block forever on LoadBalancers without an external IP
    # shellcheck disable=SC2086
    KUBECONFIG=$KCFG helm upgrade --install "$chart" "$ROOT/charts/$chart" -n "$NAMESPACE" $args >/dev/null ||
      die "helm falhou ao instalar $chart"
    ok "$chart"
  done
  state_set CHARTS "$CHARTS"
  state_set PROFILE "$PROFILE"

  step "Aguardando os serviços (o 1º download das imagens pode levar alguns minutos)"
  local deadline=$((SECONDS + TIMEOUT)) pending w last=""
  while :; do
    pending=""
    for w in $(k get deploy,statefulset -o name); do
      k rollout status "$w" --timeout=1s >/dev/null 2>&1 || pending="$pending ${w#*/}"
    done
    [[ -z $pending ]] && break
    if ((SECONDS >= deadline)); then
      pods_table
      die "serviços não ficaram prontos em ${TIMEOUT}s:$pending. Veja: KUBECONFIG=$KCFG kubectl -n $NAMESPACE describe pods"
    fi
    if [[ $pending != "$last" ]]; then info "aguardando:$pending"; last=$pending; fi
    sleep 5
  done
  pods_table
  ok "todos os pods prontos"
}

health() {
  step "Testando a aplicação"
  local url=http://127.0.0.1:$UI_PORT h=""
  if [[ $CLUSTER == existing ]]; then
    # the cluster's NodePorts are not on this machine: go through a port-forward
    k port-forward svc/streamer 18085:8085 >/dev/null 2>&1 &
    PF_PID=$!
    trap 'kill $PF_PID 2>/dev/null || true' EXIT
    url=http://127.0.0.1:18085
  fi
  for _ in $(seq 60); do curl -fsS -m 5 -o /dev/null "$url/healthz" 2>/dev/null && break; sleep 3; done
  curl -fsS -m 5 -o /dev/null "$url/healthz" || die "a interface não respondeu em $url"
  ok "interface web respondendo em $url"
  # the streamer's gRPC connections to detect/vision may still be dialing
  for _ in $(seq 30); do
    h=$(curl -fsS -m 5 "$url/rtsp/health" 2>/dev/null || true)
    if echo "$h" | grep -q '"detect":{[^}]*"ok":true'; then break; fi
    sleep 4
  done
  if echo "$h" | grep -q '"detect":{[^}]*"ok":true'; then ok "detecção (detect) conectada"; else warn "detect ainda não respondeu: $h"; fi
  if echo "$h" | grep -q '"vision":{[^}]*"ok":true'; then ok "reconhecimento facial (vision) conectado"; fi
}

summary() {
  local ip
  ip=$(lan_ip)
  cat >"$REK_HOME/env" <<EOF
# source ~/.rekognitor/env  ->  kubectl/helm apontando para o cluster do Rekognitor
export KUBECONFIG="$KCFG"
export PATH="$BIN:\$PATH"
EOF
  state_set INSTALLED_AT "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '\n%s╔══════════════════════════════════════════════════════════╗%s\n' "$G$B" "$N"
  printf '%s║            Rekognitor instalado com sucesso!             ║%s\n' "$G$B" "$N"
  printf '%s╚══════════════════════════════════════════════════════════╝%s\n\n' "$G$B" "$N"
  cat <<EOF
  Interface web    http://localhost:$UI_PORT
                   na rede: http://$ip:$UI_PORT
  MQTT (câmeras)   $ip:1883   (WebSocket: $ip:1882)
  Perfil           $PROFILE

  Login da interface (guarde em local seguro; ficam em $SECRETS)
    Identificação do cliente (CLIENT_ID)  $CLIENT_ID
    Chave de acesso (SECRET)              $API_SECRET

  Comandos úteis
    source ~/.rekognitor/env && kubectl -n $NAMESPACE get pods
    $ROOT/install.sh      atualizar / reiniciar
    $ROOT/uninstall.sh    desinstalar
EOF
  if [[ $CLUSTER == k3d && $PLAT == darwin ]]; then
    echo
    warn "macOS: após reiniciar o Mac, rode o install.sh de novo para religar o Rekognitor."
  fi
}

# ----------------------------------------------------------------- main ----
printf '%sRekognitor — instalador%s  (%s, cluster: %s)\n' "$B" "$N" "$OS" "$CLUSTER"
mkdir -p "$BIN"
export PATH=$BIN:$PATH

if ! preflight; then
  [[ $CHECK_ONLY == 1 ]] && die "pré-requisitos não atendidos (veja os itens com !)"
  die "corrija os itens marcados com ! e rode de novo"
fi
if [[ $CHECK_ONLY == 1 ]]; then
  printf '\n%sTudo certo: esta máquina pode instalar o Rekognitor.%s\n' "$G$B" "$N"
  exit 0
fi

if [[ -z $PREV_CLUSTER ]]; then
  echo
  info "Serão instalados: Kubernetes ($CLUSTER), kubectl/helm (se faltarem) e os serviços"
  info "$CHARTS no namespace '$NAMESPACE'."
  confirm "Continuar?" || die "cancelado"
fi
[[ $CLUSTER == k3s && -n $SUDO ]] && { sudo -v || die "sudo é necessário para instalar o k3s"; }

state_set CLUSTER "$CLUSTER"
state_set ROOT "$ROOT"
step "Ferramentas"
ensure_helm
case $CLUSTER in
  k3s) cluster_k3s ;;
  k3d) ensure_kubectl; cluster_k3d ;;
  existing) ensure_kubectl; cluster_existing ;;
esac
pick_profile
deploy
health
summary
