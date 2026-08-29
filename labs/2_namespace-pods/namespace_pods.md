### Namespaces
Un namespace Kubernetes (à ne pas confondre avec un namespace Linux) peut être vu comme un cluster virtuel. 
Il est notamment possible de lui associer des quotas (limite maximale de ressources utilisables), et des droits définis pour chaque utilisateur (ex : droit de création de certaines ressources, droits de lecture, etc…).
Un namespace peut donc être utilisé pour :
   - Séparer de manière logique des applications :
     - Cependant, sans configuration supplémentaire, un namespace ne permet pas de créer une réelle isolation des ressources. En effet, par défaut un pod/service d’un namespace A peut communiquer avec un pod/service d’un namespace B !
   - Répartir les ressources disponibles au sein du cluster
     - Par le biais de création de quotas
Les ressources Kubernetes se trouvant dans un namespace doivent avoir un nom unique.
Cependant, il est possible d’avoir des ressources avec le même nom dans deux namespaces différents.

```bash
$ kubectl run nginx --image=nginx
pod/nginx created

$ kubectl get pod nginx -o yaml
apiVersion: v1
kind: Pod
metadata:
annotations:
kubernetes.io/psp: eks.privileged
...

$ kubectl exec -it nginx -- /bin/bash
root@nginx:/# hostname
nginx
root@nginx:/#
``` |

