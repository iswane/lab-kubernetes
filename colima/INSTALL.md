# Reproduire en français le tutoriel « Building the best Kubernetes test cluster on macOS »

Ce document reprend le tutoriel original en français, en ajoutant les détails pratiques que l’auteur laisse implicites : où exécuter chaque commande, pourquoi certaines variables sont calculées sur macOS et non dans Colima, comment corriger le cas où Docker renvoie d’abord un sous-réseau IPv6, et pourquoi `iptables` doit être installé dans la VM Colima plutôt que sur le Mac.[1][2][3][4]

## Objectif du montage

L’objectif est d’obtenir sur macOS un cluster Kubernetes local qui ressemble davantage à un cluster cloud managé qu’un simple environnement mono-nœud. Le montage combine Colima pour fournir une VM Linux légère avec Docker, Kind pour créer un cluster Kubernetes multi-nœuds dans Docker, et MetalLB pour simuler des services `LoadBalancer` hors cloud.[1][2][5]

Cette approche répond à deux limites fréquentes du développement local : l’impossibilité de tester correctement les comportements multi-nœuds et l’absence native de support utilisable pour les services `LoadBalancer`. Dans un cloud, ces objets s’appuient sur l’infrastructure du fournisseur ; en local, il faut donc recréer une partie de cette logique.[1][5][6]

## Ce que fait chaque composant

| Composant | Rôle | Pourquoi il est utilisé ici |
|---|---|---|
| Colima | Lance une VM Linux légère sur macOS | Docker ne tourne pas nativement sur macOS comme sur Linux ; Colima fournit donc l’hôte Linux nécessaire.[4] |
| Docker CLI | Permet d’interagir avec le moteur Docker exposé par Colima | Avec Colima, le client Docker doit être installé séparément.[1] |
| Kind | Crée un cluster Kubernetes dans des conteneurs Docker | Permet de définir plusieurs nœuds, notamment un control plane et plusieurs workers.[1][2] |
| MetalLB | Fournit des IP externes à des services `LoadBalancer` | Remplace localement le rôle habituellement joué par AWS, GCP ou Azure pour ce type de service.[1][5] |
| kubectl | Pilote le cluster Kubernetes | Sert à installer MetalLB, appliquer les manifests et tester les services.[1] |

## Prérequis réels

L’article suppose un Mac récent, sans Docker Desktop installé, avec Homebrew et `kubectl` déjà présents. Cette hypothèse est importante parce que Docker Desktop embarque son propre moteur et ses propres mécanismes réseau, alors que Colima sépare le client Docker, la VM Linux et le réseau Docker interne.[1][4]

À installer côté macOS :

```bash
brew install docker colima kind kubectl
```

Vérification rapide :

```bash
docker --version
colima version
kind version
kubectl version --client
```

## Comprendre où s’exécutent les commandes

C’est le point le plus souvent implicite dans le tutoriel original. Les commandes `export` sont exécutées dans le terminal **macOS**, pas dans la VM Colima, parce qu’elles servent à construire des variables à partir d’informations visibles depuis le Mac, comme `ifconfig`, `docker network inspect`, `colima list` ou `route`.[1][4][7]

En revanche, la règle `iptables` doit être exécutée **dans la VM Colima**, car `iptables` est un outil Linux qui agit sur la pile réseau Linux hébergeant Docker et le réseau de Kind. macOS n’utilise pas `iptables` comme mécanisme natif de filtrage réseau ; il utilise principalement PF (`pfctl`).[5][8][9][10]

La séparation correcte est donc :

- sur macOS : calcul des variables, inspection Docker, ajout de la route macOS ;
- dans Colima : exécution de la règle `iptables` ;
- via `kubectl` depuis macOS : gestion du cluster Kubernetes.

## Étape 1 — Installer Docker CLI

Avec Docker Desktop, le client Docker était fourni automatiquement. Avec Colima, il faut l’installer séparément :

```bash
brew install docker
```

L’important à comprendre est que cette commande n’installe pas le moteur Docker sur macOS. Elle installe seulement le client, qui parlera ensuite au moteur Docker tournant dans la VM Colima.[1][4]

## Étape 2 — Installer et démarrer Colima

Installe Colima :

```bash
brew install colima
```

Démarre Colima :

```bash
colima start --network-address
```

L’option `--network-address` est essentielle dans ce tutoriel, car elle expose une adresse réseau de la VM Colima et rend possible le routage du Mac vers le réseau Docker/Kind derrière cette VM. Sans cette option, l’accès aux adresses exposées par MetalLB devient beaucoup plus difficile, voire impossible avec cette méthode.[1][6][4]

Vérifie ensuite :

```bash
colima list
docker info
```

## Étape 3 — Installer Kind

Installe Kind :

```bash
brew install kind
```

Kind crée un cluster Kubernetes à l’intérieur de Docker, avec des conteneurs spécialisés capables d’héberger les rôles Kubernetes. C’est ce qui permet de simuler plusieurs nœuds sans lancer plusieurs machines virtuelles complètes.[1][2]

## Étape 4 — Créer un cluster multi-nœuds

Crée un fichier `kind-config.yaml` :

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kind-multi-node
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

Crée ensuite le cluster :

```bash
kind create cluster --config=kind-config.yaml
```

Vérifie les nœuds :

```bash
kubectl get nodes -o wide
```

L’intérêt de cette topologie est de pouvoir tester la répartition de pods, certains comportements de scheduling, les redémarrages progressifs, ainsi que les cas où plusieurs réplicas doivent vivre sur des nœuds distincts. Le tutoriel insiste sur ce point, car un cluster mono-nœud masque souvent des problèmes qui n’apparaissent qu’en environnement distribué.[1]

## Étape 5 — Comprendre le problème réseau sur macOS

Sur Linux, Docker s’exécute directement sur l’hôte, ce qui rend les réseaux de conteneurs plus accessibles. Sur macOS, Docker s’exécute dans une VM Linux ; ici, cette VM est fournie par Colima. Cela crée une couche supplémentaire entre ton Mac et le réseau Docker où Kind crée ses nœuds.[1][6][4]

Le trafic doit donc traverser plusieurs niveaux :

```text
macOS -> VM Colima -> réseau Docker kind -> nœuds Kind -> pods/services
```

Le tutoriel original ajoute donc :

1. une route sur macOS pour envoyer le trafic vers la VM Colima ;
2. une règle de forwarding dans la VM pour laisser passer le trafic vers le réseau Docker `kind`.[1][5][6]

## Étape 6 — Récupérer les variables réseau sur macOS

Toutes les commandes suivantes sont à lancer **sur macOS**.

### Adresse du pont réseau côté Mac

```bash
export colima_host_ip=$(ifconfig bridge100 | awk '/inet / {print $2; exit}')
echo "$colima_host_ip"
```

Cette adresse correspond généralement à l’interface du pont créé pour joindre la VM Colima. Une valeur typique est `192.168.64.1` ou `192.168.106.1`, selon la version et la configuration de Colima.[1]

### Adresse IP de la VM Colima

```bash
export colima_vm_ip=$(colima list | awk '/docker/ {print $8; exit}')
echo "$colima_vm_ip"
```

Cette variable représente l’adresse de la VM Linux dans laquelle Docker tourne réellement. Une valeur typique est `192.168.64.2` ou `192.168.106.2`.[1]

### Réseau Kind : attention au piège IPv6

Le tutoriel original suppose que `docker network inspect` renverra d’abord un sous-réseau IPv4. Sur certaines machines, Docker renvoie aussi un sous-réseau IPv6, par exemple `fc00:f853:ccd:e793::/64`, et celui-ci peut apparaître avant l’IPv4. Kind supporte IPv4, IPv6 et dual-stack ; mais cette procédure de routage locale et la configuration MetalLB utilisée ici reposent sur l’IPv4.[2][3]

La commande robuste est donc :

```bash
export colima_kind_cidr=$(
  docker network inspect kind \
    -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' |
  awk '$0 !~ /:/ && $0 ~ /^[0-9]+\./ { print; exit }'
)

echo "$colima_kind_cidr"
```

Résultat attendu :

```text
172.20.0.0/16
```

Puis :

```bash
export colima_kind_cidr_short=$(echo "$colima_kind_cidr" | cut -d'.' -f1-2)
echo "$colima_kind_cidr_short"
```

Résultat attendu :

```text
172.20
```

### Interface réseau de la VM Colima

```bash
export colima_vm_iface=$(
  colima ssh -- ip -br address |
  awk -v ip="$colima_vm_ip" '$0 ~ ip { print $1; exit }'
)

echo "$colima_vm_iface"
```

En pratique, la valeur est souvent `col0`.[1]

### Interface bridge du réseau Kind

L’article propose une commande basée sur `ip -br address show to ...`, mais dans la pratique il peut être plus simple d’inspecter d’abord toutes les interfaces :

```bash
colima ssh -- ip -br address
```

Repère ensuite l’interface de type `br-...` attachée au réseau `172.20.0.0/16`, puis exporte-la manuellement :

```bash
export colima_kind_iface="br-xxxxxxxxxxxx"
echo "$colima_kind_iface"
```

Ce point n’est pas assez détaillé dans l’article d’origine : si `colima_kind_iface` est vide, la commande `iptables` produira une règle invalide avec `-o  -p tcp`, et échouera ensuite dans Colima.[1]

## Étape 7 — Vérifier les variables avant d’aller plus loin

Avant d’ajouter la route et la règle de forwarding, affiche toutes les variables :

```bash
printf '%s\n' \
  "colima_host_ip=$colima_host_ip" \
  "colima_vm_ip=$colima_vm_ip" \
  "colima_kind_cidr=$colima_kind_cidr" \
  "colima_kind_cidr_short=$colima_kind_cidr_short" \
  "colima_vm_iface=$colima_vm_iface" \
  "colima_kind_iface=$colima_kind_iface"
```

Exemple cohérent :

```text
colima_host_ip=192.168.64.1
colima_vm_ip=192.168.64.2
colima_kind_cidr=172.20.0.0/16
colima_kind_cidr_short=172.20
colima_vm_iface=col0
colima_kind_iface=br-1a2b3c4d5e6f
```

S’il reste une valeur IPv6 dans `colima_kind_cidr`, il faut corriger cela avant de continuer. Si `colima_kind_iface` est vide, il faut d’abord retrouver le bridge Docker côté Colima.[1][3]

## Étape 8 — Ajouter la route sur macOS

Toujours sur macOS :

```bash
sudo route -nv add -net "$colima_kind_cidr_short" "$colima_vm_ip"
```

Si le réseau Kind est `172.20.0.0/16` et la VM `192.168.64.2`, cela revient à :

```bash
sudo route -nv add -net 172.20 192.168.64.2
```

Cette route dit à macOS : « pour joindre le réseau `172.20.x.x`, passe par l’IP de la VM Colima ». C’est indispensable pour que le Mac puisse joindre les IP qu’attribuera ensuite MetalLB aux services `LoadBalancer`.[1][6]

## Étape 9 — Installer `iptables` dans Colima

C’est un point non explicité dans l’article : selon l’image Linux utilisée par Colima, la commande `iptables` peut ne pas être préinstallée. Colima s’appuie aujourd’hui largement sur une VM Ubuntu légère ; dans ce cas, il faut installer le paquet manquant dans la VM, pas sur macOS.[11][12][4]

Installe-le ainsi :

```bash
colima ssh -- sh -c "sudo apt-get update && sudo apt-get install -y iptables"
```

Vérifie :

```bash
colima ssh -- sudo iptables --version
```

Installer `iptables` via Homebrew sur le Mac n’aide pas pour cette procédure, car la règle de forwarding doit agir sur la pile réseau Linux de la VM Colima. macOS utilise d’autres mécanismes réseau natifs.[8][9][10][13]

## Étape 10 — Créer et exécuter la commande `iptables`

La chaîne est préparée sur macOS, car les variables y sont définies :

```bash
ssh_cmd="sudo iptables -A FORWARD \
-s $colima_host_ip \
-d $colima_kind_cidr \
-i $colima_vm_iface \
-o $colima_kind_iface \
-p tcp \
-j ACCEPT"

echo "$ssh_cmd"
```

Exemple correct :

```text
sudo iptables -A FORWARD -s 192.168.64.1 -d 172.20.0.0/16 -i col0 -o br-1a2b3c4d5e6f -p tcp -j ACCEPT
```

Puis la commande est exécutée **dans Colima** :

```bash
colima ssh -- "$ssh_cmd"
```

Ce détail est crucial : les `export` se font sur le Mac, mais la commande finale passe dans la VM. L’article le mentionne brièvement, car Colima n’hérite pas automatiquement des variables d’environnement du Mac.[1][4]

Vérifie la règle :

```bash
colima ssh -- sudo iptables -L FORWARD -n -v
```

## Étape 11 — Installer MetalLB

Installe la version utilisée par l’article :

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.9/config/manifests/metallb-native.yaml
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

MetalLB joue ici le rôle d’un fournisseur d’adresses externes pour les services `LoadBalancer`. Dans un cloud, cette logique serait prise en charge par l’intégration du cluster avec l’infrastructure du fournisseur ; ici, MetalLB l’implémente localement.[1][5]

## Étape 12 — Configurer le pool d’adresses MetalLB

Choisis une plage dans le réseau IPv4 de Kind, en général vers la fin du sous-réseau. Si le réseau Kind vaut `172.20.0.0/16`, une plage acceptable est `172.20.255.200-172.20.255.250`.[1]

Crée `metallb-conf.yaml` :

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: example
  namespace: metallb-system
spec:
  addresses:
    - 172.20.255.200-172.20.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: metallb-system
```

Applique-le :

```bash
kubectl apply -f metallb-conf.yaml
```

Deux précisions utiles :

- la plage doit appartenir au réseau IPv4 `kind`, pas au réseau IPv6 ;
- elle ne doit pas entrer en conflit avec des IP déjà utilisées par les conteneurs Docker du réseau `kind`.[1][3]

Tu peux vérifier les IP occupées :

```bash
docker network inspect kind \
  -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'
```

## Étape 13 — Déployer le service de test

Crée `test-service.yaml` :

```yaml
kind: Pod
apiVersion: v1
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
kind: Pod
apiVersion: v1
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
kind: Service
apiVersion: v1
metadata:
  name: foo-bar-service
spec:
  type: LoadBalancer
  selector:
    app: http-echo
  ports:
    - port: 5678
```

Applique-le :

```bash
kubectl apply -f test-service.yaml
```

Récupère l’IP attribuée :

```bash
LB_IP=$(kubectl get svc/foo-bar-service -o=jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "$LB_IP"
```

Cette IP doit venir du pool MetalLB, par exemple `172.20.255.200`.[1][5]

## Étape 14 — Tester la répartition

Teste le service :

```bash
for _ in {1..10}; do curl ${LB_IP}:5678; done
```

Tu dois voir alternativement des réponses `foo` et `bar`. Cela confirme deux choses :

1. MetalLB attribue correctement une IP externe au service ;
2. le service `LoadBalancer` répartit bien le trafic entre les deux pods sélectionnés.[1]

Tu peux également vérifier les pods et endpoints :

```bash
kubectl get pods -o wide
kubectl get endpoints foo-bar-service
```

## Problèmes fréquents et corrections

### `docker network inspect` renvoie d’abord de l’IPv6

Si `colima_kind_cidr` vaut quelque chose comme `fc00:.../64`, il faut filtrer explicitement l’IPv4. Kind supporte l’IPv6, mais la procédure réseau décrite ici est pensée pour une route IPv4 sur macOS, une règle `iptables` IPv4 dans Colima et un pool MetalLB IPv4.[2][3]

### `sudo: iptables: command not found`

Cela signifie que le binaire manque dans la VM Colima. Installe-le dans Colima avec `apt-get` ; l’installer sur macOS via Homebrew ne remplace pas ce besoin.[11][12][14][13]

### `colima_kind_iface` vide

Cela arrive si la commande d’identification automatique ne trouve pas l’interface bridge du réseau Kind. Dans ce cas, inspecte `colima ssh -- ip -br address` puis renseigne manuellement l’interface `br-...` correspondante.[1]

### `No such file or directory` lors de `colima ssh -- "$ssh_cmd"`

Cette erreur apparaît souvent lorsque la variable contient une mauvaise combinaison de valeurs, par exemple un CIDR IPv6 et une interface vide. Il faut alors reconstruire les variables avant de reformer `ssh_cmd`.[1][3]

### `brew install iptables` sur macOS

Cette installation peut exister via Homebrew, mais elle ne remplace pas la configuration requise dans Colima. `iptables` est un outil Linux ; le tutoriel a besoin d’une règle appliquée dans la VM Linux qui héberge Docker et le réseau Kind.[8][9][13]

## Séquence complète recommandée

```bash
brew install docker colima kind kubectl
colima start --network-address

cat > kind-config.yaml <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kind-multi-node
nodes:
  - role: control-plane
  - role: worker
  - role: worker
YAML

kind create cluster --config=kind-config.yaml

export colima_host_ip=$(ifconfig bridge100 | awk '/inet / {print $2; exit}')
export colima_vm_ip=$(colima list | awk '/docker/ {print $8; exit}')
export colima_kind_cidr=$(
  docker network inspect kind \
    -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' |
  awk '$0 !~ /:/ && $0 ~ /^[0-9]+\./ { print; exit }'
)
export colima_kind_cidr_short=$(echo "$colima_kind_cidr" | cut -d'.' -f1-2)
export colima_vm_iface=$(
  colima ssh -- ip -br address |
  awk -v ip="$colima_vm_ip" '$0 ~ ip { print $1; exit }'
)

colima ssh -- ip -br address
# Définir ensuite manuellement colima_kind_iface selon la sortie
# export colima_kind_iface="br-xxxxxxxxxxxx"

sudo route -nv add -net "$colima_kind_cidr_short" "$colima_vm_ip"
colima ssh -- sh -c "sudo apt-get update && sudo apt-get install -y iptables"

ssh_cmd="sudo iptables -A FORWARD \
-s $colima_host_ip \
-d $colima_kind_cidr \
-i $colima_vm_iface \
-o $colima_kind_iface \
-p tcp \
-j ACCEPT"

colima ssh -- "$ssh_cmd"

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.9/config/manifests/metallb-native.yaml
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

## Nettoyage

Supprimer le service de test :

```bash
kubectl delete -f test-service.yaml
```

Supprimer le cluster Kind :

```bash
kind delete cluster --name kind-multi-node
```

Arrêter Colima :

```bash
colima stop
```

Supprimer complètement l’environnement Colima :

```bash
colima delete
```

## Ce que ce tutoriel apporte de plus que l’original

Le tutoriel original décrit bien l’architecture générale, mais laisse plusieurs points pratiques implicites : le lieu exact d’exécution des commandes, la différence entre macOS et la VM Colima, le cas où Docker retourne d’abord un sous-réseau IPv6, la nécessité d’installer `iptables` dans Colima, et la manière de vérifier qu’une interface `br-...` a bien été trouvée.[1][5][4]

Avec ces précisions, la procédure devient plus robuste et plus simple à diagnostiquer en cas d’erreur. C’est particulièrement utile sur des machines récentes où les sorties réseau diffèrent légèrement de celles présentées dans l’article d’origine.[1][2][4]