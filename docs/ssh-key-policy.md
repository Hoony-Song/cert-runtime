# Runtime SSH Key 정책

이 문서는 miniPC, Runtime Node, 세션 VM 사이에서 사용하는 SSH key 정책을 정의한다.

## 원칙

- private key는 Git, release artifact, qcow2 image, cloud-init template, bastion container에 저장하지 않는다.
- Golden Image에는 고정 SSH public key를 삽입하지 않는다.
- VM 접속용 SSH public key는 VM 생성 시점에 cloud-init user-data로 주입한다.
- miniPC에서 Runtime Node로 접속하는 운영 key와 Ansible이 세션 VM에 접속하는 VM key는 분리한다.
- Bastion container에는 runtime 관리용 private key를 복사하지 않는다.
- SSH command에는 사용자 입력을 직접 이어 붙이지 않는다.
- VM 생성 후 kubeadm/bootstrap 전에 Ansible SSH 접속 검증을 반드시 통과해야 한다.

## Key 종류

| Key | 용도 | private key 위치 | public key 위치 | 주입 방식 |
|---|---|---|---|---|
| runtime control key | bastion이 runtime Runtime Node를 제어 | bastion 운영 계정의 key store | Runtime Node runtime 계정 `authorized_keys` | 운영자가 수동 등록 |
| session VM key | Ansible이 세션 VM에 접속 | 세션 디렉토리 또는 운영 secret store | cloud-init `ssh_authorized_keys` | VM 생성 시 렌더링 |
| user/bastion key | 사용자가 bastion에서 직접 사용하는 key | 사용하지 않음 | 사용하지 않음 | 금지 |

## miniPC → Runtime Node

miniPC는 Runtime Node를 SSH로 제어한다.

정책:

- Runtime Node SSH는 miniPC IP에서만 허용한다.
- Runtime Node에는 runtime 전용 계정을 사용한다.
- runtime 전용 계정의 sudo 권한은 필요한 명령으로 최소화한다.
- Mac 개발용 SSH key를 runtime 운영용으로 재사용하지 않는다.
- runtime control private key는 `cert-runtime` 저장소에 두지 않는다.
- runtime control private key는 bastion container 또는 세션 VM에 복사하지 않는다.

권장 경로:

```text
miniPC: /etc/cka/ssh/runtime-control
miniPC: /etc/cka/ssh/runtime-control.pub
Runtime Node: /home/cka-runtime/.ssh/authorized_keys
```

위 경로는 운영 예시이며 Git에 포함하지 않는다.

## Ansible → 세션 VM

세션 VM은 cloud-init으로 public key를 주입받는다.

정책:

- 세션 VM private key는 세션 생성 시점에 생성하거나 운영 secret store에서 발급한다.
- public key만 `runtime/scripts/render-cloud-init.sh`에 전달한다.
- 렌더링된 `user-data`, `meta-data`, `network-config`는 session 디렉토리 아래에만 저장한다.
- session 종료 또는 cleanup 시 VM private key, cloud-init ISO, 렌더링 결과물을 삭제한다.
- 실패 후 retry 시 기존 sessionId와 기존 VM key를 재사용하지 않는다.

권장 경로:

```text
/var/lib/cka/sessions/<session_id>/ssh/vm
/var/lib/cka/sessions/<session_id>/ssh/vm.pub
/var/lib/cka/sessions/<session_id>/cloud-init/<vm_role>/user-data
/var/lib/cka/sessions/<session_id>/cloud-init/<vm_role>/meta-data
/var/lib/cka/sessions/<session_id>/cloud-init/<vm_role>/network-config
```

위 경로는 Runtime Node의 임시 세션 데이터이며 Git에 포함하지 않는다.

## Golden Image 정책

Golden Image는 다음만 포함한다.

- cloud-init 활성화 상태
- containerd
- kubeadm, kubelet, kubectl
- crictl, jq, yq, vim
- 기본 커널 모듈과 sysctl 설정

Golden Image에는 다음을 포함하지 않는다.

- 고정 SSH public key
- SSH private key
- token 원문
- kubeconfig
- 세션별 cloud-init ISO
- 세션 disk

Golden Image 빌드 마지막 단계에서는 다음을 정리한다.

- `/home/*/.ssh/authorized_keys`
- `/root/.ssh/authorized_keys`
- SSH host key
- cloud-init logs
- machine-id
- apt cache

## Bastion 금지 사항

Bastion은 사용자 터미널 환경이며 관리 평면이 아니다.

절대 금지:

- runtime control private key 복사
- session VM private key 복사
- Docker socket mount
- privileged container
- host network
- grading logic 또는 answer file 복사
- 다른 사용자 session 디렉토리 mount

## 로그 정책

로그에 남겨도 되는 값:

- tokenId
- sessionId
- runtimeNodeId
- VM role
- SSH 접속 성공/실패 여부
- 실패 단계

로그에 남기면 안 되는 값:

- SSH private key
- SSH public key 전체 값
- token 원문
- kubeconfig 전체 내용
- password
- 민감한 환경 변수

public key를 식별해야 할 때는 전체 값을 남기지 않고 fingerprint만 기록한다.

예:

```bash
ssh-keygen -lf /var/lib/cka/sessions/<session_id>/ssh/vm.pub
```

## 검증 Gate

VM 생성 흐름은 최소 다음 gate를 통과해야 한다.

1. session VM key 생성 또는 발급
2. public key 형식 검증
3. cloud-init user-data 렌더링
4. cloud-init ISO 생성
5. VM 생성
6. Ansible SSH 접속 검증
7. kubeadm bootstrap 진행
8. cleanup 시 key, ISO, session disk 삭제

Ansible SSH 접속 검증이 실패하면 kubeadm bootstrap을 진행하지 않는다.

## Git 저장 금지 패턴

다음 파일은 저장소에 추가하지 않는다.

```text
*.pem
*.key
id_rsa*
*.qcow2
*.iso
sessions/
artifacts/
images/base/
images/sessions/
```

커밋 전 다음 명령으로 확인한다.

```bash
find . -type f \( -name '*.pem' -o -name '*.key' -o -name 'id_rsa*' -o -name '*.qcow2' -o -name '*.iso' \) -print
git add --dry-run .
```
