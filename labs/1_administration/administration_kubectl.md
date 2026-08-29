##  [K8S] Atelier - Administration - Kubectl

### Utilisation de Kubectl
Kubectl est le client qui permet d’interagir avec votre cluster Kubernetes (par l’intermédiaire
de l’API Server).

- Pour débuter, vous pouvez afficher l’aide de kubectl grâce à la commande suivante :
```bash
$ kubectl -h
```
### 1.1 Informations sur le cluster
Vous retrouverez ci-dessous une série de commandes permettant d’afficher l’état du cluster Kubernetes :
```bash
$ kubectl cluster-info
#Affiche les adresses de l’API server et des services associés au cluster Kubernetes

$ kubectl cluster-info dump
# Affiche l’ensemble des logs liés au cluster. Utile lors du troubleshooting

$ kubectl config view
# Affiche le fichier de configuration utilisé pour s’authentifier avec le(s) serveur(s) API
```
### 1.2. Informations sur les nœuds
Vous retrouverez ci-dessous une série de commandes permettant lister les nodes composant votre cluster :
```bash
$ kubectl get nodes
# Affiche les nœuds qui appartiennent au cluster Kubernetes avec les
informations suivantes : leur état, leur rôle, leur âge et leur version

$ kubectl get nodes -o wide
# Affiche des informations supplémentaires sur les nœuds du cluster (version d’OS, version du kernel…)
```

Vous p ouvez également afficher des informations plus détaillées sur vos workers grâce à la commande suivante :
```bash
$ kubectl describe node <nom-du-worker>
# affiche l’état de la machine k8s-worker du cluster
```
Pour rappel, dans votre contexte, vous ne pouvez pas afficher les informations associées aux
masters, car ceux-ci sont entièrement managés par GKE.

### 1.3. Informations sur les services système
Lors de l’initialisation de notre cluster, certaines ressources indispensables à son fonctionnement ont été créées. Nous allons les explorer afin que vous puissiez vous familiariser avec l’interpréteur kubectl.
Après l’initialisation du cluster, 4 namespaces sont créés à savoir :
- default
- kube-public
- kube-system
- kube-node-lease


Ci-après, la commande permettant d’afficher ces namespaces :

```bash
$ kubectl get namespaces
# affiche tous les namespaces du cluster kubernetes
```

Certains services sont aussi déployés lors de l’initialisation afin de les afficher utiliser la commande suivante :
```bash
$ kubectl get service --all-namespaces
# affiche les services du namespaces kube-system
```

Certains pods sont aussi déployés lors de l’initialisation. Afin de les afficher, utilisez la commande suivante :
```bash
$ kubectl get pods --all-namespaces
```
L’option « --all-namespaces » permet d’afficher toutes les ressources déployées au sein du cluster Kubernetes.

Pour obtenir plus d’informations sur les pods, utilisez l’option suivante :
```bash
$ kubectl get pods --all-namespaces -o wide
```
Vous pouvez utiliser l’option « -n » qui permet de sélectionner un namespace particulier. Si
l’option n’est pas spécifiée, la commande s’exécutera pour le namespace « default ».
```bash
$ kubectl get pods -n kube-system -o wide
```
La commande suivante permet d’afficher les évènements survenus sur le cluster :
```bash
$ kubectl get events --sort-by=.metadata.creationTimestamp
```

### 1.4. Communication avec l’API Server
La commande kubectl cluster-info retourne des informations utiles concernant les différents
services Kubernetes déployés.

Vous pouvez notamment voir dans la capture d’écran ci-dessus que l’API Server écoute à
l’adresse https://XX.XXX.X.XX.
Cependant, il n’est pas possible d’effectuer une requête directement sur cette URL, car il s’agit
d’une connexion sécurisée HTTPS avec authentification.

Pour communiquer directement avec l’API Server il est possible d’utiliser un proxy grâce à la
commande kubectl proxy.
Cette commande démarre un proxy vers l’API Server en s’occupant de l’authentification. De
plus, il s’assure que l’on communique bien à l’API en vérifiant le certificat et sa signature à
chaque requête.
1) Dans une nouvelle fenêtre de ligne de commande, exécutez donc la commande
   suivante pour démarrer un le proxy :
# le & permet d’exécuter la commande en fond de tâche fermer le
terminal stoppera la commande
```bash
$ kubectl proxy &
Starting to serve on 127.0.0.1:8001
```

Note : Si vous travaillez avec kubectl sur Windows le symbole « & » n’est pas reconnu. Utilisez
la commande « start kubectl proxy »
2) Il est maintenant possible de dialoguer avec l’API Server depuis l’adresse du proxy. Effectuer une requête avec curl sur l’URL http://127.0.0.1:8001 :

Chaque ressource est catégorisée en fonction de son « apiversion ». Par exemple les pods,
services se trouveront dans la catégorie /api/v1.
L’« apiversion » est le champ que vous renseignerez lors de la création de nouvelles
ressources pour indiquer à l’API Server l’endroit où il doit trouver les informations dont il a
besoin.

3) Pour connaitre la version d’API utilisée, vous pouvez effectuer la requête suivante :
```bash   
$ curl http://localhost:8001/api/
```
4) Ensuite, vous pouvez obtenir la liste des pods déployés dans le namespaces kube-
   system de votre cluster, en utilisant cette commande :
```bash
$ curl localhost:8001/api/v1/namespaces/kube-system/pods
{
"kind": "PodList",
"apiVersion": "v1",
"metadata": {
"selfLink": "/api/v1/namespaces/kube-system/pods",
"resourceVersion": "12299"
},
"items": [
{
"metadata": {
"name": "etcd-k8s1",
"namespace": "kube-system"
...
```

5) Cette liste de pods correspond à la liste obtenue grâce à la commande suivante :
```bash
$ kubectl get -n kube-system pod
```

1.4. Découvrir les champs de configurations API
Lorsque vous souhaitez découvrir une ressource, vous pouvez utiliser la commande « kubectl
explain ».
1) Commencez par afficher l’aide, qui liste toutes les ressources qui sont supportées par
   l’API server :
```bash
   $ kubectl explain -h
```
2) Vous pouvez par exemple afficher tous les champs que l’on peut utiliser lors de la
   définition d’un pod dans un fichier yaml ou json :
   
```bash
$ kubectl explain pod
   DESCRIPTION:
   Pod is a collection of containers that can run on a host. This
   resource is
   created by clients and scheduled onto hosts.
   FIELDS:
   apiVersion <string>
   APIVersion defines the versioned schema of this representation
   of an
   object. Servers should convert recognized schemas to the latest
   internal
   value, and may reject unrecognized values. More info:
   https://git.k8s.io/community/c
...
```
Comme nous pouvons le voir, cette commande retourne la version API que nous devons
indiquer à l’API server lors de la création d’un pod (« VERSION: v1 »). Puis, une description de
la ressource est détaillée.
Enfin, nous retrouvons les champs évoqués tout à l’heure à savoir :
• Metadata
o Contient les métadonnées de la ressource (nom, namespace…)
• Spec
• Status
o Contient la description du contenu de la ressource
o Contient les informations courantes associées à la ressource (statut, IP…)
Cette structure décomposée en 3 sections est la structure type d’un objet API Kubernetes.
Dans la pratique, l’écriture des manifests est plus légère. Lors de la création de l’objet,
Kubernetes ajoute lui-même plusieurs informations complémentaires.
Ces champs sont suivis d’une description. À ce stade, les paramètres des différents champs ne sont pas encore indiqués. Pour cela, il faut utiliser la commande suivante :

```bash
$ kubectl explain pod.spec
KIND: Pod
VERSION: v1
RESOURCE: spec <Object>
DESCRIPTION:
Specification of the desired behavior of the pod. More info:
https://git.k8s.io/community/contributors/devel/api-
conventions.replicatset-daemonset.md#spec-and-status
...
```

Vous pouvez aller ainsi dans le détail des arguments :
```bash 
$ kubectl explain pod.spec.containers
$ kubectl explain pod.spec.containers.image
```
