# ArgoCD examples

These manifests are **examples** — copy them into your own GitOps
repository (e.g. `infra-config.git/environments/prod/`) and adapt the
values. Do not apply them from inside this project repo: doing so would
collapse the GitOps separation between "code + chart sources" (this
repo) and "what is actually deployed where" (your config repo).

## Two patterns

| File | Source | When to use |
|---|---|---|
| [`application-oci.yaml`](application-oci.yaml) | `oci://ghcr.io/idoyo7/charts/lxcfs-admission-webhook` | **Production.** Pulls a versioned, cosign-signed chart artifact published by this project's CI. Chart bumps are explicit (you change `targetRevision` in your GitOps repo). |
| [`application-git.yaml`](application-git.yaml) | `https://github.com/idoyo7/lxcfs-admission-webhook.git`, `path: charts/lxcfs-admission-webhook` | **Test / preview.** Useful for trying unreleased chart changes by pointing `targetRevision` at a branch or commit. Avoid in production: a moving ref means ArgoCD's idea of "the chart" changes whenever this repo's `main` does. |

## Recommended flow

```
[idoyo7/lxcfs-admission-webhook] (this repo)
        │
        │ git push, chart-publish workflow
        ▼
[oci://ghcr.io/idoyo7/charts/lxcfs-admission-webhook:0.1.x]
        │
        │ ArgoCD pulls by OCI URL + version
        ▼
[<your-org>/infra-config] (your GitOps repo)
        │
        │ ArgoCD watches and reconciles
        ▼
[your cluster]
```

Bumping the chart version is then a **pull request in your GitOps
repo** that changes `targetRevision: 0.1.0` → `0.2.0`. No code in
`idoyo7/lxcfs-admission-webhook` needs to be touched to roll out a
deploy.

## Prerequisites in the target cluster

- ArgoCD v2.6+ (OCI Helm chart support is GA from v2.6 on)
- cert-manager v1.x — issues the webhook serving certificate
- Nodes with `fuse3` available (LXCFS 5.x+ links against libfuse3)

If your ArgoCD cannot reach `ghcr.io` anonymously yet, configure a
repository credential. The chart is published as a public OCI
artifact once `gh api -X PATCH /user/packages/container/charts%2Flxcfs-admission-webhook/visibility -f visibility=public`
has been run on the publishing account; before that, ArgoCD needs a
PAT with `read:packages`.

## Customizing values

Both example Applications inline a small `helm.values:` block. You
can:

1. Inline more values directly in the Application (simple cases).
2. Move them to a separate `values.yaml` in your GitOps repo and
   reference it with `valueFiles:` (when paired with a multi-source
   Application — ArgoCD v2.8+).
3. Build your own umbrella chart that lists this chart as a
   dependency.

For most users (1) is enough until the values block grows beyond ~30
lines.

## Sync options used

- `CreateNamespace=true` — ArgoCD creates the `lxcfs` namespace if
  missing. The chart resources are then namespaced into it.
- `ServerSideApply=true` — avoids client-side ownership conflicts
  with cert-manager rewriting the `caBundle` field on
  MutatingWebhookConfiguration.
- `ignoreDifferences` on `caBundle` — cert-manager populates that
  field at runtime; ArgoCD must not flag it as drift.

## Multi-cluster

For "deploy this to N clusters" you typically want an `ApplicationSet`
that templates the same Application across a cluster generator. That
is out of scope for these examples but the pattern is unchanged: one
ApplicationSet → N Applications, each pointing at the same OCI chart.
