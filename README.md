# Deploying to a local Kubernetes cluster

This application is a generated CESNET Invenio based repository. It uses
the published `helm-invenio` chart directly from its Helm repository — this
repository doesn't modify the chart, so there's no need to clone it locally.

To try on your repository, the following files are needed to be copied to your local repository:
- `helm/values-overrides.yaml`
- `Dockerfile`
- `run.sh` (newer version than the one you probably have)

Before building the image, run the `./run.sh upgrade` command to update the python dependencies.

These steps assume a fresh clone of this repository and a local Kubernetes
cluster (e.g. OrbStack, Docker Desktop, minikube, kind) that shares the same
context as your local `docker` CLI.

## 1. Get the code

```bash
git clone https://github.com/mesemus/sample-local-k8s-deployment.git
cd testrepo
```

## 2. Build the image

```bash
docker build -t testrepo:latest -t local/testrepo:latest .
```

The second tag is required — the chart always renders the image reference
as `<registry>/<repository>:<tag>`, and `values-overrides.yaml` (next step)
points it at `local/testrepo:latest`.

## 3. Add the chart's Helm repository

```bash
helm repo add helm-invenio https://inveniosoftware.github.io/helm-invenio/
helm repo update helm-invenio
```

No `helm dependency build` step here — a chart pulled from a Helm
repository already has its dependencies (postgresql/redis/rabbitmq/
opensearch) packaged in, unlike a raw chart directory.

## 4. Create values-overrides.yaml

```bash
cp helm/values-overrides.yaml.tmpl helm/values-overrides.yaml
```

`helm/values-overrides.yaml` (the real file, not the `.tmpl` — it's
gitignored, don't commit it) is ready to use as-is. Create a Secret with
your S3 endpoint and access/secret keys — the template already references
it (`s3-credentials`), so no values-overrides.yaml changes are needed:

```bash
kubectl create namespace invenio
kubectl create secret generic s3-credentials --namespace invenio \
  --from-literal=endpoint-url="<https://your-s3-endpoint>" \
  --from-literal=access-key="<your-s3-access-key>" \
  --from-literal=secret-key="<your-s3-secret-key>"
```

## 5. Set up HTTPS (ingress + TLS)

This repository requires HTTPS. The chart's `ingress.enabled` only creates an `Ingress` resource — it doesn't
install a controller or issue a certificate, so set both up here.

If you don't already have an ingress, install one as follows:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=90s
```

On OrbStack (and similar), its `LoadBalancer` Service is exposed directly on
your host's `localhost` — no port-forward needed. On clusters that don't
support `LoadBalancer` (e.g. vanilla kind/minikube), port-forward the
`ingress-nginx-controller` service instead.

Generate a self-signed cert for `localhost` and store it as the TLS secret
the chart expects:

```bash
mkdir -p /tmp/localhost-cert
openssl req -x509 -newkey rsa:2048 -keyout /tmp/localhost-cert/tls.key \
  -out /tmp/localhost-cert/tls.crt -days 365 -nodes -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

kubectl create secret tls localhost-tls --namespace invenio \
  --cert=/tmp/localhost-cert/tls.crt --key=/tmp/localhost-cert/tls.key
```

## 6. Install

**Don't name the release `invenio`.** Kubernetes auto-injects an env var for
every Service into every pod in the namespace — naming the release `invenio`
makes the OpenSearch service `invenio-opensearch`, and the injected
`INVENIO_OPENSEARCH_PORT=tcp://<ip>:9200` silently clobbers the identically
named var this repository expects to be a bare port number, breaking the
OpenSearch connection. Use anything else, e.g. `repo`:

```bash
helm install -f helm/values-overrides.yaml repo helm-invenio/invenio --version 0.14.0 --namespace invenio
```

If you don't use Helm regularly: the general shape of this command is
`helm install [flags] RELEASE_NAME CHART`, and here that's `-f
helm/values-overrides.yaml` (the values file) + `repo` (the release name —
this is what must not be `invenio`) + `helm-invenio/invenio` (the chart,
resolved from the Helm repository added in step 3, not a local path) +
`--version 0.14.0` (pin the exact chart version — this repository was tested
against this one) + `--namespace invenio`. The release name is unrelated to
the chart's own name (`invenio`) — you're free to pick anything for it.
Helm uses it as a prefix for every resource it creates (`repo-postgresql`,
`repo-opensearch`, `repo-invenio-web`, etc.).

## 7. Watch it come up

```bash
kubectl get pods --namespace invenio -w
```

First run takes a few minutes — Postgres/OpenSearch/RabbitMQ need to
initialize, then the web pod's startup probe needs to pass.

### Point file storage at S3

Once the web pods are up, run:

```bash
kubectl exec --namespace invenio deploy/repo-invenio-web -- \
  invenio files location create s3-location s3://<bucket> --default
```

Replace `<bucket>` with your bucket name.

## 8. Access it

```bash
kubectl get ingress --namespace invenio
```

Browse to **`https://localhost/`**. Your browser will warn about the
self-signed cert — that's expected; proceed past it (or import
`/tmp/localhost-cert/tls.crt` as trusted if you don't want the warning).

If your cluster doesn't expose the ingress controller's `LoadBalancer` on
`localhost` (only confirmed on OrbStack), port-forward it instead:

```bash
kubectl port-forward --namespace ingress-nginx svc/ingress-nginx-controller 8443:443
```

and browse to `https://localhost:8443/`.

## 9. Iterate

Rebuilding the image doesn't change its tag, so Kubernetes won't notice on
its own — force a rollout:

```bash
docker build -t testrepo:latest -t local/testrepo:latest .
kubectl rollout restart deployment --namespace invenio -l app.kubernetes.io/instance=repo
```

Better long-term: tag builds uniquely (e.g. `docker build -t testrepo:dev-$(date +%s)
-t local/testrepo:dev-$(date +%s) .`) and `helm upgrade` with the new tag
instead (`helm upgrade -f helm/values-overrides.yaml repo helm-invenio/invenio
--version 0.14.0 --namespace invenio`), to avoid stale-pod caching issues.
