# Ubuntu 22.04 kubeadm Golden Image

이 디렉토리는 CKA VM cluster용 Golden Image Packer skeleton이다.

Golden Image는 kubeadm 클러스터를 미리 구성하지 않는다.
이 이미지에는 containerd, kubeadm, kubelet, kubectl 같은 기본 패키지만 포함한다.
노드가 `Ready`가 되려면 VM 생성 후 kubeadm bootstrap 단계에서 반드시 CNI manifest를 적용해야 한다.

## 포함 파일

- `ubuntu-22.04-kubeadm.pkr.hcl`: QEMU 기반 Packer template
- `scripts/00-install-base-packages.sh`: cloud-init과 기본 패키지 설치
- `scripts/10-install-containerd.sh`: containerd와 커널 설정 적용
- `scripts/20-install-kubernetes-tools.sh`: kubeadm/kubelet/kubectl 설치
- `scripts/30-install-exam-tools.sh`: crictl, jq, yq, vim 검증
- `scripts/90-clean-golden-image.sh`: machine-id, SSH host key, apt cache 정리
- `scripts/99-validate-cloud-init.sh`: cloud-init 활성화와 고정 SSH key 부재 검증
- `image-metadata.yaml`: 운영에서 참조할 image metadata

## 보안 정책

- qcow2 산출물은 Git에 저장하지 않는다.
- Golden Image에는 고정 SSH public key를 넣지 않는다.
- VM 생성 시 cloud-init으로 세션별 SSH public key를 주입한다.
- VM 생성 후 kubeadm bootstrap 전에 Ansible SSH 접속 검증을 통과해야 한다.
- kubeadm init 후 CNI를 적용하고 Node Ready 검증을 통과해야 한다.

## Bootstrap 필수 Gate

TASK-017 kubeadm bootstrap은 최소 다음 순서를 지켜야 한다.

1. control-plane VM에 `kubeadm init` 실행
2. CNI manifest 적용
3. worker VM join
4. `kubectl wait node --for=condition=Ready` 검증

CNI가 적용되지 않으면 kubelet은 준비되어도 Node는 Ready가 되지 않는다.

## 검증

```bash
packer init images/packer/ubuntu-22.04-kubeadm
packer validate images/packer/ubuntu-22.04-kubeadm
```

실제 빌드 전에는 `source_image_path`와 `source_image_checksum`을 운영 이미지 경로와 checksum으로 교체한다.
