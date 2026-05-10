# lxcfs-admission-webhook

[![Go](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/go.yml/badge.svg)](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/go.yml)
[![Publish images](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/docker-publish.yml)
[![License](https://img.shields.io/github/license/idoyo7/lxcfs-admission-webhook)](LICENSE)

**한국어** · [English](README.md)

> Kubernetes Pod에 [LXCFS](https://linuxcontainers.org/lxcfs/introduction/) 기반의 `/proc`, `/sys` 가상 파일을 자동으로 마운트해, 컨테이너 안의 런타임이 호스트 전체가 아니라 cgroup 기준의 CPU·메모리 값을 보도록 돕습니다.

`lxcfs-admission-webhook`은 Kubernetes `MutatingAdmissionWebhook`과 LXCFS DaemonSet으로 구성됩니다. namespace에 라벨 하나만 붙이면, 이후 생성되는 Pod에 필요한 LXCFS 마운트가 자동으로 주입됩니다.

이 저장소는 [`ymping/lxcfs-admission-webhook`](https://github.com/ymping/lxcfs-admission-webhook)의 유지보수 fork입니다. LXCFS 6.x, 최신 Kubernetes 라이브러리, cert-manager 기반 인증서 관리, GHCR 이미지, OCI Helm chart 배포 흐름에 맞춰 정리했습니다.

---

## 왜 필요한가

많은 도구와 런타임은 사용할 수 있는 CPU나 메모리를 판단할 때 `/proc/cpuinfo`, `/proc/meminfo`, `/proc/stat` 같은 파일을 읽습니다. 하지만 컨테이너 안의 이 파일들은 Pod의 cgroup limit이 아니라 노드의 호스트 값을 그대로 보여주는 경우가 있습니다.

그 결과 힙 크기, 워커 수, 스레드 풀, 메트릭이 실제 Pod limit보다 과하게 잡히거나, 예상치 못한 OOMKill로 이어질 수 있습니다. LXCFS는 이런 파일들을 컨테이너 관점의 값으로 가상화하고, 이 webhook은 그 마운트를 Pod마다 수동으로 넣는 일을 자동화합니다.

특히 다음과 같은 워크로드에서 유용합니다.

- **JVM**: `Runtime.availableProcessors()`, GC worker 수, 메모리 percentage 옵션에 영향을 받는 서비스.
- **Node.js**: `os.cpus()` 또는 cluster worker 수를 기준으로 동작하는 서비스.
- **Go**: `runtime.NumCPU()`와 `GOMAXPROCS` 동작에 의존하는 애플리케이션.
- **Python / Ruby**: 표준 CPU count helper를 사용하는 워크로드.
- `nproc`, `free`, `top` 같은 운영·진단용 CLI 도구.

---

## 주요 기능

- **Namespace opt-in**: `lxcfs-admission-webhook=enabled` 라벨이 붙은 namespace의 Pod만 mutation합니다.
- **Pod 단위 opt-out**: `mutating.lxcfs-admission-webhook.io/enable: "false"` annotation으로 특정 Pod를 제외할 수 있습니다.
- **안전한 패치**: 기존 `lxcfs` volume이나 동일 mount path가 있으면 덮어쓰지 않고 `conflict`로 표시합니다.
- **결과 annotation**: 처리 결과를 `mutated`, `skip`, `conflict` 중 하나로 Pod에 기록합니다.
- **cert-manager 연동**: webhook serving certificate와 CA bundle 주입을 cert-manager에 맡깁니다.
- **다양한 설치 방식**: OCI Helm chart, Argo CD 예제, 가벼운 `install.sh` 설치 방식을 제공합니다.
- **GHCR 배포**: webhook 이미지, LXCFS 이미지, Helm chart를 GHCR 기반으로 배포합니다.

---

## 동작 방식

```text
┌──────────────────────┐       AdmissionReview        ┌──────────────────────────┐
│ Kubernetes API server │ ───────────────────────────▶ │ lxcfs-admission-webhook  │
│                      │ ◀──────── JSON Patch ─────── │ Deployment :8443         │
└──────────┬───────────┘                              └───────────┬──────────────┘
           │                                                      │
           │ patched Pod spec                                     │ TLS certs via
           ▼                                                      │ cert-manager
┌──────────────────────┐                              ┌───────────▼──────────────┐
│ Application Pod       │ read-only bind mounts        │ LXCFS DaemonSet          │
│ /proc/* and /sys/*    │ ◀─────────────────────────── │ /var/lib/lxc/lxcfs       │
└──────────────────────┘                              └──────────────────────────┘
```

Pod `CREATE` 시점에 webhook은 `/var/lib/lxc/` hostPath volume을 추가하고, 아래 LXCFS 기반 파일들을 read-only로 마운트합니다.

| 경로 | 용도 |
|---|---|
| `/proc/cpuinfo` | 런타임이 보는 CPU topology |
| `/proc/meminfo` | memory limit을 반영한 값 |
| `/proc/stat` | CPU/statistics view |
| `/proc/uptime` | 컨테이너 관점의 uptime |
| `/proc/loadavg` | load average view |
| `/proc/diskstats` | disk statistics view |
| `/proc/swaps` | swap information view |
| `/sys/devices/system/cpu/online` | online CPU set |
| `/var/lib/lxc/` | `HostToContainer` propagation으로 전달되는 LXCFS source |

코드상 `kube-system`, `kube-public` namespace는 건너뛰며, 기본 webhook failure policy는 `Ignore`입니다.

---

## 빠른 시작

### 사전 요구사항

- `admissionregistration.k8s.io/v1`을 지원하는 Kubernetes 클러스터.
- 클러스터에 설치된 [cert-manager](https://cert-manager.io/).
- LXCFS/FUSE를 실행할 수 있는 Linux 노드.
- 모든 설치 방식에 필요한 `kubectl`.
- OCI chart 설치에 필요한 Helm 3.8+.
- `deploy/install.sh` 사용 시 `gettext`의 `envsubst`.

cert-manager가 없다면 먼저 설치합니다.

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=120s
```

### Helm으로 설치

```sh
helm install lxcfs-admission-webhook \
  oci://ghcr.io/idoyo7/charts/lxcfs-admission-webhook \
  --version 0.2.1 \
  --namespace lxcfs \
  --create-namespace
```

설정은 `--set` 또는 values 파일로 조정할 수 있습니다. 가능한 값은 [`charts/lxcfs-admission-webhook/values.yaml`](charts/lxcfs-admission-webhook/values.yaml)을 참고하세요.

### Argo CD로 설치

[`examples/argocd`](examples/argocd)에 있는 예제를 사용할 수 있습니다.

- [`application-oci.yaml`](examples/argocd/application-oci.yaml): GHCR의 OCI chart를 사용합니다.
- [`application-git.yaml`](examples/argocd/application-git.yaml): 이 저장소의 chart 경로를 직접 사용합니다.

GitOps 구성, sync option, CA bundle drift 처리 방식은 [`examples/argocd/README.md`](examples/argocd/README.md)를 참고하세요.

### Helm 없이 설치

```sh
git clone https://github.com/idoyo7/lxcfs-admission-webhook.git
cd lxcfs-admission-webhook/deploy
./install.sh
```

자주 쓰는 override 값은 다음과 같습니다.

| Flag / env | 기본값 |
|---|---|
| `--namespace` | `lxcfs` |
| `--deployment` | `lxcfs-admission-webhook` |
| `--service` | `lxcfs-admission-webhook` |
| `--secret` | `lxcfs-admission-webhook` |
| `--daemonset` | `lxcfs-ds` |
| `--mutating` | `lxcfs-admission-webhook` |
| `--wh-image` / `WH_IMAGE` | `ghcr.io/idoyo7/lxcfs-admission-webhook:latest` |
| `--lxcfs-image` / `LXCFS_IMAGE` | `ghcr.io/idoyo7/lxcfs:6.0.1-r1` |

---

## 사용 방법

대상 namespace에 라벨을 추가합니다.

```sh
kubectl label namespace your-namespace lxcfs-admission-webhook=enabled
```

라벨을 붙인 뒤 새로 생성되는 Pod만 mutation됩니다. 이미 실행 중인 워크로드에 적용하려면 재시작하거나 다시 배포해야 합니다.

특정 Pod만 제외하려면 다음 annotation을 추가합니다.

```yaml
metadata:
  annotations:
    mutating.lxcfs-admission-webhook.io/enable: "false"
```

webhook 처리 결과는 다음 명령으로 확인할 수 있습니다.

```sh
kubectl get pod <pod> \
  -o jsonpath='{.metadata.annotations.mutating\.lxcfs-admission-webhook\.io/status}'
```

가능한 값은 다음과 같습니다.

| 상태 | 의미 |
|---|---|
| `mutated` | LXCFS volume과 mount가 주입되었습니다. |
| `skip` | 의도적으로 mutation을 건너뛰었습니다. |
| `conflict` | 기존 volume 또는 mount와 충돌해 주입하지 않았습니다. |

---

## 적용 확인

opt-in된 namespace에서 limit이 있는 Pod를 실행하고 `/proc` 값을 확인합니다.

```sh
kubectl label namespace default lxcfs-admission-webhook=enabled --overwrite

kubectl run lxcfs-check --rm -it --restart=Never \
  --image=alpine:3.21 \
  --limits=cpu=1,memory=1Gi \
  -- sh -c 'echo "nproc: $(nproc)"; head -3 /proc/meminfo; grep -c ^processor /proc/cpuinfo'
```

CPU 1개, 메모리 1Gi로 제한한 Pod라면 `nproc`은 `1`, `MemTotal`은 대략 `1048576 kB`에 가깝게 보여야 합니다.

> 참고: LXCFS가 모든 커널 counter를 가상화하는 것은 아닙니다. cgroup mode와 커널 동작에 따라 일부 사용량 기반 도구는 여전히 호스트에서 파생된 값을 보여줄 수 있습니다.

---

## 설정 요약

Helm chart의 주요 운영 설정은 [`values.yaml`](charts/lxcfs-admission-webhook/values.yaml)에 정의되어 있습니다.

| 값 | 기본값 |
|---|---|
| `webhook.image.repository` | `ghcr.io/idoyo7/lxcfs-admission-webhook` |
| `webhook.replicas` | `2` |
| `webhook.port` | `8443` |
| `lxcfs.image.repository` | `ghcr.io/idoyo7/lxcfs` |
| `lxcfs.image.tag` | `6.0.1-r1` |
| `lxcfs.hostPath` | `/var/lib/lxc` |
| `mutatingWebhook.namespaceSelector.matchLabels.lxcfs-admission-webhook` | `enabled` |
| `mutatingWebhook.timeoutSeconds` | `5` |
| `mutatingWebhook.reinvocationPolicy` | `Never` |

Raw manifest installer는 [`deploy/certificate.tpl.yaml`](deploy/certificate.tpl.yaml)의 cert-manager 리소스를 사용합니다. Helm chart는 [`charts/lxcfs-admission-webhook/values.yaml`](charts/lxcfs-admission-webhook/values.yaml)에 별도 인증서 기본값을 가지므로, 클러스터마다 한 가지 설치 방식을 정해 일관되게 관리하는 것을 권장합니다.

---

## 개발

```sh
make build          # ./build/lxcfs-admission-webhook 빌드
make test           # 유닛 테스트 실행
make test-coverage  # build/coverage.out 생성

make build-image-wh    DOCKER_REGISTRY=ghcr.io/<you>
make build-image-lxcfs DOCKER_REGISTRY=ghcr.io/<you>
```

저장소 구조는 다음과 같습니다.

```text
cmd/                         webhook server와 mutation 로직
deploy/                      raw Kubernetes template과 설치 스크립트
charts/lxcfs-admission-webhook/ Helm chart
examples/argocd/             GitOps 예제
lxcfs-image/                 LXCFS container image와 entrypoint
.github/workflows/           CI, 이미지 배포, chart 배포 workflow
```

webhook은 다음 endpoint를 제공합니다.

- `GET /ping` → `pong`
- `POST /mutate` → Kubernetes `AdmissionReview` mutation endpoint

---

## 제거

설치한 방식에 맞춰 제거합니다.

```sh
# Helm
helm uninstall lxcfs-admission-webhook -n lxcfs

# Argo CD
kubectl delete application lxcfs-admission-webhook -n argocd

# install.sh
cd deploy && ./uninstall.sh
```

제거 시 webhook configuration, Deployment, Service, LXCFS DaemonSet, cert-manager 리소스, 소유한 Secret이 삭제됩니다. namespace 자체는 남겨 둡니다.

---

## Release artifacts

- Webhook image: `ghcr.io/idoyo7/lxcfs-admission-webhook`
- LXCFS image: `ghcr.io/idoyo7/lxcfs`
- Helm chart: `oci://ghcr.io/idoyo7/charts/lxcfs-admission-webhook`

CI는 Go 코드 빌드와 테스트를 수행하고, `main` 및 semantic version tag에서 이미지를 배포합니다. Chart workflow는 Helm chart를 배포하며, release 경로의 OCI artifact는 cosign으로 서명됩니다.

---

## License

Apache License 2.0. [`LICENSE`](LICENSE)를 참고하세요.

---

## Maintainer

idoyo7 — [idoyo7@gmail.com](mailto:idoyo7@gmail.com)

원본 프로젝트: [`ymping/lxcfs-admission-webhook`](https://github.com/ymping/lxcfs-admission-webhook)
