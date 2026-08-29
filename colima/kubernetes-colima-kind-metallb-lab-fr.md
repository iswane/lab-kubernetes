# Lab Kubernetes local sur macOS avec Colima, Kind et MetalLB

> **Objectif :** construire sur macOS un cluster Kubernetes multi-nœuds avec [Kind](https://kind.sigs.k8s.io/), exécuté dans [Colima](https://github.com/abiosoft/colima), puis utiliser [MetalLB](https://metallb.universe.tf/) pour fournir des `LoadBalancer` Kubernetes accessibles depuis le Mac.
>
> Ce lab est adapté du tutoriel OpenCredo *Building the best Kubernetes test cluster on MacOS*. Les commandes de réseau ont été adaptées à l'environnement réellement utilisé dans ce lab.

---

## 1. Architecture du lab

Le principe est de reproduire localement une architecture proche d'un cluster Kubernetes hébergé dans le cloud.

Les composants sont :

- Docker CLI
- Colima
- Kind
- Kubernetes multi-nœuds
- MetalLB
- une application Kubernetes exposée par un service `LoadBalancer`

### Architecture réseau utilisée dans ce lab

Dans notre environnement, les adresses observées sont :

| Élément | Valeur |
|---|---|
| Mac, côté réseau Colima | `192.168.64.1` |
| VM Colima | `192.168.64.2` |
| Interface Colima | `col0` |
| Réseau Docker Kind | `172.19.0.0/16` |
| Bridge Docker Kind | `br-691e177f7cba` |

Le chemin réseau est donc :

```text
Mac
192.168.64.1
   │
   │ col0
   ▼
VM Colima
192.168.64.2
   │
   │ br-691e177f7cba
   ▼
Réseau Docker Kind
172.19.0.0/16
   │
   ├── control-plane
   ├── worker
   └── worker
```

> **Important :** les valeurs du réseau Kind et du bridge peuvent changer lors de la recréation du cluster. Il faut donc les découvrir plutôt que de les coder en dur dans les scripts.

---

# 2. Prérequis

Le lab suppose que macOS est utilisé avec Homebrew et `kubectl`.

Docker Desktop n'est pas nécessaire.

Vérifier :

```bash
brew --version
kubectl version --client
```

---

# 3. Installer Docker CLI

Colima fournit le runtime Docker, mais le client Docker doit être installé séparément :

```bash
brew install docker
```

Vérifier :

```bash
docker --version
```

---

# 4. Installer et démarrer Colima

Installer Colima :

```bash
brew install colima
```

Démarrer Colima avec une adresse réseau :

```bash
colima start --network-address
```

Vérifier :

```bash
colima list
```

Vérifier également que Docker fonctionne :

```bash
docker info
```

---

# 5. Installer Kind

Installer Kind :

```bash
brew install kind
```

Vérifier :

```bash
kind version
```

---

# 6. Créer un cluster Kind multi-nœuds

Créer `kind-config.yaml` :

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kind-multi-node

nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

Créer le cluster :

```bash
kind create cluster --config=kind-config.yaml
```

Vérifier les nœuds :

```bash
kubectl get nodes -o wide
```

On doit obtenir un control-plane et deux workers.

Vérifier également le réseau Docker :

```bash
docker network ls
```

Puis :

```bash
docker network inspect kind
```

---

# 7. Comprendre le problème réseau sur macOS

Sous Linux, Docker s'exécute directement sur l'hôte. Les interfaces Docker sont donc directement accessibles.

Avec Colima sur macOS, Docker s'exécute **dans une VM Linux**.

Le chemin est donc :

```text
macOS
   │
   │ réseau Colima
   ▼
VM Linux Colima
   │
   │ réseau Docker
   ▼
Kind
   │
   ▼
Containers / Kubernetes
```

Le Mac ne peut donc pas simplement atteindre directement les adresses du réseau Docker Kind.

Il faut mettre en place :

1. une route sur le Mac vers le réseau Kind ;
2. une règle de forwarding dans la VM Colima.

---

# 8. Identifier les paramètres réseau

## 8.1 Adresse du Mac côté Colima

Selon la configuration Colima, le réseau utilisé peut différer du `bridge100` présenté dans le tutoriel original.

Dans notre environnement, le Mac est :

```text
192.168.64.1
```

On peut vérifier la passerelle depuis la VM :

```bash
colima ssh -- ip route
```

Dans notre cas :

```text
default via 192.168.64.1 dev col0
```

Cela permet d'identifier :

```bash
export colima_host_ip=192.168.64.1
```

---

## 8.2 Adresse de la VM Colima

Depuis la VM :

```bash
colima ssh -- ip -br addr
```

On obtient notamment :

```text
col0    UP    192.168.64.2/24
```

Donc :

```bash
export colima_vm_ip=192.168.64.2
```

---

## 8.3 Identifier le CIDR IPv4 du réseau Kind

Le tutoriel original utilise :

```bash
docker network inspect -f '{{.IPAM.Config}}' kind
```

Cette méthode n'est pas suffisamment robuste lorsque Docker retourne à la fois IPv6 et IPv4.

Dans notre environnement, la commande retourne notamment :

```text
fc00:f853:ccd:e793::/64
172.19.0.0/16
```

Nous voulons uniquement l'IPv4.

Utiliser :

```bash
export colima_kind_cidr=$(
  docker network inspect kind \
    -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' |
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/'
)
```

Vérifier :

```bash
echo "$colima_kind_cidr"
```

Résultat attendu dans notre environnement :

```text
172.19.0.0/16
```

---

## 8.4 Calculer le réseau court utilisé par la route macOS

Le tutoriel utilise une variable correspondant aux deux premiers octets du réseau.

Pour :

```text
172.19.0.0/16
```

on obtient :

```text
172.19
```

Commande :

```bash
export colima_kind_cidr_short=$(
  echo "$colima_kind_cidr" |
  cut -d '.' -f1-2
)
```

Vérifier :

```bash
echo "$colima_kind_cidr_short"
```

Résultat :

```text
172.19
```

---

# 9. Identifier l'interface réseau Colima

La VM possède une interface `col0`.

Vérifier :

```bash
colima ssh -- ip -br addr
```

Dans notre environnement :

```text
col0    UP    192.168.64.2/24
```

On peut donc définir :

```bash
export colima_vm_iface=col0
```

Vérifier :

```bash
echo "$colima_vm_iface"
```

---

# 10. Identifier le bridge Docker du réseau Kind

Le réseau Kind possède un bridge Linux dans la VM Colima.

Récupérer l'identifiant du réseau :

```bash
export colima_kind_network_id=$(docker network inspect kind -f '{{.Id}}')
```

Le bridge Docker correspondant utilise les 12 premiers caractères de cet identifiant.

```bash
export colima_kind_iface="br-${colima_kind_network_id:0:12}"
```

Vérifier :

```bash
echo "$colima_kind_iface"
```

Dans notre environnement :

```text
br-691e177f7cba
```

Vérifier que l'interface existe dans Colima :

```bash
colima ssh -- ip -br link
```

On doit retrouver :

```text
br-691e177f7cba    UP
```

Et :

```bash
colima ssh -- ip -br addr
```

doit montrer :

```text
br-691e177f7cba    UP    172.19.0.1/16
```

---

# 11. Résumé des paramètres réseau

À ce stade, notre environnement contient :

```bash
export colima_host_ip=192.168.64.1
export colima_vm_ip=192.168.64.2
export colima_vm_iface=col0
export colima_kind_cidr=172.19.0.0/16
export colima_kind_cidr_short=172.19
export colima_kind_iface=br-691e177f7cba
```

Vérifier :

```bash
echo "Host IP      : $colima_host_ip"
echo "VM IP        : $colima_vm_ip"
echo "VM interface : $colima_vm_iface"
echo "Kind CIDR    : $colima_kind_cidr"
echo "Kind network : $colima_kind_iface"
```

---

# 12. Ajouter la route sur macOS

Le Mac doit savoir que le réseau :

```text
172.19.0.0/16
```

est accessible via la VM Colima :

```text
192.168.64.2
```

Ajouter la route :

```bash
sudo route -nv add -net "$colima_kind_cidr_short" "$colima_vm_ip"
```

Vérifier :

```bash
netstat -rn | grep 172.19
```

On doit retrouver une route vers le réseau Kind via l'adresse de la VM Colima.

> **Attention :** la commande originale du tutoriel utilise `colima_kind_cidr_short`, par exemple `172.18`. Cette forme est adaptée à la commande `route` de macOS telle qu'utilisée dans le tutoriel.

---

# 13. Configurer le forwarding dans Colima

C'est l'étape qui nous a posé problème dans la version originale du tutoriel.

Le but de la règle est d'autoriser le trafic TCP :

```text
Mac
192.168.64.1
   │
   ▼
col0
   │
   ▼
br-691e177f7cba
   │
   ▼
172.19.0.0/16
```

La règle est :

```bash
sudo iptables -A FORWARD \
  -s 192.168.64.1 \
  -d 172.19.0.0/16 \
  -i col0 \
  -o br-691e177f7cba \
  -p tcp \
  -j ACCEPT
```

## Exécuter la règle dans Colima

Il est possible de construire la commande :

```bash
ssh_cmd="sudo iptables -A FORWARD -s $colima_host_ip -d $colima_kind_cidr -i $colima_vm_iface -o $colima_kind_iface -p tcp -j ACCEPT"
```

Afficher la commande :

```bash
echo "$ssh_cmd"
```

Cependant, avec la version de Colima utilisée dans ce lab, il ne faut pas exécuter :

```bash
colima ssh -- "$ssh_cmd"
```

car la chaîne entière peut être interprétée comme le nom d'un exécutable.

Utiliser plutôt :

```bash
colima ssh -- bash -c "$ssh_cmd"
```

Ou, plus simplement, exécuter directement :

```bash
colima ssh -- sudo iptables -A FORWARD \
  -s "$colima_host_ip" \
  -d "$colima_kind_cidr" \
  -i "$colima_vm_iface" \
  -o "$colima_kind_iface" \
  -p tcp \
  -j ACCEPT
```

---

# 14. Vérifier la règle iptables

Afficher la chaîne `FORWARD` :

```bash
colima ssh -- sudo iptables -L FORWARD -n -v
```

On doit retrouver une règle similaire à :

```text
ACCEPT tcp -- col0 br-691e177f7cba 192.168.64.1 172.19.0.0/16
```

Les compteurs :

```text
pkts bytes
```

restent à `0` tant qu'aucun trafic correspondant n'a traversé la règle.

## Éviter les doublons

Chaque exécution de `iptables -A` ajoute une nouvelle règle.

Avant de réexécuter la commande, vérifier :

```bash
colima ssh -- sudo iptables -L FORWARD -n -v
```

Pour supprimer une règle précise :

```bash
colima ssh -- sudo iptables -D FORWARD \
  -s "$colima_host_ip" \
  -d "$colima_kind_cidr" \
  -i "$colima_vm_iface" \
  -o "$colima_kind_iface" \
  -p tcp \
  -j ACCEPT
```

---

# 15. Vérifier le routage dans Colima

Vérifier les routes :

```bash
colima ssh -- ip route
```

On doit notamment avoir :

```text
172.19.0.0/16 dev br-691e177f7cba
192.168.64.0/24 dev col0
```

Dans notre environnement :

```text
172.19.0.0/16 dev br-691e177f7cba proto kernel scope link src 172.19.0.1
192.168.64.0/24 dev col0 proto kernel scope link src 192.168.64.2
```

Cela confirme que Colima sait déjà atteindre le réseau Docker Kind.

---

# 16. Installer MetalLB

MetalLB permet de fournir une implémentation de `LoadBalancer` pour un cluster Kubernetes local.

Installer MetalLB :

```bash
kubectl apply \
  -f https://raw.githubusercontent.com/metallb/metallb/v0.13.9/config/manifests/metallb-native.yaml
```

Attendre que les pods soient prêts :

```bash
kubectl wait \
  --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

Vérifier :

```bash
kubectl get pods -n metallb-system
```

> Le manifeste `v0.13.9` provient du tutoriel d'origine. Pour un nouveau lab, il est recommandé de vérifier la version de MetalLB utilisée et d'adapter le manifeste si nécessaire.

---

# 17. Configurer le pool d'adresses MetalLB

MetalLB doit disposer d'une plage d'adresses IP qu'il peut attribuer aux services `LoadBalancer`.

Notre réseau Kind est :

```text
172.19.0.0/16
```

Nous pouvons réserver, par exemple :

```text
172.19.255.200 - 172.19.255.250
```

Créer :

```text
metallb-conf.yaml
```

avec :

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

Appliquer :

```bash
kubectl apply -f metallb-conf.yaml
```

Vérifier :

```bash
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

---

# 18. Tester avec un service LoadBalancer

Créer `test-service.yaml` :

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: foo-app
  labels:
    app: http-echo
spec:
  containers:
    - name: foo-app
      image: hashicorp/http-echo:0.2.3
      args:
        - "-text=foo"

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
      image: hashicorp/http-echo:0.2.3
      args:
        - "-text=bar"

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
```

Appliquer :

```bash
kubectl apply -f test-service.yaml
```

Vérifier les pods :

```bash
kubectl get pods -o wide
```

Vérifier le service :

```bash
kubectl get svc foo-bar-service
```

---

# 19. Récupérer l'adresse IP attribuée par MetalLB

Exécuter :

```bash
LB_IP=$(kubectl get svc/foo-bar-service \
  -o=jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

Afficher :

```bash
echo "$LB_IP"
```

Une adresse dans le pool configuré devrait apparaître, par exemple :

```text
172.19.255.200
```

---

# 20. Tester depuis le Mac

Depuis le Mac :

```bash
curl "$LB_IP:5678"
```

On doit obtenir :

```text
foo
```

ou :

```text
bar
```

Répéter plusieurs fois :

```bash
for _ in {1..10}; do
  curl "$LB_IP:5678"
  echo
done
```

Les réponses doivent alterner entre `foo` et `bar`.

Cela permet de vérifier que le service Kubernetes répartit le trafic entre les deux pods.

---

# 21. Accéder à un NodePort (`IP_node:NodePort`) depuis le Mac

## Rappel : l'IP externe est sur le service, pas sur les nodes

L'`EXTERNAL-IP` allouée par MetalLB apparaît sur le **service** (`kubectl get svc`), jamais dans la colonne `EXTERNAL-IP` de `kubectl get nodes -o wide`. Cette colonne est renseignée par le contrôleur cloud (AWS/GCP/Azure) ; avec Kind/MetalLB elle reste `<none>` en permanence. Ne pas s'y fier pour cet accès.

## Principe

Un service `NodePort` (ex. `nodePort: 30080`) est écouté par **chaque node** sur `IP_node:30080`. Depuis le navigateur du Mac, trois ajustements sont nécessaires.

## 1. Route macOS (une seule fois)

```bash
sudo route -n add -net 172.19.0.0/16 192.168.64.2
```

(Cette route est nécessaire — et suffisante — pour le LoadBalancer aussi.)

## 2. Forward entrant Mac → réseau Kind

```bash
colima ssh -- sudo iptables -I DOCKER-USER 1 -i col0 -s 192.168.64.0/24 -o br-691e177f7cba -d 172.19.0.0/16 -p tcp -j ACCEPT
```

## 3. Forward retour node → Mac

```bash
colima ssh -- sudo iptables -I DOCKER-USER 2 -i br-691e177f7cba -o col0 -s 172.19.0.0/16 -d 192.168.64.0/24 -p tcp -j ACCEPT
```

> La policy `FORWARD` de la VM est `DROP` : sans ces deux règles, le SYN du Mac arrive sur `col0` mais n'est jamais transmis au node, et la réponse n'est jamais renvoyée.

## ⚠️ Le piège : les règles de durcissement du table `raw`

La VM possède des règles dans le **table `raw` (PREROUTING)** qui DROP tout trafic destiné aux IP des nodes dès qu'il n'arrive pas par le bridge Kind :

```text
iptables -t raw -L PREROUTING -n -v
DROP  tcp dpt:61035  !lo                → 127.0.0.1       # protège le tunnel API kubectl
DROP  --   !br-691e177f7cba             → 172.19.0.2      # protection des nodes
DROP  --   !br-691e177f7cba             → 172.19.0.3
DROP  --   !br-691e177f7cba             → 172.19.0.4
```

Le `raw` court-circuite `FORWARD` : même avec les règles `DOCKER-USER` posées, le paquet est jeté avant. C'est pourquoi :

- le **LoadBalancer** (`172.19.255.x`) répond sans règle supplémentaire (l'IP MetalLB n'est pas ciblée par ces DROP) ;
- le **NodePort** sur `IP_node:30080` est silencieux tant qu'on n'a pas d'exception.

Ajouter une exception au `raw` pour le NodePort utilisé :

```bash
colima ssh -- sudo iptables -t raw -I PREROUTING 1 -i col0 -s 192.168.64.0/24 -d 172.19.0.0/16 -p tcp --dport 30080 -j ACCEPT
```

(La règle est volontairement limitée au port NodePort pour préserver la protection des nodes.)

## Vérification

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://172.19.0.4:30080/   # → 200
```

Navigateur : `http://172.19.0.4:30080` — ou n'importe quel node (`172.19.0.2`, `172.19.0.3`, `172.19.0.4`). Le trafic est ensuite réparti par kube-proxy vers les pods du service.

> Si le réseau Kind est recréé, l'identifiant du bridge (`br-691e177f7cba`) change : toutes les règles ci-dessus sont à réécrire avec le nouveau `colima_kind_iface` (voir § 25).

---

# 22. Vérifier les compteurs iptables

Après les appels `curl` :

```bash
colima ssh -- sudo iptables -L FORWARD -n -v
```

La règle :

```text
ACCEPT tcp -- col0 br-691e177f7cba 192.168.64.1 172.19.0.0/16
```

doit maintenant avoir des compteurs `pkts` et `bytes` supérieurs à zéro.

Par exemple :

```text
12  720  ACCEPT  tcp  --  col0  br-691e177f7cba  192.168.64.1  172.19.0.0/16
```

Cela confirme que le trafic du Mac vers le réseau Kind traverse bien la règle de forwarding.

---

# 23. Vérifications utiles

## Vérifier les nœuds

```bash
kubectl get nodes -o wide
```

## Vérifier les pods

```bash
kubectl get pods -A -o wide
```

## Vérifier les services

```bash
kubectl get svc -A
```

## Vérifier MetalLB

```bash
kubectl get pods -n metallb-system
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

## Vérifier le réseau Docker Kind

```bash
docker network inspect kind
```

## Vérifier les interfaces Colima

```bash
colima ssh -- ip -br addr
```

## Vérifier les routes Colima

```bash
colima ssh -- ip route
```

## Vérifier le forwarding

```bash
colima ssh -- sudo iptables -L FORWARD -n -v
```

---

# 24. Dépannage

## `docker network inspect kind` retourne IPv6 et IPv4

C'est normal si le réseau Docker possède les deux familles d'adresses.

Ne pas utiliser :

```bash
docker network inspect kind -f '{{.IPAM.Config}}'
```

pour extraire directement le CIDR.

Utiliser :

```bash
docker network inspect kind \
  -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}'
```

puis filtrer l'IPv4 :

```bash
docker network inspect kind \
  -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' |
grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/'
```

---

## `{{.Subnet}}` provoque une erreur

Cette commande est incorrecte :

```bash
docker network inspect kind -f '{{.Id}} {{.Subnet}}'
```

`Subnet` se trouve dans `IPAM.Config`.

Utiliser :

```bash
docker network inspect kind \
  -f '{{.Id}} {{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

---

## `{{contains}}` n'existe pas

Docker utilise une version de Go templates qui ne fournit pas nécessairement la fonction `contains`.

Éviter donc :

```bash
{{if not (contains .Subnet ":")}}
```

et effectuer le filtrage côté shell avec `grep`.

---

## `colima_kind_iface` est vide

Identifier le bridge avec :

```bash
docker network inspect kind -f '{{.Id}}'
```

Puis :

```bash
colima ssh -- ip -br link
```

Le bridge devrait avoir la forme :

```text
br-<12 premiers caractères de l'ID>
```

Exemple :

```text
br-691e177f7cba
```

---

## `colima ssh -- "$ssh_cmd"` retourne `No such file or directory`

Avec cette syntaxe :

```bash
colima ssh -- "$ssh_cmd"
```

Colima peut considérer toute la chaîne comme le nom d'un programme.

Utiliser :

```bash
colima ssh -- bash -c "$ssh_cmd"
```

ou directement :

```bash
colima ssh -- sudo iptables ...
```

---

# 25. Recréer le cluster

Si le cluster doit être recréé :

```bash
kind delete cluster --name kind-multi-node
```

Puis :

```bash
kind create cluster --config=kind-config.yaml
```

> Le réseau Docker peut recevoir un nouvel identifiant de bridge. Il faut donc redéterminer `colima_kind_cidr` et `colima_kind_iface` après la recréation.

Redéterminer :

```bash
export colima_kind_cidr=$(
  docker network inspect kind \
    -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' |
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/'
)

export colima_kind_network_id=$(docker network inspect kind -f '{{.Id}}')

export colima_kind_iface="br-${colima_kind_network_id:0:12}"
```

Puis vérifier :

```bash
echo "$colima_kind_cidr"
echo "$colima_kind_iface"
```

Enfin, réappliquer la route macOS et la règle `iptables`.

---

# 26. Résultat attendu

À la fin du lab, nous avons :

```text
                         macOS
                    192.168.64.1
                          │
                          │ route
                          ▼
                 ┌─────────────────┐
                 │   Colima VM     │
                 │ 192.168.64.2    │
                 │                 │
                 │     col0        │
                 │       │         │
                 │       ▼         │
                 │ br-691e177f7cba │
                 │  172.19.0.1     │
                 └───────┬─────────┘
                         │
                         │ 172.19.0.0/16
                         ▼
                  ┌──────────────┐
                  │ Kind Cluster │
                  │              │
                  │ control-plane│
                  │ worker       │
                  │ worker       │
                  └──────┬───────┘
                         │
                         ▼
                      MetalLB
                         │
                         ▼
                 LoadBalancer IP
                   172.19.255.x
                         │
                         ▼
                 Kubernetes Service
                         │
                    ┌────┴────┐
                    ▼         ▼
                  foo       bar
```

Le résultat final est un cluster Kubernetes local multi-nœuds qui permet de tester des ressources `LoadBalancer` avec une architecture plus proche de celle rencontrée dans un environnement cloud.

---

## Référence

Ce lab est une adaptation du tutoriel OpenCredo *Building the best Kubernetes test cluster on MacOS*, qui décrit l'utilisation conjointe de Colima, Kind et MetalLB pour construire un cluster Kubernetes local multi-nœuds avec support des `LoadBalancer`. fileciteturn0file0L26-L33
