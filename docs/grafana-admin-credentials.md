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

Both values travel on **stdin**, not in arguments. Anything in argv is visible to `ps` inside the container for the life of the call and is recorded in the API server's audit log of the exec — neither of which a password should reach.

```bash
GRAFANA_PW=$(openssl rand -base64 24)
ROOT_TOKEN=$(kubectl get secret openbao-init -n openbao -o jsonpath='{.data.root_token}' | base64 -d)

# First line is the token, the rest is the password. `admin-password=-` is
# OpenBao's own convention for reading a value from stdin.
printf '%s\n%s' "$ROOT_TOKEN" "$GRAFANA_PW" | kubectl exec -i -n openbao openbao-0 -- sh -c '
  read -r BAO_TOKEN
  export BAO_TOKEN
  bao kv put secret/heimdall/grafana admin-user=admin admin-password=-
'
```

Check it round-trips — comparing rather than printing, so the value stays out of the terminal and its scrollback:

```bash
stored=$(printf '%s' "$ROOT_TOKEN" | kubectl exec -i -n openbao openbao-0 -- sh -c '
  read -r BAO_TOKEN
  export BAO_TOKEN
  bao kv get -field=admin-password secret/heimdall/grafana')

if [ "$stored" = "$GRAFANA_PW" ]; then
  echo "round-trip OK"
else
  echo "MISMATCH: OpenBao does not hold the value just written — stop here" >&2
  false
fi
```

`false` rather than only printing, so the check leaves a non-zero status. A validation step that reports failure and still exits `0` is one a copied script will run straight past.

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

printf '%s' "$GRAFANA_PW" | kubectl exec -i -n heimdall "$GRAFANA_POD" -c grafana -- \
  grafana-cli --homepath /usr/share/grafana admin reset-admin-password --password-from-stdin
```

`--password-from-stdin` rather than a positional argument, for the same reason as step 1 — a positional password is visible in the container's process list and in the exec audit record.

`--homepath` is required: without it the CLI cannot find the config and database and exits with an error rather than doing nothing, which is at least a loud failure.

On a **fresh** install this step is unnecessary — the admin user is created from the Secret. It is only needed when converting an existing instance, which is the case here.

## Step 5 — validate

Four checks, in order. The last one is the only one that proves the change took effect.

`$GRAFANA_PW_OLD` is the credential being replaced. On the **first** migration that is the chart default, `admin`. On a **rotation** it is the previously generated value, which step 1 of the rotation procedure captures before overwriting — see below. Check 4 is worthless against the wrong value, because a password that was never set is refused whether or not the reset worked.

Each check asserts rather than prints, so a failure leaves a non-zero status instead of a number someone has to notice.

```bash
GRAFANA_PW_OLD=${GRAFANA_PW_OLD:-admin}

expect() {  # expect <what> <got> <wanted>
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: got '$2', wanted '$3'" >&2
    false
  fi
}

code() {  # run curl inside the pod, echo the status code
  kubectl exec -i -n heimdall "$GRAFANA_POD" -c grafana -- \
    curl -s -o /dev/null -w '%{http_code}' "$@"
}

# 1. The Secret carries the value ESO fetched — compared, not printed
secret_pw=$(kubectl get secret grafana-admin-credentials -n heimdall \
  -o jsonpath='{.data.admin-password}' | base64 -d)
expect "secret matches OpenBao" "$([ "$secret_pw" = "$GRAFANA_PW" ] && echo yes || echo no)" yes

# 2. Grafana's own health endpoint is up
expect "health endpoint" "$(code http://localhost:3000/api/health)" 200

# 3. The NEW password authenticates.
#    `--config -` reads the credential from stdin, keeping it out of argv.
expect "new password accepted" \
  "$(printf 'user = "admin:%s"\n' "$GRAFANA_PW" | code --config - http://localhost:3000/api/org)" 200

# 4. The OLD password is refused
expect "old password rejected" \
  "$(printf 'user = "admin:%s"\n' "$GRAFANA_PW_OLD" | code --config - http://localhost:3000/api/org)" 401
```

Check 4 returning `200` means the reset did not take: the value is in the Secret and in the environment, but Grafana's database still holds the old credential. Re-run step 4 and confirm the CLI reported success rather than a config error.

Anonymous access is off by default, so an unauthenticated call to `/api/org` returning `401` is expected and is not a substitute for check 4 — that check must use the actual previous password.

## Rotation

Rotation is steps 1, 4 and 5 — write the new value to OpenBao, wait for ESO's refresh interval (or force it), then reset and validate. Steps 2 and 3 are one-time wiring.

**Capture the current password first.** Step 1 overwrites it in OpenBao, and once that has happened the old value is unrecoverable — which leaves check 4 with nothing real to test against:

```bash
GRAFANA_PW_OLD=$(kubectl get secret grafana-admin-credentials -n heimdall \
  -o jsonpath='{.data.admin-password}' | base64 -d)
```

Then run step 1 with a new `GRAFANA_PW`, force the refresh, and **wait for the Secret to actually carry the new value** before resetting Grafana. Resetting first means step 4 writes whatever the Secret still holds, which on a slow refresh is the old password:

```bash
kubectl annotate externalsecret grafana-admin-credentials -n heimdall \
  force-sync="$(date +%s)" --overwrite

# Poll until ESO has propagated the new value, with a deadline. A refresh can
# fail outright — a sealed OpenBao, a broken ClusterSecretStore — and an
# unbounded wait would hang instead of saying so.
synced=false
deadline=$((SECONDS + 120))
while [ "$SECONDS" -lt "$deadline" ]; do
  current=$(kubectl get secret grafana-admin-credentials -n heimdall \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
  if [ "$current" = "$GRAFANA_PW" ]; then synced=true; break; fi
  sleep 2
done

if [ "$synced" != true ]; then
  echo "ESO did not propagate within 120s — check: kubectl describe externalsecret grafana-admin-credentials -n heimdall" >&2
  false
fi
```

Now run step 4, then step 5 with both `GRAFANA_PW` and `GRAFANA_PW_OLD` set.

Remove the annotation afterwards if the ExternalSecret is managed in Git, so the live object does not drift from its manifest.

## Notes

- **The password is not the only door.** Grafana is exposed at `grafana.cmdbee.org` through a Traefik IngressRoute with no auth in front of it, so this credential is the entire access control for the dashboards. OIDC via Keycloak is the intended eventual answer and is tracked as Heimdall Phase 2 item 4.
- **Until the OpenBao hardening phase lands, values cross the cluster in plaintext** — the listener runs with TLS disabled and ESO reads over `http://`. That is an accepted staging posture, documented in nidavellir `docs/secrets-management.md` § "Security limitations", but it means this password is observable to anything with in-cluster network visibility during a refresh.
- **Anyone able to read Secrets in `openbao` can read the parked root token**, and therefore this value, regardless of how strong the password is.
