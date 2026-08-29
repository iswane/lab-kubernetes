# Replcaset

```²bash

➜ kubectl apply -f replicaset-fortune.yaml
replicaset.apps/fortune created

➜ kubectl get po -w                       
NAME            READY   STATUS    RESTARTS   AGE
fortune-47qwb   2/2     Running   0          5s
                                                                                                                                                                                                               ➜  4_replicatset-daemonset git:(main) ✗ k get pods -owide 
NAME            READY   STATUS    RESTARTS   AGE   IP           NODE                 NOMINATED NODE   READINESS GATES
fortune-47qwb   2/2     Running   0          29s   10.244.2.6   multi-node-worker2   <none>           <none>

➜ kubectl delete pod fortune-47qwb               
pod "fortune-47qwb" deleted from lab-aug-2026 namespace

➜ kubectl get pod                  
NAME            READY   STATUS    RESTARTS   AGE
fortune-x6hlr   2/2     Running   0          41s

➜ kubectl delete pod fortune-x6hlr             
pod "fortune-x6hlr" deleted from lab-aug-2026 namespace

➜ kubectl get pods -owide         
NAME            READY   STATUS    RESTARTS   AGE   IP           NODE                 NOMINATED NODE   READINESS GATES
fortune-5kcg6   2/2     Running   0          57s   10.244.2.7   multi-node-worker2   <none>           <none>

➜ kubectl scale --replicas=3 replicaset fortune
replicaset.apps/fortune scaled

➜ kubectl get pods -owide                      
NAME            READY   STATUS    RESTARTS   AGE     IP           NODE                 NOMINATED NODE   READINESS GATES
fortune-5kcg6   2/2     Running   0          2m27s   10.244.2.7   multi-node-worker2   <none>           <none>
fortune-5llbn   2/2     Running   0          74s     10.244.1.9   multi-node-worker    <none>           <none>
fortune-tbz44   2/2     Running   0          74s     10.244.2.8   multi-node-worker2   <none>           <none>


➜ kubectl get rs                                
NAME      DESIRED   CURRENT   READY   AGE
fortune   2         2         2       11m

➜ kubectl delete rs fortune          
replicaset.apps "fortune" deleted from lab-aug-2026 namespace


➜ kubectl get ds                  
NAME      DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
fortune   2         2         2       2            2           <none>          43s
    
➜ kubectl delete ds fortune       
daemonset.apps "fortune" deleted from lab-aug-2026 namespace

```