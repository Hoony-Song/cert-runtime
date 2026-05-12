# cloud-init template

VM 생성 시 세션별 SSH public key를 주입하기 위한 cloud-init template이다.

## 포함 파일

- `user-data.tpl`: VM 사용자, SSH public key, 세션 메타데이터를 렌더링한다.
- `meta-data.tpl`: cloud-init instance id와 hostname을 렌더링한다.
- `network-config.tpl`: VM 네트워크 인터페이스를 DHCP로 설정한다.

## 보안 정책

- 이 디렉토리에는 실제 SSH public key나 private key를 저장하지 않는다.
- Golden Image에는 고정 SSH public key를 넣지 않는다.
- `SSH_PUBLIC_KEY`는 VM 생성 시점에 세션별 값으로 전달한다.
- 렌더링 결과물과 ISO는 session 디렉토리 아래에만 생성하고 Git에 저장하지 않는다.

## 렌더링 예시

```bash
runtime/scripts/render-cloud-init.sh \
  --session-id cka-session-001 \
  --vm-role control-plane \
  --vm-hostname cka-session-001-cp \
  --ssh-public-key-file /path/to/session.pub \
  --output-dir /var/lib/cka/sessions/cka-session-001/cloud-init/control-plane
```
