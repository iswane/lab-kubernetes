brew install k3d


k3d version


k3d cluster create mycluster \
  --servers 1 \
  --agents 2 \
  -p "80:80@loadbalancer" \
  -p "443:443@loadbalancer"


kubectl get nodes


k3d cluster create mycluster \
  --servers 1 \
  --agents 2 \
  -p "80:80@loadbalancer" \
  -p "443:443@loadbalancer" \
  --k3s-server-arg "--disable=traefik"
