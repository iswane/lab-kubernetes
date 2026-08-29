```bash
➜ kubectl label namespaces lab-aug-2026 form=k8s
# Permet d'ajouter le label form=k8s au namespace lab-aug-2026
➜ kubectl get namespaces --show-labels                
NAME                 STATUS   AGE     LABELS
default              Active   7d      kubernetes.io/metadata.name=default
kube-node-lease      Active   7d      kubernetes.io/metadata.name=kube-node-lease
kube-public          Active   7d      kubernetes.io/metadata.name=kube-public
kube-system          Active   7d      kubernetes.io/metadata.name=kube-system
lab-aug-2026         Active   5d18h   form=k8s,kubernetes.io/metadata.name=lab-aug-2026
local-path-storage   Active   7d      kubernetes.io/metadata.name=local-path-storage
metallb-system       Active   6d23h   kubernetes.io/metadata.name=metallb-system,pod-security.kubernetes.io/audit=privileged,pod-security.kubernetes.io/enforce=privileged,pod-security.kubernetes.io/warn=privileged

# L'option -L permte d'afficher sous forme de colonnes les labels app et release associés aux pods
➜ kubectl get pods -L app,release
NAME       READY   STATUS    RESTARTS   AGE     APP        RELEASE
nginx      1/1     Running   0          2m51s   frontend   beta
nginx-v2   1/1     Running   0          56s     frontend   stable


➜ kubectl get pods -l release=stable
NAME       READY   STATUS    RESTARTS   AGE
nginx-v2   1/1     Running   0          2m28s


➜ kubectl label node multi-node-worker disk=ssd
node/multi-node-worker labeled

➜ kubectl get nodes -L disk                       
NAME                       STATUS   ROLES           AGE   VERSION   DISK
multi-node-control-plane   Ready    control-plane   7d    v1.36.1   
multi-node-worker          Ready    worker          7d    v1.36.1   ssd
multi-node-worker2         Ready    worker          7d    v1.36.1   


➜ kubectl annotate pod pod-ssd iswane.dev/lab="k8s-training"
pod/pod-ssd annotated

➜ kubectl describe pod pod-ssd                              
Name:             pod-ssd
Namespace:        lab-aug-2026
Priority:         0
Service Account:  default
Node:             multi-node-worker/172.19.0.4
Start Time:       Sat, 29 Aug 2026 15:36:37 +0200
Labels:           app=backend
                  release=beta
Annotations:      iswane.dev/lab: k8s-training
Status:           Running
IP:               10.244.1.6
```

