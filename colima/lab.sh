#!/usr/bin/env bash
# lab.sh — Lab Kubernetes local sur macOS : Colima + Kind + MetalLB
# Basé sur kubernetes-colima-kind-metallb-lab-fr.replicatset-daemonset.md
#
# Usage :
#   ./lab.sh install   # prérequis + Colima + cluster Kind + réseau + MetalLB
#   ./lab.sh test      # app foo/bar via LoadBalancer + vérifications
#   ./lab.sh status    # état du lab
#   ./lab.sh cleanup   # suppression app test, cluster, route macOS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN_DIR="$SCRIPT_DIR/gen"
ENV_FILE="$GEN_DIR/.lab-env"

CLUSTER_NAME="${CLUSTER_NAME:-kind-multi-node}"
METALLB_VERSION="${METALLB_VERSION:-v0.13.9}"
METALLB_POOL="${METALLB_POOL:-}"
LB_SERVICE="foo-bar-service"
LB_PORT="${LB_PORT:-5678}"
CURL_COUNT="${CURL_COUNT:-10}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m [ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m [!!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m [ko]\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
vm()   { colima ssh -- "$@"; }

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

load_env() {
  [[ -f "$ENV_FILE" ]] && . "$ENV_FILE" || true
}

# ---------------------------------------------------------------------------
# Découverte des paramètres réseau (à recalculer à chaque recréation du cluster)
# ---------------------------------------------------------------------------
discover_network() {
  log "Découverte des paramètres réseau"

  # L'adresse exposée par Colima (--network-address) est la référence fiable :
  # la route par défaut de la VM peut pointer vers l'interface NAT interne de
  # Lima (eth0) et non vers l'interface partagée avec le Mac (col0)
  VM_IP="$(colima list | awk 'NR==2{print $NF}')"
  [[ -n "$VM_IP" && "$VM_IP" != "_" ]] ||
    die "Colima n'expose pas d'adresse réseau (recréer avec --network-address)"

  escaped_ip="${VM_IP//./\\.}"
  VM_IFACE="$(vm bash -c "ip -o -4 addr show | awk '\$4 ~ /^${escaped_ip}\// {print \$2}'" | head -1)"
  [[ -n "$VM_IFACE" ]] || die "Interface portant l'IP $VM_IP introuvable dans la VM"

  # Convention Lima/socketvmnet : le Mac occupe la première adresse du subnet
  HOST_IP="${VM_IP%.*}.1"

  KIND_CIDR="$(docker network inspect kind \
    -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' |
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' | head -1)"

  [[ -n "${VM_IFACE:-}" && -n "${HOST_IP:-}" && -n "${KIND_CIDR:-}" ]] ||
    die "Paramètres réseau incomplets (iface=$VM_IFACE host=$HOST_IP cidr=$KIND_CIDR)"

  KIND_CIDR_SHORT="$(printf '%s' "$KIND_CIDR" | cut -d. -f1-2)"

  NET_ID="$(docker network inspect kind -f '{{.Id}}')"
  KIND_IFACE="br-${NET_ID:0:12}"
  vm ip link show dev "$KIND_IFACE" >/dev/null 2>&1 ||
    die "Bridge $KIND_IFACE introuvable dans la VM Colima"

  if [[ -n "$METALLB_POOL" ]]; then
    POOL="$METALLB_POOL"
  else
    prefix="${KIND_CIDR##*/}"
    case "$prefix" in
      16)
        b="$(printf '%s' "$KIND_CIDR" | cut -d. -f1-2)"
        POOL="${b}.255.200-${b}.255.250"
        ;;
      24)
        b="$(printf '%s' "$KIND_CIDR" | cut -d. -f1-3)"
        POOL="${b}.200-${b}.250"
        ;;
      *)
        die "Préfixe /$prefix non géré : définissez METALLB_POOL=a.b.c.d-a.b.c.e"
        ;;
    esac
  fi

  mkdir -p "$GEN_DIR"
  cat > "$ENV_FILE" <<ENV
CLUSTER_NAME='$CLUSTER_NAME'
HOST_IP='$HOST_IP'
VM_IP='$VM_IP'
VM_IFACE='$VM_IFACE'
KIND_CIDR='$KIND_CIDR'
KIND_CIDR_SHORT='$KIND_CIDR_SHORT'
KIND_IFACE='$KIND_IFACE'
POOL='$POOL'
ENV

  printf '  Mac côté Colima : %s\n  VM Colima       : %s (interface %s)\n  Réseau Kind     : %s (bridge %s)\n  Pool MetalLB    : %s\n' \
    "$HOST_IP" "$VM_IP" "$VM_IFACE" "$KIND_CIDR" "$KIND_IFACE" "$POOL"
}

ensure_route() {
  log "Route macOS : $KIND_CIDR_SHORT/16 via $VM_IP"
  current_gw="$(netstat -rn -f inet | awk -v p="$KIND_CIDR_SHORT" 'index($1, p) == 1 {print $2; exit}')"
  if [[ "$current_gw" == "$VM_IP" ]]; then
    ok "Route déjà correcte ($KIND_CIDR_SHORT via $VM_IP)"
    return
  fi
  log "Modification de la route (mot de passe sudo demandé)"
  sudo route -nv delete -net "$KIND_CIDR_SHORT" >/dev/null 2>&1 || true
  sudo route -nv add -net "$KIND_CIDR_SHORT" "$VM_IP"
  netstat -rn -f inet | grep -Eq "^${KIND_CIDR_SHORT}(/|[[:space:]])" ||
    die "Route $KIND_CIDR_SHORT absente après ajout"
  ok "Route macOS active"
}

ensure_iptables_rule() {
  if ! vm which iptables >/dev/null 2>&1; then
    log "Installation d'iptables dans la VM Colima"
    vm sudo apt-get update -qq >/dev/null
    vm sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables >/dev/null
  fi

  RULE=(-s "$HOST_IP" -d "$KIND_CIDR" -i "$VM_IFACE" -o "$KIND_IFACE" -p tcp -j ACCEPT)

  # Nettoyage des anciennes règles posées dans FORWARD (inefficaces depuis
  # Docker 28+ : la chaîne DOCKER termine par un DROP d'isolation évalué avant)
  vm sudo iptables -D FORWARD "${RULE[@]}" >/dev/null 2>&1 || true

  # La chaîne DOCKER-USER est évaluée en premier par Docker et n'est jamais
  # réinitialisée par lui : c'est l'emplacement prévu pour ce type de règle
  if vm sudo iptables -C DOCKER-USER "${RULE[@]}" 2>/dev/null; then
    ok "Règle iptables déjà présente dans DOCKER-USER"
  else
    vm sudo iptables -I DOCKER-USER 1 "${RULE[@]}"
    ok "Règle iptables ajoutée dans DOCKER-USER"
  fi

  # Le trafic retour (réseau Kind -> Mac) est couvert par l'ACCEPT
  # 'RELATED,ESTABLISHED' / '-i br-xxx' de DOCKER-FORWARD
}

install_metallb() {
  log "Installation de MetalLB $METALLB_VERSION"
  kubectl apply \
    -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" >/dev/null
  kubectl wait --namespace metallb-system \
    --for=condition=ready pod \
    --selector=app=metallb \
    --timeout=300s >/dev/null
  ok "Pods MetalLB prêts"

  if kubectl get ipaddresspool -n metallb-system -o jsonpath='{range .items[*]}{.spec.addresses[*]}{"\n"}{end}' 2>/dev/null | grep -F "$POOL" >/dev/null; then
    ok "Un pool MetalLB couvrant $POOL existe déjà"
    return
  fi

  log "Configuration du pool MetalLB : $POOL"
  cat > "$GEN_DIR/metallb-conf.yaml" <<YAML
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - $POOL
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-advertisement
  namespace: metallb-system
YAML
  kubectl apply -f "$GEN_DIR/metallb-conf.yaml" >/dev/null
  kubectl get ipaddresspool,l2advertisement -n metallb-system
  ok "IPAddressPool + L2Advertisement appliqués"
}

# ---------------------------------------------------------------------------
# Commandes
# ---------------------------------------------------------------------------
cmd_install() {
  [[ "$(uname)" == "Darwin" ]] || die "Ce lab est prévu pour macOS"
  have brew || die "Homebrew est requis (https://brew.sh)"

  log "Vérification des outils (docker, colima, kind, kubectl)"
  for tool in docker colima kind kubectl; do
    if have "$tool"; then
      ok "$tool déjà installé"
    else
      log "Installation de $tool via Homebrew"
      brew install "$tool"
    fi
  done

  log "Démarrage de Colima avec --network-address"
  if ! colima status >/dev/null 2>&1; then
    colima start --network-address
  else
    addr="$(colima list | awk 'NR==2{print $NF}')"
    if [[ -z "$addr" || "$addr" == "_" ]]; then
      die "Colima tourne sans adresse réseau : exécutez 'colima stop && colima start --network-address'"
    fi
    ok "Colima déjà démarré avec l'adresse $addr"
  fi
  docker info >/dev/null 2>&1 || die "Le client Docker ne communique pas avec Colima"
  ok "Moteur Docker (Colima) accessible"

  log "Cluster Kind"
  EXISTING_CLUSTERS="$(kind get clusters 2>/dev/null || true)"
  if printf '%s\n' "$EXISTING_CLUSTERS" | grep -qx "$CLUSTER_NAME"; then
    ok "Cluster '$CLUSTER_NAME' déjà existant"
  elif [[ -n "$EXISTING_CLUSTERS" ]]; then
    CLUSTER_NAME="$(printf '%s\n' "$EXISTING_CLUSTERS" | head -1)"
    warn "Cluster '$CLUSTER_NAME' trouvé : réutilisé (aucun nouveau cluster créé)"
    mkdir -p "$GEN_DIR"
    printf "CLUSTER_NAME='%s'\n" "$CLUSTER_NAME" > "$ENV_FILE"
  else
    ROOT_CONFIG="$SCRIPT_DIR/../kind-config.yaml"
    if [[ "$CLUSTER_NAME" == "kind-multi-node" && -f "$ROOT_CONFIG" ]]; then
      CFG_PATH="$ROOT_CONFIG"
    else
      mkdir -p "$GEN_DIR"
      CFG_PATH="$GEN_DIR/kind-config.yaml"
      cat > "$CFG_PATH" <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER_NAME
nodes:
  - role: control-plane
  - role: worker
  - role: worker
YAML
    fi
    log "Création du cluster multi-nœuds ($CFG_PATH)"
    kind create cluster --config "$CFG_PATH" --wait 300s
  fi
  kubectl wait node --all --for=condition=ready --timeout=180s >/dev/null
  ok "Nœuds prêts"
  kubectl get nodes -o wide

  docker network inspect kind >/dev/null 2>&1 || die "Réseau Docker 'kind' introuvable"
  discover_network
  ensure_route
  ensure_iptables_rule
  install_metallb

  echo
  ok "Installation terminée. Lancez './lab.sh test' pour valider le LoadBalancer."
}

cmd_test() {
  load_env
  mkdir -p "$GEN_DIR"

  current_ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ "$current_ctx" == "kind-$CLUSTER_NAME" ]] ||
    warn "Contexte kubectl courant '$current_ctx' ≠ kind-$CLUSTER_NAME"

  log "Déploiement de l'application de test (foo / bar)"
  cat > "$GEN_DIR/test-service.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: foo-html
data:
  index.html: foo
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: bar-html
data:
  index.html: bar
---
apiVersion: v1
kind: Pod
metadata:
  name: foo-app
  labels:
    app: http-echo
spec:
  containers:
    - name: foo-app
      image: busybox:1.36
      command: ["httpd", "-f", "-p", "5678", "-h", "/www"]
      volumeMounts:
        - name: html
          mountPath: /www
  volumes:
    - name: html
      configMap:
        name: foo-html
---
apiVersion: v1
kind: Pod
metadata:
  name: bar-app
  labels:
    app: http-echo
spec:
  containers:
    - name: bar-app
      image: busybox:1.36
      command: ["httpd", "-f", "-p", "5678", "-h", "/www"]
      volumeMounts:
        - name: html
          mountPath: /www
  volumes:
    - name: html
      configMap:
        name: bar-html
---
apiVersion: v1
kind: Service
metadata:
  name: foo-bar-service
spec:
  type: LoadBalancer
  selector:
    app: http-echo
  ports:
    - port: 5678
YAML
  kubectl apply -f "$GEN_DIR/test-service.yaml" >/dev/null
  kubectl wait --for=condition=ready pod/foo-app pod/bar-app --timeout=180s >/dev/null
  ok "Pods foo-app et bar-app prêts"

  log "Attente de l'IP LoadBalancer attribuée par MetalLB"
  LB_IP=""
  for _ in $(seq 1 40); do
    LB_IP="$(kubectl get svc/$LB_SERVICE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$LB_IP" ]] && break
    sleep 3
  done
  [[ -n "$LB_IP" ]] || die "Aucune IP LoadBalancer attribuée après 120 s"
  ok "IP LoadBalancer : $LB_IP:$LB_PORT"

  log "Requêtes depuis le Mac ($CURL_COUNT requêtes vers http://$LB_IP:$LB_PORT)"
  foo_count=0
  bar_count=0
  errors=0
  i=0
  while [[ $i -lt "$CURL_COUNT" ]]; do
    i=$((i + 1))
    resp="$(curl -sS --max-time 5 "http://$LB_IP:$LB_PORT/" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$resp" in
      foo) foo_count=$((foo_count + 1)) ;;
      bar) bar_count=$((bar_count + 1)) ;;
      *)   errors=$((errors + 1)); resp="<échec>" ;;
    esac
    printf '  [%02d] %s\n' "$i" "$resp"
  done

  echo
  echo "Répartition : foo=$foo_count bar=$bar_count erreurs=$errors"
  [[ "$foo_count" -gt 0 && "$bar_count" -gt 0 ]] ||
    die "Le trafic n'est pas réparti entre foo et bar"
  ok "Répartition LoadBalancer validée"

  kubectl get endpoints "$LB_SERVICE" 2>/dev/null || true

  if [[ -n "${KIND_IFACE:-}" && -n "${HOST_IP:-}" ]]; then
    log "Compteurs iptables dans la VM Colima"
    vm sudo iptables -L DOCKER-USER -n -v | awk -v f="$KIND_IFACE" 'NR<=2 || index($0, f)'
  fi

  echo
  ok "TEST RÉUSSI : le service LoadBalancer répond depuis le Mac via MetalLB."
}

cmd_status() {
  load_env
  echo "--- Paramètres réseau mémorisés ($ENV_FILE)"
  if [[ -f "$ENV_FILE" ]]; then
    sed 's/^/  /' "$ENV_FILE"
  else
    warn "aucun fichier d'environnement (lancez ./lab.sh install)"
  fi
  echo
  echo "--- Clusters Kind"
  kind get clusters 2>/dev/null || true
  echo
  echo "--- Nœuds"
  kubectl get nodes -o wide 2>/dev/null || true
  echo
  echo "--- Pods (tous namespaces)"
  kubectl get pods -A 2>/dev/null || true
  echo
  echo "--- Services"
  kubectl get svc -A 2>/dev/null || true
  echo
  echo "--- MetalLB"
  kubectl get ipaddresspool,l2advertisement -n metallb-system 2>/dev/null || true
  echo
  echo "--- Route macOS vers le réseau Kind"
  if [[ -n "${KIND_CIDR_SHORT:-}" ]]; then
    netstat -rn -f inet | grep -E "^${KIND_CIDR_SHORT}(/|[[:space:]])" || warn "route absente"
  fi
  echo
  echo "--- Chaîne iptables DOCKER-USER (VM Colima)"
  vm sudo iptables -L DOCKER-USER -n -v 2>/dev/null | head -15 || true
}

cmd_cleanup() {
  load_env
  log "Suppression de l'application de test"
  kubectl delete -f "$GEN_DIR/test-service.yaml" --ignore-not-found >/dev/null 2>&1 || true

  log "Suppression du cluster Kind '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true

  if [[ -n "${KIND_CIDR_SHORT:-}" ]]; then
    log "Suppression de la route macOS $KIND_CIDR_SHORT (sudo)"
    sudo route -nv delete -net "$KIND_CIDR_SHORT" >/dev/null 2>&1 || true
  fi

  rm -f "$ENV_FILE"
  ok "Nettoyage terminé (Colima reste actif ; utilisez 'colima stop' pour l'arrêter)"
}

main() {
  [[ $# -ge 1 ]] || { usage; exit 1; }
  case "$1" in
    install) shift; cmd_install "$@" ;;
    test)    shift; cmd_test "$@" ;;
    status)  shift; cmd_status "$@" ;;
    cleanup) shift; cmd_cleanup "$@" ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
