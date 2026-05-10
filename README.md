# lxcfs-admission-webhook

[![Go](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/go.yml/badge.svg)](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/go.yml)
[![Publish images](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/docker-publish.yml)
[![License](https://img.shields.io/github/license/idoyo7/lxcfs-admission-webhook)](LICENSE)

> Kubernetes Pod에 [LXCFS](https://linuxcontainers.org/lxcfs/introduction/) 가상 파일을 자동으로 bind-mount해, 컨테이너 안의 JVM / Node / Go / Python 런타임이 호스트 자원이 아닌 **cgroup limit 기준의 CPU·메모리 값**을 보게 만드는 MutatingAdmissionWebhook.

이 저장소는 [`ymping/lxcfs-admission-webhook`](https://github.com/ymping/lxcfs-admission-webhook)의 메인테넌스 fork이다. LXCFS 6.x / Go 1.24 / k8s 1.34 시대로 끌어올리고, 인증서 발급을 cert-manager에 맡기고, 이미지 배포를 GHCR로 단일화했다.

---

## 한눈에 보기 — 6하원칙

| | |
|--|--|
| **What** (무엇을) | Pod 생성 순간에 `MutatingAdmissionWebhook`이 LXCFS 가상 파일들을 Pod의 `/proc`/`/sys`에 자동으로 bind-mount하도록 spec을 패치한다. LXCFS 가상 파일은 같은 노드에서 도는 LXCFS DaemonSet이 만들어 준다. |
| **Why** (왜) | 컨테이너 안의 `/proc/cpuinfo`·`/proc/meminfo`는 cgroup limit과 무관하게 **호스트 값을 그대로** 노출한다. 그래서 JVM의 `-XX:+UseContainerSupport`, Node의 `os.cpus()`, Go의 `runtime.NumCPU()`, `nproc`, `top`, `free` 같은 도구들이 컨테이너 limit을 무시하고 잘못된 GC pool / thread pool / heap 크기를 결정한다. LXCFS가 이 문제를 해결하지만 모든 Pod에 일일이 마운트를 적어주기는 번거롭다 — 이 webhook이 그 자동화 레이어다. |
| **How** (어떻게) | namespace에 `lxcfs-admission-webhook=enabled` 라벨을 한 번만 붙이면, 그 namespace에 새로 생성되는 Pod에 webhook이 JSON Patch로 `volumes`·`volumeMounts`·`mutating.lxcfs-admission-webhook.io/status` annotation을 자동 추가한다. |
| **When** (언제) | Pod **CREATE** admission 이벤트 시점에만 동작한다. 이미 떠 있는 Pod는 건드리지 않으며, 워크로드를 다시 굴려야 적용된다. |
| **Where** (어디에) | Pod 컨테이너 내부의 다음 경로들이 LXCFS view로 가려진다: `/proc/cpuinfo`, `/proc/meminfo`, `/proc/stat`, `/proc/uptime`, `/proc/loadavg`, `/proc/diskstats`, `/proc/swaps`, `/sys/devices/system/cpu/online`. |
| **Who** (누가 쓰면 좋은가) | JVM·Node·Go·Python·Ruby 같이 cgroup을 직접 읽지 못하거나 잘 못 읽는 런타임을 컨테이너로 운영하는 팀. JVM 메모리 예측이 어긋나 OOMKilled가 잦은 클러스터, `nproc`/`os.cpus()`가 호스트 값을 반환해 thread pool이 과도하게 생성되는 워크로드. |

---

## 어떤 효과가 있는가 — Before / After

> 4 vCPU, 8 GB 메모리를 가진 노드에서 `cpu: "1", memory: "1Gi"`로 제한된 Pod 안에서 명령을 실행한 가상의 결과:

| 명령 | webhook 없이 | webhook 적용 |
|---|---|---|
| `nproc` | `4` (호스트의 vCPU 수) | `1` (cgroup CPU quota) |
| `cat /proc/cpuinfo \| grep -c processor` | `4` | `1` |
| `free -m` | `... 8000 ...` | `... 1024 ...` |
| `cat /proc/meminfo \| grep MemTotal` | 호스트 메모리 | cgroup memory limit |
| `uptime` 의 load average | 호스트 load | 컨테이너 view load |

런타임 단에서의 실효:

- **JVM**: `Runtime.availableProcessors()`가 cgroup CPU에 맞춰 줄어들어 `ForkJoinPool`·G1 GC 워커 스레드 수가 정상화된다. cgroup v1 환경에서 컨테이너 메모리 인식 정확도가 올라가 `-XX:MaxRAMPercentage`가 의도대로 동작한다.
- **Node.js**: `os.cpus()`가 limit 기준 코어 배열을 반환해 cluster 모듈로 worker를 띄울 때 호스트 코어만큼 fork되는 사고를 막는다.
- **Go**: `runtime.NumCPU()`가 줄어들어 `GOMAXPROCS` 자동 조정이 의도대로 작동한다 (별도의 `automaxprocs` 라이브러리 없이도).
- **Python · Ruby**: `multiprocessing.cpu_count()`, `Etc.nprocessors`가 정확한 CPU 수를 반환한다.

---

## 동작 구조

```
                      ┌─────────────────────────┐
                      │  LXCFS DaemonSet        │
                      │  (각 노드 1 Pod, host-  │
                      │   PID, privileged)      │
                      │  ─ FUSE mount @         │
                      │    /var/lib/lxc/lxcfs   │
                      └──────────┬──────────────┘
                                 │ hostPath, 노드의
                                 │ /var/lib/lxc 가 모든 Pod에서
                                 │ bind-mount 가능해진다
                                 ▼
   ┌──────────────┐  AdmissionReview ┌─────────────────────────┐
   │  kube-       │ ────────────────▶│  webhook Deployment     │
   │  apiserver   │                  │  (cert-manager 발급      │
   │              │ ◀── JSON Patch ──│   인증서로 mTLS)         │
   └──────────────┘                  └─────────────────────────┘
          │
          │ Pod spec에 다음이 추가됨:
          ▼
   spec.volumes:                      spec.containers[*].volumeMounts:
     - name: lxcfs                       - mountPath: /proc/cpuinfo
       hostPath:                           subPath: lxcfs/proc/cpuinfo
         path: /var/lib/lxc/                readOnly: true
         type: DirectoryOrCreate          (… meminfo, stat, uptime,
                                          loadavg, diskstats, swaps,
                                          sys/devices/system/cpu/online)
                                          - mountPath: /var/lib/lxc/
                                            readOnly: true
                                            mountPropagation: HostToContainer
   metadata.annotations:
     mutating.lxcfs-admission-webhook.io/status: mutated
```

webhook이 Pod 하나에 대해 내릴 수 있는 결정은 세 가지다.

| `status` annotation 값 | 의미 |
|---|---|
| `mutated` | LXCFS volume·volumeMount들이 정상적으로 추가됨 |
| `skip` | namespace selector나 Pod annotation 때문에 패치를 건너뜀 |
| `conflict` | 이미 같은 이름(`lxcfs`)의 volume이나 같은 mountPath를 쓰는 컨테이너가 있어 충돌 — 안전하게 건너뜀 |

> **알아둘 것**: LXCFS는 `/proc/cpustat`을 가상화하지 않는다. 그래서 cgroup v2 환경에서 일부 도구가 CPU "사용량" 일부를 호스트 기준으로 계산할 수 있다. CPU·메모리 limit "인식"은 정상이다.

---

## 원본(ymping) 대비 추가·개선 사항

총 14개 fork-only 커밋. 카테고리별로 정리하면:

### 기능적 개선

| 항목 | 원본 | 본 fork |
|---|---|---|
| **Annotation 패치 안전성** | `Path: "/metadata/annotations"`로 전체 annotation 맵을 통째로 add — 사용자가 미리 붙여놓은 annotation을 지울 위험 | `Path: "/metadata/annotations/<key>"`로 키별 add/replace, RFC 6901 JSON Pointer escape 처리 (`~` → `~0`, `/` → `~1`) |
| **인증서 발급** | `install.sh` 안에서 openssl로 self-signed CA·serving cert 생성, base64로 인코딩해 `caBundle`을 envsubst로 주입 — openssl 의존, 자동 갱신 없음 | cert-manager가 self-signed Issuer → 10년 CA → 1년 serving cert 체인을 발급. `cert-manager.io/inject-ca-from` 어노테이션으로 caBundle 자동 주입. **자동 갱신**(만료 30일 전) |
| **이미지 레지스트리** | docker.io에 webhook 이미지만 publish, lxcfs 이미지는 수동 빌드 | GHCR 매트릭스 워크플로우가 `ghcr.io/<owner>/lxcfs-admission-webhook`과 `ghcr.io/<owner>/lxcfs` 둘 다 자동 publish. cosign keyless 서명. `org.opencontainers.image.source` 라벨로 패키지 ↔ 레포 연결 |
| **이미지 참조** | deployment·daemonset YAML에 `montkim9/...` 하드코딩 | `${WH_IMAGE}` / `${LXCFS_IMAGE}` 변수화. install.sh `--wh-image` / `--lxcfs-image` 플래그로 즉석 override 가능 |
| **uninstall 견고성** | 리소스가 일부만 남아있을 때 에러로 멈춤 | 모든 `kubectl delete`에 `--ignore-not-found` 적용 — 부분 설치도 깨끗이 청소 |
| **install.sh 의존성** | `kubectl`, `openssl`, `envsubst`, `base64`, `mktemp` | `kubectl`, `envsubst`, cert-manager CRD (런타임)만 요구 — openssl 의존 제거 |

### 버전·툴체인 갱신

| 항목 | 원본 | 본 fork |
|---|---|---|
| LXCFS | 4.0.12-r0 (cgroup v1 only 검증) | **6.0.1-r1** (cgroup v2 호환) |
| Alpine 베이스 | 3.15 (2023-11 EOL) | **3.21** (지원 중) |
| 빌드 Go | 1.17 (2022-09 EOL) | **1.24** (지원 중) |
| go.mod `go` directive | 1.18 | **1.24.0** + `toolchain go1.24.5` |
| k8s.io 모듈 | v0.24.3 (k8s 1.24, 2022-05) | **v0.34.1** (k8s 1.34, 2025) |
| `io/ioutil` (deprecated) | 사용 중 | `io` 패키지로 교체 |
| GitHub Actions | checkout@v2 / setup-go@v3 / login@v2 / build-push@v3 / cosign@v2 | 모두 현재 메이저 (v5/v5/v3/v6/v3) |

### 배포 자동화

- main 브랜치 push 또는 `v*.*.*` 태그 시 두 이미지 GHCR에 자동 publish
- `docker/metadata-action`으로 branch / PR / semver / sha / `latest` 태그 자동 부여
- cosign keyless로 push 직후 디지털 서명 (Fulcio + Rekor 투명 로그)
- pull request에서는 빌드만 하고 push는 skip

---

## 사전 요구사항

- Kubernetes **v1.16+** (`admissionregistration.k8s.io/v1` 사용)
- [**cert-manager**](https://cert-manager.io/) v1.x — 서빙 인증서 발급·자동 갱신
- 노드에 **fuse3** (LXCFS 5.x+ 가 libfuse3에 링크)
- 운영자 머신에 `kubectl`, `envsubst` (gettext)

cert-manager 빠른 설치 (이미 있으면 건너뛰기):

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=120s
```

---

## 설치

```sh
git clone https://github.com/idoyo7/lxcfs-admission-webhook.git
cd lxcfs-admission-webhook/deploy
./install.sh
```

기본값과 override 가능한 플래그:

| 플래그 | 기본값 |
|---|---|
| `--namespace` | `lxcfs` |
| `--deployment` | `lxcfs-admission-webhook` |
| `--service` | `lxcfs-admission-webhook` |
| `--secret` | `lxcfs-admission-webhook` (cert-manager가 채움) |
| `--daemonset` | `lxcfs-ds` |
| `--mutating` | `lxcfs-admission-webhook` |
| `--wh-image` | `ghcr.io/idoyo7/lxcfs-admission-webhook:latest` |
| `--lxcfs-image` | `ghcr.io/idoyo7/lxcfs:6.0.1-r1` |

이미지는 환경변수로도 줄 수 있다:
```sh
WH_IMAGE=ghcr.io/idoyo7/lxcfs-admission-webhook:v0.2.0 ./install.sh
```

---

## 사용

대상 namespace에 라벨만 붙인다:

```sh
kubectl label namespace your-namespace lxcfs-admission-webhook=enabled
```

그 다음부터 그 namespace에 들어오는 Pod는 자동으로 mutation된다. 특정 Pod만 빼고 싶으면 Pod (또는 그 Deployment/StatefulSet template)에 다음을 추가:

```yaml
metadata:
  annotations:
    mutating.lxcfs-admission-webhook.io/enable: "false"
```

webhook은 자기 결과를 다시 Pod annotation에 적어 돌려준다 — `mutating.lxcfs-admission-webhook.io/status: mutated | skip | conflict`.

---

## 효과 검증

설치 후 라벨 붙인 namespace에 테스트 Pod 하나 띄워서 직접 확인:

```sh
kubectl label namespace default lxcfs-admission-webhook=enabled
kubectl run lxcfs-check --rm -it --restart=Never \
  --image=alpine:3.21 \
  --limits=cpu=1,memory=1Gi \
  -- sh -c 'echo "nproc:    $(nproc)"; echo; head -3 /proc/meminfo; echo; cat /proc/cpuinfo | grep -c ^processor'
```

`nproc`이 `1`, `MemTotal`이 약 `1048576 kB`로 나오면 정상 적용된 상태다. mutation이 적용됐는지는 다음으로도 확인:

```sh
kubectl get pod lxcfs-check -o jsonpath='{.metadata.annotations.mutating\.lxcfs-admission-webhook\.io/status}'
# → mutated
```

---

## 제거

```sh
cd deploy
./uninstall.sh
```

MutatingWebhookConfiguration · Deployment · Service · LXCFS DaemonSet · cert-manager Issuer/Certificate 쌍 · 그들이 만든 Secret까지 같이 지운다. namespace 자체는 남긴다.

---

## 소스에서 빌드

```sh
make build         # ./build/lxcfs-admission-webhook
make test          # 유닛 테스트 (테스트용 self-signed cert 자동 생성)

# 이미지 빌드 — DOCKER_REGISTRY는 어디든 override 가능
make build-image-wh    DOCKER_REGISTRY=ghcr.io/<you>
make build-image-lxcfs DOCKER_REGISTRY=ghcr.io/<you>
```

CI는 `main` 브랜치 push와 `v*.*.*` semver 태그에 대해 두 이미지를 GHCR에 자동 publish한다. 자세한 건 [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml).

---

## License

Apache License 2.0. [`LICENSE`](LICENSE) 참조.

## Maintainer

idoyo7 — [idoyo7@gmail.com](mailto:idoyo7@gmail.com)

원 프로젝트: [ymping/lxcfs-admission-webhook](https://github.com/ymping/lxcfs-admission-webhook)
