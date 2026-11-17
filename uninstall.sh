#!/usr/bin/env bash
# Rekognitor uninstaller for Linux and macOS (also used by uninstall-windows.cmd
# inside WSL).
#
#   ./uninstall.sh [--keep-cluster] [--yes]
#
# Removes the rekognitor charts and namespace (including the enrolled faces),
# then only what install.sh itself installed, as recorded in ~/.rekognitor/state:
# the k0s it installed (k0s reset), the k0s container and Colima VM it created,
# the Homebrew packages it added and ~/.rekognitor. A k0s/Docker that was already on the
# machine is left alone.
# shellcheck disable=SC2015 # "cmd && ok || warn": ok only prints
set -euo pipefail

REK_HOME=${REKOGNITOR_HOME:-$HOME/.rekognitor}
STATE=$REK_HOME/state
CONTAINER=rekognitor-k0s
API_PORT_DOCKER=16443
NAMESPACE=rekognitor
KEEP_CLUSTER=0 YES=0

if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' C=$'\e[36m' N=$'\e[0m'; else B="" G="" Y="" R="" C="" N=""; fi
step() { printf '\n%s==> %s%s\n' "$C$B" "$*" "$N"; }
ok() { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die() { printf '\n%s✘ ERRO:%s %s\n' "$R$B" "$N" "$*" >&2; exit 1; }

while (($#)); do
  case $1 in
    --keep-cluster) KEEP_CLUSTER=1 ;;
    -y | --yes) YES=1 ;;
    -h | --help)
      cat <<EOF
Desinstalador do Rekognitor (Linux / macOS)

Uso: $0 [--keep-cluster] [--yes]

  --keep-cluster   remove só o Rekognitor; mantém o Kubernetes e as ferramentas
  -y, --yes        não pede confirmação
EOF
      exit 0 ;;
    *) die "opção desconhecida: $1" ;;
  esac
  shift
done

[[ -f $STATE ]] || die "não encontrei $STATE: o Rekognitor não foi instalado por este instalador neste usuário."
state_get() { sed -n "s/^$1=//p" "$STATE" | tail -1; }
CLUSTER=$(state_get CLUSTER)
CHARTS=$(state_get CHARTS)
K0S_INSTALLED=$(state_get K0S_INSTALLED)
K0S_CONTAINER=$(state_get K0S_CONTAINER)
COLIMA_PROFILE=$(state_get COLIMA_PROFILE)
BREW_INSTALLED=$(state_get BREW_INSTALLED)
SUDO=""
[[ $(id -u) -ne 0 ]] && SUDO=sudo
export PATH=$REK_HOME/bin:$PATH
[[ -n $COLIMA_PROFILE ]] && export DOCKER_HOST=unix://$HOME/.colima/$COLIMA_PROFILE/docker.sock

printf '%sRekognitor — desinstalador%s\n\n' "$B" "$N"
echo "Será removido:"
info "• serviços do Rekognitor: ${CHARTS:-?} (namespace $NAMESPACE)"
info "• os rostos cadastrados, as configurações salvas e as credenciais da API (Secret)"
if [[ $KEEP_CLUSTER == 0 ]]; then
  [[ $K0S_INSTALLED == 1 ]] && info "• o k0s (Kubernetes) instalado pelo Rekognitor"
  [[ -n $K0S_CONTAINER ]] && info "• o contêiner k0s '$K0S_CONTAINER' e o volume dele"
  [[ -n $COLIMA_PROFILE ]] && info "• a VM Colima '$COLIMA_PROFILE'"
  [[ -n $BREW_INSTALLED ]] && info "• pacotes Homebrew instalados pelo Rekognitor:$BREW_INSTALLED"
  info "• a pasta $REK_HOME"
fi
if [[ $YES == 0 ]]; then
  read -r -p "Confirmar a desinstalação? [s/N] " a || true
  [[ $a == s || $a == S || $a == y || $a == Y ]] || die "cancelado"
fi
[[ $CLUSTER == k0s && -n $SUDO ]] && { sudo -v || die "sudo é necessário para acessar o k0s"; }

# admin kubeconfig only in a private temp dir while this runs (as in install.sh)
TMPD=$(mktemp -d)
chmod 700 "$TMPD"
trap 'rm -rf "$TMPD"' EXIT
KCFG=$TMPD/kubeconfig
case $CLUSTER in
  k0s) [[ -x /usr/local/bin/k0s ]] && $SUDO /usr/local/bin/k0s kubeconfig admin >"$KCFG" 2>/dev/null || true ;;
  k0s-docker)
    if docker exec "$CONTAINER" k0s kubeconfig admin >"$KCFG" 2>/dev/null; then
      sed "s#server: https://.*#server: https://127.0.0.1:$API_PORT_DOCKER#" "$KCFG" >"$KCFG.tmp" && mv "$KCFG.tmp" "$KCFG"
    fi ;;
  existing) kubectl config view --raw --minify >"$KCFG" 2>/dev/null || true ;;
esac

step "Removendo o Rekognitor"
if [[ -s $KCFG ]] && KUBECONFIG=$KCFG kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  for chart in $CHARTS; do
    KUBECONFIG=$KCFG helm uninstall "$chart" -n "$NAMESPACE" >/dev/null 2>&1 && ok "$chart" || true
  done
  # StatefulSet PVCs (vision's faces) and the rekognitor-credentials Secret outlive
  # helm uninstall: deleting the namespace takes them
  KUBECONFIG=$KCFG kubectl delete namespace "$NAMESPACE" --timeout=180s >/dev/null 2>&1 || warn "o namespace $NAMESPACE demorou a ser removido"
  ok "namespace $NAMESPACE removido"
else
  warn "cluster inacessível ou namespace já removido: pulando"
fi

if [[ $KEEP_CLUSTER == 1 ]]; then
  # keep the state so a later install.sh reuses the cluster
  sed -i.bak -e '/^CHARTS=/d' -e '/^PROFILE=/d' -e '/^INSTALLED_AT=/d' "$STATE" && rm -f "$STATE.bak"
  printf '\n%sRekognitor removido. O Kubernetes foi mantido.%s\n' "$G$B" "$N"
  exit 0
fi

step "Removendo o Kubernetes e as ferramentas"
if [[ $K0S_INSTALLED == 1 ]]; then
  if [[ -x /usr/local/bin/k0s ]]; then
    # k0s reset removes the service, /var/lib/k0s, /etc/k0s and the CNI state
    $SUDO /usr/local/bin/k0s stop >/dev/null 2>&1 || true
    if $SUDO /usr/local/bin/k0s reset >/dev/null 2>&1; then ok "k0s parado e resetado"; else warn "k0s reset falhou"; fi
    $SUDO rm -f /usr/local/bin/k0s
    ok "k0s removido"
    REBOOT_HINT=1
  else warn "/usr/local/bin/k0s não encontrado (k0s já removido?)"; fi
elif [[ $CLUSTER == k0s ]]; then
  info "o k0s já existia antes do Rekognitor: mantido"
fi
if [[ -n $K0S_CONTAINER ]] && command -v docker >/dev/null; then
  docker rm -f "$K0S_CONTAINER" >/dev/null 2>&1 && ok "contêiner $K0S_CONTAINER removido" || warn "falha ao remover o contêiner $K0S_CONTAINER"
  docker volume rm "$K0S_CONTAINER" >/dev/null 2>&1 && ok "volume $K0S_CONTAINER removido" || true
fi
if [[ -n $COLIMA_PROFILE ]] && command -v colima >/dev/null; then
  colima delete "$COLIMA_PROFILE" --force >/dev/null 2>&1 && ok "VM Colima '$COLIMA_PROFILE' removida" || warn "falha ao remover a VM Colima"
fi
if [[ -n $BREW_INSTALLED ]] && command -v brew >/dev/null; then
  # shellcheck disable=SC2086
  brew uninstall $BREW_INSTALLED >/dev/null 2>&1 && ok "Homebrew:$BREW_INSTALLED removidos" || warn "brew uninstall$BREW_INSTALLED falhou"
fi
case $REK_HOME in
  "" | / | "$HOME") die "REKOGNITOR_HOME inválido: $REK_HOME" ;;
esac
rm -rf "$REK_HOME"
ok "$REK_HOME removida"

printf '\n%sRekognitor desinstalado.%s\n' "$G$B" "$N"
if [[ ${REBOOT_HINT:-0} == 1 ]]; then
  info "Recomendação do k0s: reinicie a máquina para limpar as regras de rede (iptables) que restarem."
fi
