# cert-runtime

CKA/CKAD/CKS 모의시험 플랫폼의 Runtime 실행 영역 저장소이다.

## 포함 범위

- Runtime Node 초기 설정
- Bastion container
- kind cluster 생성/삭제
- libvirt/KVM VM 생성/삭제
- kubeadm VM cluster bootstrap
- cloud-init template
- Ansible setup
- Packer golden image template
- session provision/grade/cleanup/inspect script

## 제외 범위

- Frontend
- Backend API
- token/session DB
- 문제 본문 작성
- 사용자 결과 저장
- secret, private key, qcow2 image, generated ISO, session data

## 하네스

작업 전 루트 작업공간의 `../docs/harness`에서 작업 유형에 맞는 하네스를 읽는다.

- Runtime: `../docs/harness/00-project-brief.md`, `../docs/harness/01-contracts.md`, `../docs/harness/04-runtime-harness.md`, `../docs/harness/06-security-harness.md`
- Security: `../docs/harness/00-project-brief.md`, `../docs/harness/01-contracts.md`, `../docs/harness/06-security-harness.md`
- Release: `../docs/harness/00-project-brief.md`, `../docs/harness/01-contracts.md`, `../docs/harness/07-release-harness.md`

## Task 기준

Task 문서는 루트 작업공간의 `../docs/tasks`를 단일 기준으로 사용한다.

작업 시작 전 확인 순서:

1. `../docs/project-state.md`
2. `../docs/tasks/<TASK-ID>.md`
3. 루트 `../docs/harness/*.md` 중 작업 유형에 필요한 하네스

이 저장소에서 다른 저장소 변경이 필요해지면 직접 넘겨서 수정하지 않고 루트 `../docs/project-state.md`의 cross-project TODO에 기록한다.

## 핵심 보안 정책

- Golden Image에 고정 SSH public key를 삽입하지 않는다.
- VM 생성 시 cloud-init으로 SSH public key를 주입한다.
- VM 생성 후 Ansible SSH 연결 검증을 통과해야 kubeadm/bootstrap 단계로 진행한다.
