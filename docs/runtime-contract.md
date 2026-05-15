# Runtime contract

이 문서는 `cert-platform` Backend/Worker가 `cert-runtime`을 호출할 때 기대하는 고정 계약이다.

## Host and root

Runtime 전용 호스트 이름은 `runtime`이다. 플랫폼이 실행되는 RKE2 호스트는 `infra`, 운영 기준점은 `bastion`으로 부른다.

Runtime root는 `/var/lib/cka`로 고정한다.

```text
/var/lib/cka
├── images/base
├── images/source
├── images/sessions
├── sessions/<session_id>
├── logs
└── tmp
```

`cert-runtime` 저장소 체크아웃 경로는 운영자가 배포 방식에 맞게 정할 수 있지만, Backend가 실행 스크립트를 찾는 기본 root도 `/var/lib/cka`이다. 따라서 운영 배포에서는 아래 경로가 존재해야 한다.

```text
/var/lib/cka/runtime/scripts/provision-session.sh
/var/lib/cka/runtime/scripts/inspect-session.sh
/var/lib/cka/runtime/scripts/grade-session.sh
/var/lib/cka/runtime/scripts/cleanup-session.sh
```

## Session topology

세션 1개는 VM 3대와 Kubernetes cluster 2개로 구성한다.

| Internal hostname | Global resource name | Role | Context |
|---|---|---|---|
| `cka0001` | `<session_id>-cka0001` | kubeadm control-plane, first terminal target | `cka-vm` |
| `cka0002` | `<session_id>-cka0002` | kind 전용 VM | `cka-kind` |
| `cka0003` | `<session_id>-cka0003` | kubeadm worker | `cka-vm` |

세션 내부 hostname은 항상 `cka0001`, `cka0002`, `cka0003`이다. libvirt domain, disk, cloud-init ISO, log, kubeconfig, container, kind cluster 같은 Runtime 전역 자원은 반드시 `session_id`를 포함한다.

예:

```text
<session_id>-cka0001
<session_id>-cka0002
<session_id>-cka0003
<session_id>-cka0001.qcow2
<session_id>-cka0002-cloud-init.iso
<session_id>-cka0002-kind
```

`session_id`가 비어 있거나 안전하지 않은 문자를 포함하면 Runtime script는 전역 자원을 만들기 전에 실패해야 한다.

## Script interface

Backend/Worker는 Runtime 호스트에 SSH로 접속한 뒤 아래 script를 호출한다.

```bash
/var/lib/cka/runtime/scripts/provision-session.sh --session-id <id> --exam-type <type> --exam-set-id <id>
/var/lib/cka/runtime/scripts/inspect-session.sh --session-id <id>
/var/lib/cka/runtime/scripts/grade-session.sh --session-id <id> --exam-type <type> --exam-set-id <id>
/var/lib/cka/runtime/scripts/cleanup-session.sh --session-id <id>
```

모든 script는 성공 시 stdout에 JSON 한 개를 출력한다. 진행 로그와 상세 오류는 세션 log 디렉터리 또는 stderr에 기록한다.

`provision-session.sh`와 `inspect-session.sh`의 READY JSON은 Backend가 그대로 파싱할 수 있는 아래 형태를 기준으로 한다.

```json
{
  "sessionId": "sess-abc123",
  "status": "READY",
  "vms": [
    {"name": "cka0001", "domain": "sess-abc123-cka0001", "ip": "10.10.1.11", "role": "kubeadm-cp"},
    {"name": "cka0002", "domain": "sess-abc123-cka0002", "ip": "10.10.1.12", "role": "kind"},
    {"name": "cka0003", "domain": "sess-abc123-cka0003", "ip": "10.10.1.13", "role": "kubeadm-worker"}
  ],
  "contexts": ["cka-vm", "cka-kind"],
  "adminCommands": [
    "ssh cka-runtime@runtime virsh console sess-abc123-cka0001",
    "ssh cka-runtime@runtime virsh console sess-abc123-cka0002",
    "ssh cka-runtime@runtime virsh console sess-abc123-cka0003"
  ]
}
```

`grade-session.sh`의 결과 JSON은 단발성 채점 결과이며 장기 저장을 전제로 하지 않는다.

```json
{
  "sessionId": "sess-abc123",
  "examSetId": "cka-mock-001",
  "status": "FINISHED",
  "totalScore": 10,
  "maxScore": 10,
  "results": [
    {"questionId": "cka-q001", "status": "PASSED", "score": 10, "maxScore": 10, "message": "ok"}
  ]
}
```
