# Grafana admin credentials — moving off the default and into OpenBao

Heimdall's Grafana currently ships with `adminPassword: admin` hardcoded in the composition, which means the login is `admin` / `admin` on every environment. This document is the procedure for replacing that with a generated password held in OpenBao and delivered by External Secrets Operator, plus the checks that prove the change actually took effect.

The delivery mechanism is the platform's standard one — OpenBao as the system of record, ESO copying values into ordinary Kubernetes Secrets. See nidavellir `docs/secrets-management.md` for the model, the `ClusterSecretStore` (`openbao-kv`), and the KV v2 path rules. This document only covers what is specific to Grafana.

## The trap that makes validation non-optional

**Grafana seeds the admin user from `GF_SECURITY_ADMIN_PASSWORD` only when that user is first created.** After that the credential lives in Grafana's own database, and changing the Helm value, the Secret, or the environment variable has no effect on a running instance — the pod restarts, reads the new value, sees an admin user already exists, and moves on. Nothing errors and nothing warns.

So a change that looks complete from the Kubernetes side can leave `admin` / `admin` working perfectly. Every step below therefore ends in a check, and the final check deliberately asserts that the **old** password is now *rejected* — the one test that cannot pass by accident.

## Prerequisites

OpenBao must be unsealed and the store Ready. A restarted OpenBao pod always comes back sealed:

```bash
kubectl get pods -n openbao                    # openbao-0 must be 1/1, not 0/1
kubectl get clustersecretstore openbao-kv      # READY must be True
```

If `openbao-0` is `0/1` or the store reports `InvalidProviderConfig`, unseal first — runbook in nidavellir `docs/secrets-management.md` § "The pod restarted and shows 0/1".

## Step 1 — generate a password and store it in OpenBao

Generate locally so the value never appears in a command that a shell history or a CI log would capture more widely than intended.

```bash
GRAFANA_PW=$(openssl rand -base64 24)
ROOT_TOKEN=$(kubectl get secret openbao-init -n openbao -o jsonpath='{.data.root_token}' | base64 -d)

kubectl exec -n openbao openbao-0 -- env BAO_TOKEN="$ROOT_TOKEN" \
  bao kv put secret/heimdall/grafana admin-user=admin admin-password="$GRAFANA_PW"
```

Check it round-trips:

```bash
kubectl exec -n openbao openbao-0 -- env BAO_TOKEN="$ROOT_TOKEN" \
  bao kv get -field=admin-password secret/heimdall/grafana
```

## Step 2 — materialize it as a Kubernetes Secret

Add an `ExternalSecret` in the `heimdall` namespace. Note the OpenBao path has no `data/` segment here — that infix applies to the API and to policy paths, not to the CLI or to ESO's `remoteRef`.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-admin-credentials
  namespace: heimdall
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao-kv
    kind: ClusterSecretStore
  target:
    name: grafana-admin-credentials
  data:
    - secretKey: admin-user
      remoteRef:
        key: secret/heimdall/grafana
        property: admin-user
    - secretKey: admin-password
      remoteRef:
        key: secret/heimdall/grafana
        property: admin-password
```

Check ESO delivered it:

```bash
kubectl get externalsecret grafana-admin-credentials -n heimdall   # STATUS SecretSynced, READY True
kubectl get secret grafana-admin-credentials -n heimdall -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

## Step 3 — point Grafana at the Secret

In `crossplane/composition.yaml`, replace the hardcoded `adminPassword` under the kube-prometheus-stack `grafana:` block:

```yaml
                grafana:
                  enabled: true
                  admin:
                    existingSecret: grafana-admin-credentials
                    userKey: admin-user
                    passwordKey: admin-password
```

`admin.existingSecret` and `adminPassword` are mutually exclusive — leaving both set means the chart renders the literal and the Secret is ignored, so delete the old line rather than commenting around it.

Check the pod actually consumes it:

```bash
kubectl rollout status deploy/heimdall-<xrsuffix>-kube-prometheus-grafana -n heimdall
kubectl get deploy -n heimdall -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].spec.template.spec.containers[?(@.name=="grafana")].env[?(@.name=="GF_SECURITY_ADMIN_PASSWORD")].valueFrom.secretKeyRef.name}'; echo
```

That must print `grafana-admin-credentials`. If it prints nothing, the chart is still rendering a literal value.

## Step 4 — apply the password to the existing admin user

Because of the trap above, steps 1–3 do not change the credential on an instance that already has an admin user. Reset it explicitly, reading the value from the Secret so there is one source of truth:

```bash
GRAFANA_POD=$(kubectl get pod -n heimdall -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
GRAFANA_PW=$(kubectl get secret grafana-admin-credentials -n heimdall -o jsonpath='{.data.admin-password}' | base64 -d)

kubectl exec -n heimdall "$GRAFANA_POD" -c grafana -- \
  grafana-cli --homepath /usr/share/grafana admin reset-admin-password "$GRAFANA_PW"
```

`--homepath` is required: without it the CLI cannot find the config and database and exits with an error rather than doing nothing, which is at least a loud failure.

On a **fresh** install this step is unnecessary — the admin user is created from the Secret. It is only needed when converting an existing instance, which is the case here.

## Step 5 — validate

Four checks, in order. The last one is the only one that proves the change took effect.

```bash
# 1. The Secret carries the value ESO fetched
kubectl get secret grafana-admin-credentials -n heimdall -o jsonpath='{.data.admin-password}' | base64 -d; echo

# 2. Grafana's own health endpoint is up
kubectl exec -n heimdall "$GRAFANA_POD" -c grafana -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/api/health

# 3. The NEW password authenticates -> expect 200
kubectl exec -n heimdall "$GRAFANA_POD" -c grafana -- \
  curl -s -o /dev/null -w '%{http_code}\n' -u "admin:$GRAFANA_PW" http://localhost:3000/api/org

# 4. The OLD password is refused -> expect 401
kubectl exec -n heimdall "$GRAFANA_POD" -c grafana -- \
  curl -s -o /dev/null -w '%{http_code}\n' -u 'admin:admin' http://localhost:3000/api/org
```

Check 4 returning `200` means the reset did not take: the value is in the Secret and in the environment, but Grafana's database still holds the old credential. Re-run step 4 and confirm the CLI reported success rather than a config error.

Anonymous access is off by default, so an unauthenticated call to `/api/org` returning `401` is expected and is not a substitute for check 4 — that check must use the literal old password.

## Rotation

Rotation is steps 1, 4 and 5 — write the new value to OpenBao, wait for ESO's refresh interval (or force it), then reset and validate. Steps 2 and 3 are one-time wiring.

```bash
kubectl annotate externalsecret grafana-admin-credentials -n heimdall \
  force-sync="$(date +%s)" --overwrite
```

Remove that annotation afterwards if the ExternalSecret is managed in Git, so the live object does not drift from its manifest.

## Notes

- **The password is not the only door.** Grafana is exposed at `grafana.cmdbee.org` through a Traefik IngressRoute with no auth in front of it, so this credential is the entire access control for the dashboards. OIDC via Keycloak is the intended eventual answer and is tracked as Heimdall Phase 2 item 4.
- **Until the OpenBao hardening phase lands, values cross the cluster in plaintext** — the listener runs with TLS disabled and ESO reads over `http://`. That is an accepted staging posture, documented in nidavellir `docs/secrets-management.md` § "Security limitations", but it means this password is observable to anything with in-cluster network visibility during a refresh.
- **Anyone able to read Secrets in `openbao` can read the parked root token**, and therefore this value, regardless of how strong the password is.
