# Runtime Node Ansible

Desktop1/Desktop2 Runtime Node를 준비하는 Ansible 구성이다.

## 파일 구성

- `ansible.cfg`: runtime 저장소 내부 Ansible 기본 설정
- `../ansible.cfg`: 저장소 루트에서 lint/syntax-check를 실행하기 위한 Ansible 기본 설정
- `inventory/runtime-nodes.ini.example`: Runtime Node inventory 예시
- `inventory/dev.ini`: 개발 장비 기준 Runtime Node inventory
- `group_vars/runtime_nodes.yml`: runtime 계정, 설치 패키지, 경로 변수
- `playbooks/runtime-node-setup.yml`: Runtime Node 기본 구성 playbook
- `playbooks/check-runtime-node.yml`: Runtime Node SSH 연결, 필수 binary, `/var/lib/cka` 쓰기 검증 playbook
- `playbooks/wait-vm-ssh.yml`: 세션 VM SSH 연결 대기 playbook
- `playbooks/bootstrap-vm.yml`: SSH 연결 확인 후 세션 VM kubeadm 사전 Bootstrap playbook
- `roles/runtime_node`: Docker, kind, libvirt/qemu, cloud-init, runtime 계정 구성 role
- `roles/session_vm_bootstrap`: 세션 VM swap, kernel module, sysctl, containerd, kubelet 기본 구성 role

## 보안 정책

- 실제 SSH private key는 저장소에 저장하지 않는다.
- 현재 개발 inventory는 `cert-infra`와 동일하게 `user` 계정과 `~/.ssh/id_ed25519`를 사용한다.
- `runtime_allowed_ssh_public_keys`에는 runtime 전용 운영 public key만 외부 inventory/group_vars에서 주입한다.
- Runtime Node SSH는 방화벽에서 miniPC IP만 허용해야 한다.
- Bastion container에는 runtime 관리 key를 복사하지 않는다.

## 실행 예시

```bash
cp ansible/inventory/runtime-nodes.ini.example ansible/inventory/runtime-nodes.ini
ansible-playbook -i ansible/inventory/runtime-nodes.ini ansible/playbooks/runtime-node-setup.yml
```

`runtime-nodes.ini`는 환경별 파일이며 필요 시 Git에 포함하지 않는 방식으로 관리한다.

## 연결 검증

Desktop1만 검증할 때:

```bash
ansible-playbook -i ansible/inventory/dev.ini ansible/playbooks/check-runtime-node.yml --check --limit desktop1
```

Desktop1/Desktop2를 모두 검증할 때:

```bash
ansible-playbook -i ansible/inventory/dev.ini ansible/playbooks/check-runtime-node.yml --check
```

## 세션 VM Bootstrap

세션 VM은 kubeadm 실행 전에 SSH 연결 확인을 반드시 통과해야 한다.

```bash
ansible-playbook -i ansible/inventory/session-example.ini ansible/playbooks/bootstrap-vm.yml
```

`session-example.ini`는 예시이며 실제 세션에서는 VM IP와 세션 VM private key 경로를 런타임이 생성한 값으로 대체한다.
