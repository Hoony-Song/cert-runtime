# Ubuntu 22.04 kubeadm Golden Image

이 디렉토리는 CKA VM cluster용 Golden Image Packer skeleton이다.

## 포함 파일

- `ubuntu-22.04-kubeadm.pkr.hcl`: QEMU 기반 Packer template
- `scripts/install-kubeadm-placeholder.sh`: kubeadm/containerd 설치 placeholder
- `image-metadata.yaml`: 운영에서 참조할 image metadata

## 보안 정책

- qcow2 산출물은 Git에 저장하지 않는다.
- Golden Image에는 고정 SSH public key를 넣지 않는다.
- VM 생성 시 cloud-init으로 세션별 SSH public key를 주입한다.
- VM 생성 후 kubeadm bootstrap 전에 Ansible SSH 접속 검증을 통과해야 한다.

## 검증

```bash
packer init images/packer/ubuntu-22.04-kubeadm
packer validate images/packer/ubuntu-22.04-kubeadm
```

실제 빌드 전에는 `source_image_path`와 `source_image_checksum`을 운영 이미지 경로와 checksum으로 교체한다.
