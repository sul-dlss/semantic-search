# Deploying to Kubernetes

This directory deploys the Rails app in `webapp/` to Kubernetes with a Helm chart, at <https://discovery-engine.stanford.edu>. ArgoCD watches `main` in this repository. Credentials stay in Vault and the operator's shell; none are committed.

## Deploying a new commit

Pushing to `main` builds an image but deploys nothing on its own. Each environment pins its image with `image.tag` in `values/<environment>.yaml`. To deploy:

1. Wait for the Docker workflow to pass on the commit. It publishes `ghcr.io/sul-dlss/semantic-search:<7-character commit SHA>`.
2. Pin that SHA, then commit and push to `main`:

   ```sh
   k8s/bin/deploy prod "$(git rev-parse --short=7 origin/main)"
   git commit -am "Deploy <sha> to prod" && git push
   ```

   `bin/deploy` changes only that environment's values file, and refuses a tag CI hasn't published.

The ArgoCD Application syncs automatically. ArgoCD polls the repository every few minutes; click **Refresh** on the app, or run `argocd app get semantic-search-prod --refresh`, to pick up the change sooner. Watch the rollout with `kubectl -n semantic-search-prod get pods -w`. Roll back by reverting the deploy commit.

Rolling updates start a new pod before stopping an old one. A stopping pod waits five seconds for the Service to stop sending it traffic, then has 60 seconds after SIGTERM to finish in-flight requests. A chat answer that's still streaming after that is cut off.

## What it deploys

The chart in `chart/` creates:

- A **Deployment** of the web server (two replicas): the image's default command, Thruster on port 8080 in front of Puma. The image's entrypoint runs `db:prepare` before starting the server. The startup, readiness and liveness probes all use Rails' built-in `GET /up`, which answers once the app has booted. It doesn't contact Solr or LiteLLM, so an outage of either shows the app's error page instead of taking every pod out of the Service.
- A **Service** (`ClusterIP` on port 80, plain HTTP).
- A **ListenerSet** and **HTTPRoute** that register the hostname with the cluster's shared Envoy Gateway. The F5 terminates TLS. The route allows 300 seconds per request, since chat answers stream over one response.
- When `oidc.enabled` is set, a second **HTTPRoute** and an Envoy **SecurityPolicy** for login (see [Login](#login)).
- A **ConfigMap** from the `env` values, and a **PodDisruptionBudget** that keeps all but one pod running during node drains.

The root filesystem is read-only. Each pod keeps its SQLite databases (search history, bookmarks, Solid Cache) in an `emptyDir` at `/rails/storage`. They start empty whenever a pod is replaced, and aren't shared between pods.

The chart doesn't create the Secrets; `bin/create-secrets` does.

## Login

The app shows restricted excerpts only to logged-in users. Login goes through the Envoy Gateway's OIDC filter, and only `/webauth/login` requires it:

1. An unauthenticated request for `/webauth/login` is redirected to the OIDC provider. After login, the provider redirects back to `/webauth/oidc/callback`, and Envoy returns the user to `/webauth/login`.
2. On that route only, Envoy sets `X-Oidc-Authenticated: true`, replacing anything the client sent. Rails records the login in its session and redirects to the page the user started from. The main route strips that header from every other request, and Rails ignores it everywhere except `/webauth/login`.
3. `/webauth/logout` clears the Rails session and redirects to `/webauth/oidc/logout`, which clears Envoy's OIDC cookies.

Until `oidc.enabled` is true, `/webauth/login` answers 503 and nobody can log in. To turn login on:

1. Register an OIDC client with the redirect URL `https://discovery-engine.stanford.edu/webauth/oidc/callback`.
2. Put the client secret in Vault as the `content` field of `puppet/application/semantic-search/prod/oidc_client_secret`, then run `k8s/bin/create-secrets prod`.
3. Set `oidc.issuer` and `oidc.clientID`, and `oidc.enabled: true`, in `values/prod.yaml`. Commit and push.

## Environments

An environment is a values file, `values/<environment>.yaml`, deployed by its ArgoCD Application, `argocd/semantic-search-<environment>.yaml`, into the namespace `semantic-search-<environment>`. Only `prod` exists today, in the stanford-prod cluster. `bin/deploy` and `bin/create-secrets` take the environment as their first argument.

To bring up an environment for the first time:

1. Ask Ops to create the `semantic-search-<env>` namespace, and an ArgoCD project named `semantic-search-<env>` that allows this repository as a source and that namespace as a destination. Ask which ArgoCD instance manages the cluster; if it doesn't run in that cluster, set `destination.server` in the Application to the cluster URL Ops gives.
2. Ask Ops to add a deploy key for this repository to ArgoCD, to point the hostname at the cluster in NetDB and on the F5, and to let the namespace reach Solr and the AI gateway.
3. Set `KUBE_CONTEXT_<ENV>` in `k8s/.env` to that cluster's context.
4. Run `k8s/bin/create-secrets <env>`.
5. Apply the Application with `kubectl apply -f k8s/argocd/semantic-search-<env>.yaml`, or ask Ops to.

## Requirements

- `kubectl` with access to the target namespace. The namespace must already exist.
- Vault access to `puppet/application/semantic-search/demo/secret_key_base` and `puppet/application/semantic-search/demo/litellm_key`, and to `puppet/application/semantic-search/<environment>/oidc_client_secret` once login is set up.

## Configure

Copy `k8s/.env.example` to `k8s/.env` and fill it in. `.env` is ignored by Git and sourced by the scripts, so treat it as trusted shell code. It sets the kubectl context for each environment (`KUBE_CONTEXT_PROD`; unset uses the current context).

Log into Vault and create the Secrets:

```sh
vault login -method oidc
k8s/bin/create-secrets prod
```

`bin/create-secrets <environment>` writes `SECRET_KEY_BASE` and `LITELLM_API_KEY` to the `semantic-search` Secret. If Vault has an OIDC client secret, it also writes that to the `semantic-search-oidc` Secret. To read other Vault paths for one run, set `VAULT_SECRET_KEY_BASE_PATH`, `VAULT_LITELLM_KEY_PATH` or `VAULT_OIDC_CLIENT_SECRET_PATH`. Run it again after rotating any of them, then restart the pods with the command it prints, because pods read Secrets only at startup.

### Adding a secret

1. Add it to Vault, as the `content` field.
2. Read it and add it to the `semantic-search` Secret in `bin/create-secrets`.
3. Add its name to the `secretKeyRef` list in `chart/templates/deployment.yaml`, and to the credentials that `semantic-search.checkValues` in `chart/templates/_helpers.tpl` refuses in `env`.

Non-secret settings go in `env` in `values/<environment>.yaml`.

## Checking a deployment

```sh
kubectl -n semantic-search-prod port-forward service/semantic-search 8080:80
curl -i http://localhost:8080/up
curl -i https://discovery-engine.stanford.edu/up
kubectl -n semantic-search-prod logs deploy/semantic-search -f
kubectl -n semantic-search-prod exec -it deploy/semantic-search -- bin/rails console
```
