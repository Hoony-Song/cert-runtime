# Runtime Artifacts

Runtime Node join installer는 Cloudflare R2에 게시된 버전 고정 artifact를 사용한다.

## Bucket

운영 bucket과 public base URL은 `s3.env` 또는 배포별 values에서 주입한다. Git에는 실제 bucket 이름이나 credential을 저장하지 않는다.

객체 경로:

```text
runtime/
  installer/install.sh
  bundles/
  images/
  manifests/
```

## Local Credential File

로컬 업로드 자격 증명은 Git에 저장하지 않는다.

```text
s3.env
```

지원하는 key 이름:

```text
Access Key ID=<redacted>
Secret Access Key=<redacted>
endpoints=https://<account-id>.r2.cloudflarestorage.com
```

표준 이름도 사용할 수 있다.

```text
R2_ACCESS_KEY_ID=<redacted>
R2_SECRET_ACCESS_KEY=<redacted>
R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
R2_BUCKET=<artifact-bucket>
R2_PUBLIC_BASE_URL=https://artifacts.example.com
```

## Smoke Test

```bash
python3 scripts/r2_object.py --env-file s3.env smoke
```

성공하면 아래 형식의 공개 URL로 테스트 객체가 다운로드된다.

```text
<R2_PUBLIC_BASE_URL>/runtime/installer/ping.txt
```

## Publish Runtime Bundle

Golden image 없이 runtime bundle과 manifest만 게시:

```bash
scripts/publish-runtime-artifacts.sh \
  --version v20260517 \
  --public-base-url https://artifacts.example.com
```

Golden image까지 게시:

```bash
scripts/publish-runtime-artifacts.sh \
  --version v20260517 \
  --public-base-url https://artifacts.example.com \
  --image /var/lib/cka/images/base/cka-ubuntu-22.04-kubeadm-1.30-v1/cka-ubuntu-22.04-kubeadm-1.30-v1.qcow2
```

`--image`가 압축되지 않은 qcow2이면 `.zst`로 압축한 뒤 게시한다.

## Manifest

게시 스크립트는 아래 manifest를 업로드한다.

```text
runtime/manifests/runtime-node-<version>.json
```

manifest에는 runtime bundle URL, checksum, golden image URL/checksum, 필수 패키지 목록, 설치 기준 runtime root가 포함된다.

이미 게시된 versioned object는 같은 key로 덮어쓰지 않는다. Cloudflare/R2 custom domain 캐시가 기존 bytes를 잠시 반환할 수 있으므로,
runtime bundle이나 manifest를 갱신할 때는 `runtime-node-<new-version>.json`과 `cert-runtime-<new-version>.tar.gz`처럼 새 version key를 발행한다.

## Join Installer

Admin에서 생성한 one-line command는 아래 installer를 사용한다.

```text
<R2_PUBLIC_BASE_URL>/runtime/installer/install.sh
```

installer는 manifest를 내려받아 필수 패키지, kind, runtime bundle, golden image를 설치하고 platform API에 단계 상태와 최종 resource profile을 보고한다. join token 원문은 Runtime Node에서 API 호출에만 사용하고 저장하지 않는다.
