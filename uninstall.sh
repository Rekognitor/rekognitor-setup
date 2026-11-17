#!/usr/bin/env bash
# Rekognitor uninstaller for Linux and macOS (also used by uninstall-windows.cmd
# inside WSL).
#
#   ./uninstall.sh [--keep-cluster] [--yes]
#
# Removes the rekognitor charts and namespace (including the enrolled faces),
# then only what install.sh itself installed, as recorded in ~/.rekognitor/state:
# the k3s it installed, the k3d cluster and Colima VM it created, the Homebrew
# packages it added and ~/.rekognitor. A k3s/Docker that was already on the
# machine is left alone.
# shellcheck disable=SC2015 # "cmd && ok || warn": ok only prints
set -euo pipefail

REK_HOME=${REKOGNITOR_HOME:-$HOME/.rekognitor}
STATE=$REK_HOME/state
KCFG=$REK_HOME/kubeconfig
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
K3S_INSTALLED=$(state_get K3S_INSTALLED)
K3D_CLUSTER=$(state_get K3D_CLUSTER)
COLIMA_PROFILE=$(state_get COLIMA_PROFILE)
BREW_INSTALLED=$(state_get BREW_INSTALLED)
SUDO=""
[[ $(id -u) -ne 0 ]] && SUDO=sudo
export PATH=$REK_HOME/bin:$PATH
[[ -n $COLIMA_PROFILE ]] && export DOCKER_HOST=unix://$HOME/.colima/$COLIMA_PROFILE/docker.sock

printf '%sRekognitor — desinstalador%s\n\n' "$B" "$N"
echo "Será removido:"
info "• serviços do Rekognitor: ${CHARTS:-?} (namespace $NAMESPACE)"
info "• os rostos cadastrados e as configurações salvas"
if [[ $KEEP_CLUSTER == 0 ]]; then
  [[ $K3S_INSTALLED == 1 ]] && info "• o k3s (Kubernetes) instalado pelo Rekognitor"
  [[ -n $K3D_CLUSTER ]] && info "• o cluster k3d '$K3D_CLUSTER'"
  [[ -n $COLIMA_PROFILE ]] && info "• a VM Colima '$COLIMA_PROFILE'"
  [[ -n $BREW_INSTALLED ]] && info "• pacotes Homebrew instalados pelo Rekognitor:$BREW_INSTALLED"
  info "• a pasta $REK_HOME"
fi
if [[ $YES == 0 ]]; then
  read -r -p "Confirmar a desinstalação? [s/N] " a || true
  [[ $a == s || $a == S || $a == y || $a == Y ]] || die "cancelado"
fi
[[ $KEEP_CLUSTER == 0 && $K3S_INSTALLED == 1 && -n $SUDO ]] && { sudo -v || die "sudo é necessário para remover o k3s"; }

step "Removendo o Rekognitor"
if [[ -f $KCFG ]] && KUBECONFIG=$KCFG kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  for chart in $CHARTS; do
    KUBECONFIG=$KCFG helm uninstall "$chart" -n "$NAMESPACE" >/dev/null 2>&1 && ok "$chart" || true
  done
  # StatefulSet PVCs (vision's faces) outlive helm uninstall: the namespace takes them
  KUBECONFIG=$KCFG kubectl delete namespace "$NAMESPACE" --timeout=180s >/dev/null 2>&1 || warn "o namespace $NAMESPACE demorou a ser removido"
  ok "namespace $NAMESPACE removido"
else
  warn "cluster inacessível ou namespace já removido: pulando"
fi

if [[ $KEEP_CLUSTER == 1 ]]; then
  # keep state/kubeconfig so a later install.sh reuses the cluster
  sed -i.bak -e '/^CHARTS=/d' -e '/^PROFILE=/d' -e '/^INSTALLED_AT=/d' "$STATE" && rm -f "$STATE.bak"
  printf '\n%sRekognitor removido. O Kubernetes foi mantido.%s\n' "$G$B" "$N"
  exit 0
fi

step "Removendo o Kubernetes e as ferramentas"
if [[ $K3S_INSTALLED == 1 ]]; then
  if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    $SUDO /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1 && ok "k3s removido" || warn "k3s-uninstall.sh falhou"
  else warn "k3s-uninstall.sh não encontrado (k3s já removido?)"; fi
elif [[ $CLUSTER == k3s ]]; then
  info "k3s já existia antes do Rekognitor: mantido"
fi
if [[ -n $K3D_CLUSTER ]] && command -v k3d >/dev/null; then
  k3d cluster delete "$K3D_CLUSTER" >/dev/null 2>&1 && ok "cluster k3d '$K3D_CLUSTER' removido" || warn "falha ao remover o cluster k3d"
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
