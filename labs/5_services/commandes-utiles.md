# Install ingress

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

# Créer un certficat TLS

Créez une paire de certificats clef publique / clef privée comme suit :

```bash
openssl genrsa -out izwane.dev-tls.key 2048 

openssl req -new -x509 -key izwane.dev-tls.key -out izwane.dev-tls.cert -days 30 -subj /CN=izwane.dev 
```

Créer un Secret depuis ces 2 fichiers pour ensuite les utiliser dans votre ressource
Ingress :

```bash
kubectl create secret tls izwane.dev-tls-secret --cert=izwane.dev-tls.cert --key=izwane.dev-tls.key
```
