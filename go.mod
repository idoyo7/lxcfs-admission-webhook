module github.com/ymping/lxcfs-admission-webhook

go 1.24.0

toolchain go1.24.5

replace k8s.io/api => k8s.io/api v0.34.1

replace k8s.io/apiextensions-apiserver => k8s.io/apiextensions-apiserver v0.34.1

replace k8s.io/apimachinery => k8s.io/apimachinery v0.34.6

replace k8s.io/apiserver => k8s.io/apiserver v0.34.1

replace k8s.io/cli-runtime => k8s.io/cli-runtime v0.34.1

replace k8s.io/client-go => k8s.io/client-go v0.34.1

replace k8s.io/cloud-provider => k8s.io/cloud-provider v0.34.1

replace k8s.io/cluster-bootstrap => k8s.io/cluster-bootstrap v0.34.1

replace k8s.io/code-generator => k8s.io/code-generator v0.34.1

replace k8s.io/component-base => k8s.io/component-base v0.34.1

replace k8s.io/component-helpers => k8s.io/component-helpers v0.34.1

replace k8s.io/controller-manager => k8s.io/controller-manager v0.34.1

replace k8s.io/cri-api => k8s.io/cri-api v0.34.6

replace k8s.io/csi-translation-lib => k8s.io/csi-translation-lib v0.34.1

replace k8s.io/kube-aggregator => k8s.io/kube-aggregator v0.34.1

replace k8s.io/kube-controller-manager => k8s.io/kube-controller-manager v0.34.1

replace k8s.io/kube-proxy => k8s.io/kube-proxy v0.34.1

replace k8s.io/kube-scheduler => k8s.io/kube-scheduler v0.34.1

replace k8s.io/kubectl => k8s.io/kubectl v0.34.1

replace k8s.io/kubelet => k8s.io/kubelet v0.34.1

replace k8s.io/legacy-cloud-providers => k8s.io/legacy-cloud-providers v0.24.3

replace k8s.io/metrics => k8s.io/metrics v0.34.1

replace k8s.io/mount-utils => k8s.io/mount-utils v0.34.6

replace k8s.io/pod-security-admission => k8s.io/pod-security-admission v0.34.1

replace k8s.io/sample-apiserver => k8s.io/sample-apiserver v0.34.1

replace k8s.io/sample-cli-plugin => k8s.io/sample-cli-plugin v0.34.1

replace k8s.io/sample-controller => k8s.io/sample-controller v0.34.1

require (
	github.com/golang/glog v1.2.4
	gotest.tools v2.2.0+incompatible
	k8s.io/api v0.34.1
	k8s.io/apimachinery v0.34.1
	k8s.io/kubernetes v1.34.1
)

require (
	github.com/beorn7/perks v1.0.1 // indirect
	github.com/blang/semver/v4 v4.0.0 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/distribution/reference v0.6.0 // indirect
	github.com/fxamacker/cbor/v2 v2.9.0 // indirect
	github.com/go-logr/logr v1.4.2 // indirect
	github.com/gogo/protobuf v1.3.2 // indirect
	github.com/google/go-cmp v0.7.0 // indirect
	github.com/json-iterator/go v1.1.12 // indirect
	github.com/modern-go/concurrent v0.0.0-20180306012644-bacd9c7ef1dd // indirect
	github.com/modern-go/reflect2 v1.0.3-0.20250322232337-35a7c28c31ee // indirect
	github.com/munnerz/goautoneg v0.0.0-20191010083416-a7dc8b61c822 // indirect
	github.com/opencontainers/go-digest v1.0.0 // indirect
	github.com/pkg/errors v0.9.1 // indirect
	github.com/prometheus/client_golang v1.22.0 // indirect
	github.com/prometheus/client_model v0.6.1 // indirect
	github.com/prometheus/common v0.62.0 // indirect
	github.com/prometheus/procfs v0.15.1 // indirect
	github.com/spf13/pflag v1.0.6 // indirect
	github.com/x448/float16 v0.8.4 // indirect
	go.opentelemetry.io/otel v1.35.0 // indirect
	go.opentelemetry.io/otel/trace v1.35.0 // indirect
	go.yaml.in/yaml/v2 v2.4.2 // indirect
	golang.org/x/net v0.38.0 // indirect
	golang.org/x/sys v0.31.0 // indirect
	golang.org/x/text v0.23.0 // indirect
	google.golang.org/protobuf v1.36.5 // indirect
	gopkg.in/inf.v0 v0.9.1 // indirect
	k8s.io/apiextensions-apiserver v0.0.0 // indirect
	k8s.io/apiserver v0.34.1 // indirect
	k8s.io/client-go v0.34.1 // indirect
	k8s.io/component-base v0.34.1 // indirect
	k8s.io/component-helpers v0.0.0 // indirect
	k8s.io/controller-manager v0.0.0 // indirect
	k8s.io/klog/v2 v2.130.1 // indirect
	k8s.io/utils v0.0.0-20250604170112-4c0f3b243397 // indirect
	sigs.k8s.io/json v0.0.0-20241014173422-cfa47c3a1cc8 // indirect
	sigs.k8s.io/randfill v1.0.0 // indirect
	sigs.k8s.io/structured-merge-diff/v6 v6.3.0 // indirect
	sigs.k8s.io/yaml v1.6.0 // indirect
)

replace k8s.io/cri-client => k8s.io/cri-client v0.34.1

replace k8s.io/dynamic-resource-allocation => k8s.io/dynamic-resource-allocation v0.34.1

replace k8s.io/endpointslice => k8s.io/endpointslice v0.34.1

replace k8s.io/externaljwt => k8s.io/externaljwt v0.34.6

replace k8s.io/kms => k8s.io/kms v0.34.1
