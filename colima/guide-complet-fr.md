# Lab Kubernetes local sur macOS avec Colima, Kind et MetalLB

# Guide complet : installation, choix techniques et difficultés rencontrées

---

## 1. Origine et contexte

Ce guide s'appuie sur trois documents complémentaires et sur une mise en œuvre
réelle et testée sur macOS (Apple Silicon) :

| Source | Nature | Apport |
|---|---|---|
| [Building the best Kubernetes test cluster on MacOS](https://opencredo.com/blog/building-the-best-kubernetes-test-cluster-on-macos) — Matthew Revell-Gordon, OpenCredo, mai 2023 (`tutorial.html`) | Tutoriel original | La méthode générale : Colima + Kind + MetalLB, la configuration réseau et le test LoadBalancer |
| `kubernetes-colima-kind-metallb-lab-fr.md` | Lab adapté (FR) | Transposition aux valeurs réellement observées (`192.168.64.x`, interface `col0`), corrections des commandes fragiles |
| `INSTALL.md` | Compléments pratiques | Où s'exécute chaque commande, installation d'`iptables` dans la VM, piège IPv6 |
| Mise en œuvre et débogage réels (`lab.sh`) | Retour d'expérience | Deux difficultés **absentes de toutes les sources** : incompatibilité ARM64 de l'image de test et DROP d'isolation des Docker récents |

**Objectif du lab** : disposer localement d'un cluster Kubernetes multi-nœuds
aussi proche que possible d'un cluster managé cloud (EKS, GKE, AKS), notamment
pour les services `LoadBalancer`, sans Docker Desktop ni compte cloud.

---

## 2. Architecture cible

```text
                         macOS (Apple Silicon)
                    192.168.64.1 (bridge100)
                          │
                          │ route statique 172.19/16
                          ▼
                 ┌─────────────────────┐
                 │     VM Colima       │
                 │ Ubuntu 24.04 arm64  │
                 │ 192.168.64.2 (col0) │
                 │                     │
                 │ br-691e177f7cba     │
                 │  172.19.0.1         │
                 │ règle DOCKER-USER   │
                 └─────────┬───────────┘
                           │ 172.19.0.0/16 (Docker)
                           ▼
                    ┌─────────────┐
                    │ Kind cluster│
                    │ control-plane│
                    │ worker      │
                    │ worker      │
                    └──────┬──────┘
                           ▼
                        MetalLB ──► VIP 172.19.255.200
                           ▼
                  Service LoadBalancer :5678
                      ┌────┴────┐
                      ▼         ▼
                   foo-app   bar-app
```

Le chemin d'une requête depuis le Mac :

```text
curl (macOS)
  → route 172.19/16 via 192.168.64.2        [table de routage macOS]
  → col0                                    [entrée dans la VM]
  → chaîne iptables DOCKER-USER : ACCEPT    [pare-feu VM]
  → br-691e177f7cba                         [bridge Docker]
  → kube-proxy / IPVS                       [cluster Kind]
  → pod foo-app ou bar-app                  [réponse foo / bar]
```

Valeurs observées dans notre environnement (à redécouvrir chez vous, voir §5) :

| Élément | Valeur observée | Valeur dans le tuto original (2023) |
|---|---|---|
| Mac côté Colima | `192.168.64.1` (`bridge100`) | `192.168.106.1` (`bridge100`) |
| VM Colima | `192.168.64.2` | `192.168.106.2` |
| Interface VM | `col0` | `col0` |
| Réseau Docker Kind | `172.19.0.0/16` | `172.18.0.0/16` |
| Bridge Docker | `br-691e177f7cba` | variable |

---

## 3. Choix des composants

### Pourquoi pas Docker Desktop ?

Docker Desktop embarque son propre moteur et ses propres mécanismes réseau,
difficiles à contrôler finement. Le projet `docker-mac-net-connect` résout le
problème de routage automatiquement pour Docker Desktop, mais ne supportait
pas Colima au moment du tutoriel. Colima offre une VM Linux légère pilotable
en ligne de commande, gratuite et sans licence commerciale.

Alternative moderne non retenue ici : OrbStack (excellent support réseau natif,
mais autre philosophie et hors périmètre du tutoriel).

### Pourquoi Kind plutôt que minikube ou k3d ?

- **Kind** crée chaque nœud Kubernetes dans un conteneur Docker : un
  control-plane + N workers sans VM supplémentaire, configuration déclarative
  YAML, utilisé comme outil de test officiel de Kubernetes lui-même.
- minikube repose historiquement sur une VM dédiée (plus lourde).
- k3d est très bon aussi, mais Kind colle exactement aux manifests du tutoriel
  et à la documentation MetalLB.

Le multi-nœuds (1 control-plane + 2 workers) n'est pas décoratif : il permet
de tester la répartition de charge réelle entre pods placés sur des nœuds
distincts, ce qu'un cluster mono-nœud masque.

### Pourquoi MetalLB ?

Dans un cloud, un service `LoadBalancer` provoque la création d'un
équilibreur de charge managé par le fournisseur. En local, rien ne joue ce
rôle : MetalLB l'implémente (mode L2 ici) en attribuant une IP du réseau
Docker Kind à chaque service et en répondant à l'ARP. C'est ce qui permet de
consommer les mêmes manifests qu'en production.

Version utilisée : `v0.13.9` (celle du tutoriel ; des versions plus récentes
existent, vérifier avant un nouveau lab).

### Tableau récapitulatif

| Composant | Rôle | Version observée |
|---|---|---|
| Homebrew | Gestion des paquets macOS | — |
| Colima | VM Linux (Ubuntu 24.04 LTS, arm64) + runtime Docker | client 29.7.2 / serveur 29.5.2 |
| Docker CLI | Client uniquement ; le moteur vit dans la VM | 29.7.2 |
| Kind | Cluster K8s dans des conteneurs | nœuds Kubernetes v1.36.1 |
| kubectl | Pilotage du cluster | — |
| MetalLB | Implémentation `LoadBalancer` bare-metal | v0.13.9 |
| busybox httpd | Application de test echo | 1.36 |

---

## 4. Installation pas à pas

Toute cette installation est automatisée dans `lab.sh` (voir §7). Les
commandes ci-dessous sont la référence manuelle.

### 4.1 Prérequis

macOS avec Homebrew. Vérifier :

```bash
brew --version
```

### 4.2 Installer les outils

```bash
brew install docker colima kind kubectl
```

> `brew install docker` n'installe **pas** le moteur Docker : uniquement le
> CLI, qui parlera au moteur exposé par Colima dans la VM.

### 4.3 Démarrer Colima avec une adresse réseau

```bash
colima start --network-address
```

L'option `--network-address` est **indispensable** : elle donne à la VM une
adresse IP joignable depuis le Mac (`192.168.64.2`), sans laquelle aucune
route n'est possible.

Si Colima tourne déjà sans cette option :

```bash
colima stop && colima start --network-address
```

Vérifications :

```bash
colima list          # colonne ADDRESS ≠ "_"
docker info          # le client parle au moteur de la VM
```

### 4.4 Créer le cluster multi-nœuds

Fichier `kind-config.yaml` :

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kind-multi-node
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```bash
kind create cluster --config=kind-config.yaml --wait 300s
kubectl get nodes -o wide
```

### 4.5 Découvrir les paramètres réseau

Règle d'or : **tout découvrir dynamiquement**, rien de coder en dur. Ces
valeurs changent à chaque recréation du cluster.

```bash
# Adresse de la VM : la source fiable est colima list.
# ATTENTION : la route par défaut de la VM pointe souvent vers eth0
# (NAT interne Lima), PAS vers col0 — voir difficulté D5.
VM_IP=$(colima list | awk 'NR==2{print $NF}')          # 192.168.64.2

# Interface de la VM portant cette adresse
VM_IFACE=$(colima ssh -- bash -c \
  "ip -o -4 addr show | awk '\$4 ~ /^${VM_IP//./\\.}\// {print \$2}'")

# Adresse du Mac côté Colima : première adresse du subnet (convention Lima)
HOST_IP="${VM_IP%.*}.1"                                 # 192.168.64.1

# CIDR IPv4 du réseau kind (filtrer l'IPv6 ! — voir difficulté D2)
KIND_CIDR=$(docker network inspect kind \
  -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' |
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' | head -1) # 172.19.0.0/16

# Bridge Docker correspondant dans la VM
NET_ID=$(docker network inspect kind -f '{{.Id}}')
KIND_IFACE="br-${NET_ID:0:12}"                          # br-691e177f7cba
```

### 4.6 Route macOS vers le réseau Kind

```bash
sudo route -nv add -net "${KIND_CIDR%.*}" "$VM_IP"
netstat -rn -f inet | grep 172.19
```

Idempotence : supprimer la route existante avant de la ré-ajouter si la
passerelle a changé.

### 4.7 Règle de forwarding dans la VM

⚠️ **Point névralgique du lab** : la règle doit être posée dans la chaîne
**DOCKER-USER** (voir difficulté D4 pour l'explication complète).

```bash
RULE=(-s "$HOST_IP" -d "$KIND_CIDR" -i "$VM_IFACE" -o "$KIND_IFACE" -p tcp -j ACCEPT)

colima ssh -- sudo iptables -C DOCKER-USER "${RULE[@]}" 2>/dev/null ||
  colima ssh -- sudo iptables -I DOCKER-USER 1 "${RULE[@]}"
```

Le trafic **retour** (Kind → Mac) n'a besoin d'aucune règle supplémentaire :
la chaîne `DOCKER-FORWARD` de Docker accepte déjà le trafic sortant des
bridges (`-i br-xxx -j ACCEPT`).

### 4.8 Installer et configurer MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.9/config/manifests/metallb-native.yaml
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=300s
```

Pool d'adresses (fin du subnet Kind, plage calculée dynamiquement pour un
`/16` : `a.b.255.200-a.b.255.250`) — fichier `metallb-conf.yaml` :

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - 172.19.255.200-172.19.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-advertisement
  namespace: metallb-system
```

```bash
kubectl apply -f metallb-conf.yaml
```

Ne pas créer de pool en doublon si un pool couvrant déjà la plage existe.

---

## 5. Test de validation

Application de test : deux serveurs HTTP écho (`foo` et `bar`) derrière un
service `LoadBalancer` sur le port 5678 (manifest complet : `gen/test-service.yaml`
généré par `lab.sh test`).

```bash
./lab.sh test    # ou manuellement :
kubectl apply -f test-service.yaml
kubectl wait --for=condition=ready pod/foo-app pod/bar-app --timeout=180s

LB_IP=$(kubectl get svc/foo-bar-service \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "$LB_IP"            # ex. 172.19.255.200

for _ in {1..10}; do curl --max-time 5 "$LB_IP:5678"; done
```

**Critères de réussite** :

1. Une IP du pool apparaît dans `EXTERNAL-IP` du service ;
2. Les réponses alternent entre `foo` et `bar` (répartition effective) ;
3. Les compteurs de la règle iptables sont > 0 :

```bash
colima ssh -- sudo iptables -L DOCKER-USER -n -v
#   151 10814 ACCEPT  tcp -- col0 br-691e177f7cba 192.168.64.1 172.19.0.0/16
```

Résultat obtenu lors de la validation finale : 10 requêtes, `foo=3 bar=7`,
0 erreur, 151 paquets / 10 814 octets traversant la règle.

---

## 6. Difficultés rencontrées et solutions

C'est la section la plus importante : chacune de ces difficultés a réellement
bloqué la mise en œuvre et n'est que partiellement couverte par les sources.

### D1 — Le réseau macOS → VM → Docker n'existe pas par défaut

**Symptôme** : le Mac ne peut pas joindre les IP attribuées par MetalLB.

**Cause** : sous Linux, Docker tourne sur l'hôte et son bridge est directement
accessible. Sur macOS, Docker vit dans une VM : il y a un saut réseau de plus
(`macOS → VM Colima → bridge Docker → conteneurs`). Ni la route macOS ni le
forwarding VM ne sont configurés spontanément.

**Solution** : les deux étapes du tutoriel — route statique côté macOS (§4.6)
+ règle iptables côté VM (§4.7). C'est le cœur du lab.

### D2 — `docker network inspect` renvoie IPv6 ET IPv4

**Symptôme** : `KIND_CIDR` vaut `fc00:f853:ccd:e793::/64` et toute la suite
(route, iptables, pool MetalLB) part en vrille.

**Cause** : le réseau kind est dual-stack ; la commande du tutoriel original
(`cut -d'{' -f2`) prend le premier subnet venu, parfois l'IPv6. Par ailleurs,
les templates Go de Docker ne fournissent pas la fonction `contains`.

**Solution** : lister tous les subnets puis filtrer côté shell :

```bash
docker network inspect kind \
  -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' |
grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/'
```

### D3 — `colima ssh -- "$ssh_cmd"` échoue (`No such file or directory`)

**Cause** : Colima interprète la chaîne entière comme un nom d'exécutable.

**Solutions** : passer les arguments individuellement
(`colima ssh -- sudo iptables -A …`) ou encapsuler explicitement
(`colima ssh -- bash -c "…"`) — forme utilisée aussi pour la découverte
d'interface (§4.5) car les variables shell du Mac n'existent pas dans la VM.

### D4 — Docker récent (≥ 28/29) : le DROP d'isolation rend la règle FORWARD inefficace ⚠️ *Non documenté*

**Symptôme** : tout est en place (pods Running, EXTERNAL-IP attribué, ping VM
OK, SYN captés par `tcpdump` sur `col0`) mais `curl` expire et le compteur de
la règle `FORWARD` reste désespérément à **0 paquet**.

**Diagnostic** : dump du ruleset de la VM :

```text
Chain FORWARD (policy DROP)
 1  DOCKER-USER
 2  DOCKER-FORWARD        ← saut évalué AVANT notre règle
 3  ACCEPT tcp col0→br-691e177f7cba   (notre règle : jamais atteinte)

Chain DOCKER
 …
 ! -i br-691e177f7cba -o br-691e177f7cba -j DROP   ← coupable
```

**Cause** : depuis Docker 28+, la chaîne `DOCKER` se termine par un DROP
d'isolation pour chaque bridge. Tout paquet entrant vers le réseau kind depuis
une interface non-Docker (`col0`) est jeté **pendant** le saut
`DOCKER-FORWARD`, avant d'atteindre une règle ajoutée manuellement en bout de
`FORWARD`. La méthode originale du tutoriel (conçue pour un Docker ~23) est
donc devenue inefficace avec les versions actuelles.

**Solution** : poser la règle dans **`DOCKER-USER`**, première chaîne
évaluée, prévue précisément pour les règles utilisateur et jamais
réinitialisée par Docker :

```bash
sudo iptables -I DOCKER-USER 1 -s 192.168.64.1 -d 172.19.0.0/16 \
  -i col0 -o br-691e177f7cba -p tcp -j ACCEPT
```

Bonus : `-I DOCKER-USER 1` + test d'existence par `iptables -C` évite les
doublons à chaque relance.

### D5 — La route par défaut de la VM pointe vers eth0, pas col0 ⚠️ *Non documenté*

**Symptôme** : la découverte automatique renvoie `Mac = 192.168.5.2`,
`VM = 192.168.5.1 (eth0)` — un réseau qui n'a rien à voir avec Colima.

**Cause** : la VM Lima possède plusieurs interfaces. Sa route **par défaut**
peut sortir par `eth0` (NAT interne Lima) alors que l'interface partagée avec
le Mac est `col0` (`192.168.64.2`). Dériver `host_ip` de la passerelle par
défaut donne donc un mauvais résultat selon les versions.

**Solution** : se baser sur la colonne **ADDRESS de `colima list`** (c'est
exactement l'adresse que Colima expose pour ce usage), retrouver l'interface
portant cette IP, puis déduire le Mac par la convention Lima
(première adresse du subnet = `.1`).

### D6 — Image de test amd64-only sur Apple Silicon ⚠️ *Non documenté*

**Symptôme** : `foo-app` et `bar-app` en `CrashLoopBackOff` (15+ redémarrages),
alors que MetalLB fonctionne et a attribué l'IP externe.

**Diagnostic** : logs du pod — stack trace Go terminant par
`asm_amd64.s` ; `uname -m` du Mac = `arm64`, de la VM = `aarch64`.

**Cause** : `hashicorp/http-echo:0.2.3` (2018) n'existe qu'en architecture
`linux/amd64`. Le tutoriel date d'avant la généralisation d'Apple Silicon.

**Solution** : remplacer par un serveur multi-arch au comportement identique —
`busybox:1.36` + `httpd` servant un `index.html` monté depuis un ConfigMap
(`foo` / `bar`). Même contrat de test, images natives arm64.

### D7 — `iptables` absent de la VM Colima

Selon l'image Linux de la VM, `iptables` peut manquer. Il faut l'installer
**dans la VM** (pas sur le Mac !) :

```bash
colima ssh -- sudo apt-get update -qq
colima ssh -- sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables
```

Installer `iptables` via Homebrew sur macOS ne sert à rien : la règle agit sur
la pile réseau Linux de la VM.

### D8 — Valeurs volatiles et idempotence

Chaque recréation du cluster change le CIDR et l'ID du bridge (`br-xxxxxx`),
invalide la route et la règle. Conséquences pratiques intégrées à `lab.sh` :

- redécouverte systématique des paramètres avant application ;
- suppression/remplacement de la route existante plutôt qu'ajout brut ;
- `iptables -C` avant insertion (anti-doublon) ;
- détection d'un pool MetalLB couvrant déjà la plage (pas de doublon) ;
- réutilisation d'un cluster Kind existant plutôt que création d'un second.

---

## 7. Automatisation : `lab.sh`

Tout ce qui précède est scripté et idempotent dans [`lab.sh`](lab.sh) :

```bash
cd colima
./lab.sh install   # prérequis → Colima → cluster → découverte réseau → route → iptables → MetalLB
./lab.sh test      # déploiement foo/bar, attente IP LB, 10 curls, critères de réussite
./lab.sh status    # vue d'ensemble : cluster, MetalLB, route, chaîne DOCKER-USER
./lab.sh cleanup   # app de test + cluster Kind + route macOS
```

Comportements notables :

| Situation | Comportement du script |
|---|---|
| Cluster existant sous un autre nom | Adopté, aucun second cluster créé |
| Route déjà correcte | Validée sans demander sudo |
| Règle DOCKER-USER présente | Non dupliquée (`iptables -C`) |
| Pool MetalLB couvrant la plage | Réutilisé, pas de second pool |
| Colima sans `--network-address` | Erreur explicite avec la commande corrective |

Les paramètres découverts sont persistés dans `gen/.lab-env`, les manifests
générés dans `gen/`.

Variables utiles : `CLUSTER_NAME`, `METALLB_VERSION` (défaut `v0.13.9`),
`METALLB_POOL`, `CURL_COUNT`.

Nettoyage complet (hors script) :

```bash
kind delete cluster --name kind-multi-node
colima stop          # voire colima delete pour tout effacer
```

---

## 8. Bilan

| Aspect | Verdict |
|---|---|
| Faisabilité du tutoriel original en 2023 | ✅ telle quelle |
| Reproductibilité telle quelle aujourd'hui (Docker 29, Apple Silicon) | ❌ 2 blocages majeurs (D4, D6) |
| Avec les correctifs de ce guide (`lab.sh`) | ✅ testé de bout en bout |
| Intérêt pédagogique | Élevé : réseau multi-couches, iptables, MetalLB, idempotence |

La valeur durable de ce lab dépasse le simple « ça marche » : il oblige à
comprendre où vivent réellement Docker et Kubernetes sur macOS, comment le
trafic traverse quatre couches réseau, et ce que fait un contrôleur
`LoadBalancer` — des connaissances directement transférables aux environnements
cloud.

---

## Références

- Tutoriel original : https://opencredo.com/blog/building-the-best-kubernetes-test-cluster-on-macos (Matthew Revell-Gordon, OpenCredo, 18 mai 2023)
- Documentation Kind : https://kind.sigs.k8s.io/
- Documentation MetalLB : https://metallb.universe.tf/
- Chaîne DOCKER-USER (doc Docker) : https://docs.docker.com/network/packet-filtering-firewalls/
- Scripts et manifests de ce lab : [`lab.sh`](lab.sh), `gen/`
