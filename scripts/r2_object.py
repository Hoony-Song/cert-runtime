#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import http.client
import json
import mimetypes
import os
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


DEFAULT_BUCKET = "sweetlabs-artifacts"
DEFAULT_PUBLIC_BASE_URL = "https://artifacts.sweetlabs.kr"
DEFAULT_REGION = "auto"
SERVICE = "s3"


class R2Error(RuntimeError):
    pass


def _strip(value: str) -> str:
    return value.strip().strip("'\"")


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        raise R2Error(f"env file not found: {path}")
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[_strip(key)] = _strip(value)
    return values


def first_value(values: dict[str, str], *names: str, default: str | None = None) -> str | None:
    for name in names:
        if name in values and values[name]:
            return values[name]
        env_value = os.getenv(name)
        if env_value:
            return env_value
    return default


def credentials(env_file: Path) -> tuple[str, str, str, str, str, str]:
    values = load_env(env_file)
    access_key = first_value(values, "R2_ACCESS_KEY_ID", "AWS_ACCESS_KEY_ID", "AccessKeyID", "Access Key ID")
    secret_key = first_value(values, "R2_SECRET_ACCESS_KEY", "AWS_SECRET_ACCESS_KEY", "SecretAccessKey", "Secret Access Key")
    endpoint = first_value(values, "R2_ENDPOINT", "AWS_ENDPOINT_URL", "endpoint", "endpoints", "Endpoint")
    bucket = first_value(values, "R2_BUCKET", "AWS_BUCKET", "bucket", "Bucket", default=DEFAULT_BUCKET)
    public_base_url = first_value(values, "R2_PUBLIC_BASE_URL", "public_base_url", "PublicBaseURL", default=DEFAULT_PUBLIC_BASE_URL)
    region = first_value(values, "R2_REGION", "AWS_REGION", "region", "Region", default=DEFAULT_REGION)
    missing = [
        name
        for name, value in {
            "access key": access_key,
            "secret key": secret_key,
            "endpoint": endpoint,
            "bucket": bucket,
            "public base url": public_base_url,
            "region": region,
        }.items()
        if not value
    ]
    if missing:
        raise R2Error(f"missing R2 configuration: {', '.join(missing)}")
    return access_key or "", secret_key or "", normalize_endpoint(endpoint or ""), bucket or "", public_base_url or "", region or ""


def normalize_endpoint(endpoint: str) -> str:
    endpoint = endpoint.strip().rstrip("/")
    if not endpoint.startswith(("http://", "https://")):
        endpoint = "https://" + endpoint
    parsed = urllib.parse.urlsplit(endpoint)
    if parsed.path not in {"", "/"}:
        endpoint = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, "", "", ""))
    return endpoint


def quote_path(path: str) -> str:
    return urllib.parse.quote(path, safe="/-_.~")


def file_sha256(path: Path, chunk_size: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def sign(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def signing_key(secret_key: str, date_stamp: str, region: str) -> bytes:
    key_date = sign(("AWS4" + secret_key).encode("utf-8"), date_stamp)
    key_region = hmac.new(key_date, region.encode("utf-8"), hashlib.sha256).digest()
    key_service = hmac.new(key_region, SERVICE.encode("utf-8"), hashlib.sha256).digest()
    return hmac.new(key_service, b"aws4_request", hashlib.sha256).digest()


def s3_request(
    *,
    env_file: Path,
    method: str,
    key: str,
    body: bytes = b"",
    content_type: str | None = None,
) -> bytes:
    access_key, secret_key, endpoint, bucket, _public_base_url, region = credentials(env_file)
    parsed_endpoint = urllib.parse.urlsplit(endpoint)
    host = parsed_endpoint.netloc
    object_path = f"/{bucket}/{quote_path(key.lstrip('/'))}"
    url = urllib.parse.urlunsplit((parsed_endpoint.scheme, host, object_path, "", ""))

    now = dt.datetime.now(dt.UTC)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()

    headers = {
        "host": host,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    if content_type:
        headers["content-type"] = content_type
    canonical_headers = "".join(f"{name}:{headers[name]}\n" for name in sorted(headers))
    signed_headers = ";".join(sorted(headers))
    canonical_request = "\n".join(
        [
            method,
            object_path,
            "",
            canonical_headers,
            signed_headers,
            payload_hash,
        ]
    )
    credential_scope = f"{date_stamp}/{region}/{SERVICE}/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    signature = hmac.new(signing_key(secret_key, date_stamp, region), string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    auth = (
        "AWS4-HMAC-SHA256 "
        f"Credential={access_key}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, "
        f"Signature={signature}"
    )
    request_headers = {k: v for k, v in headers.items() if k != "host"}
    request_headers["Authorization"] = auth
    request = urllib.request.Request(url, data=body if method != "GET" else None, headers=request_headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise R2Error(f"R2 {method} {key} failed: HTTP {exc.code} {detail}") from exc
    except urllib.error.URLError as exc:
        raise R2Error(f"R2 {method} {key} failed: {exc}") from exc


def s3_put_file(*, env_file: Path, key: str, source: Path, content_type: str) -> None:
    access_key, secret_key, endpoint, bucket, _public_base_url, region = credentials(env_file)
    parsed_endpoint = urllib.parse.urlsplit(endpoint)
    host = parsed_endpoint.netloc
    object_path = f"/{bucket}/{quote_path(key.lstrip('/'))}"

    now = dt.datetime.now(dt.UTC)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = file_sha256(source)

    headers = {
        "host": host,
        "content-type": content_type,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    canonical_headers = "".join(f"{name}:{headers[name]}\n" for name in sorted(headers))
    signed_headers = ";".join(sorted(headers))
    canonical_request = "\n".join(
        [
            "PUT",
            object_path,
            "",
            canonical_headers,
            signed_headers,
            payload_hash,
        ]
    )
    credential_scope = f"{date_stamp}/{region}/{SERVICE}/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    signature = hmac.new(signing_key(secret_key, date_stamp, region), string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    request_headers = {
        "Authorization": (
            "AWS4-HMAC-SHA256 "
            f"Credential={access_key}/{credential_scope}, "
            f"SignedHeaders={signed_headers}, "
            f"Signature={signature}"
        ),
        "Content-Length": str(source.stat().st_size),
        "Content-Type": content_type,
        "Host": host,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    connection_class = http.client.HTTPSConnection if parsed_endpoint.scheme == "https" else http.client.HTTPConnection
    connection = connection_class(host, timeout=300)
    try:
        with source.open("rb") as handle:
            connection.request("PUT", object_path, body=handle, headers=request_headers)
            response = connection.getresponse()
            detail = response.read().decode("utf-8", errors="replace")
            if response.status >= 300:
                raise R2Error(f"R2 PUT {key} failed: HTTP {response.status} {detail}")
    finally:
        connection.close()


def public_url(env_file: Path, key: str) -> str:
    *_unused, public_base_url, _region = credentials(env_file)
    return public_base_url.rstrip("/") + "/" + quote_path(key.lstrip("/"))


def put_object(args: argparse.Namespace) -> None:
    source = Path(args.file)
    content_type = args.content_type or mimetypes.guess_type(source.name)[0] or "application/octet-stream"
    s3_put_file(env_file=Path(args.env_file), key=args.key, source=source, content_type=content_type)
    print(json.dumps({"key": args.key, "size": source.stat().st_size, "url": public_url(Path(args.env_file), args.key)}, ensure_ascii=False))


def smoke(args: argparse.Namespace) -> None:
    env_file = Path(args.env_file)
    message = f"sweetlabs-r2-smoke {dt.datetime.now(dt.UTC).isoformat()}\n"
    key = args.key
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(message)
        temp_path = Path(handle.name)
    try:
        put_args = argparse.Namespace(env_file=str(env_file), file=str(temp_path), key=key, content_type="text/plain")
        put_object(put_args)
    finally:
        temp_path.unlink(missing_ok=True)

    url = public_url(env_file, key)
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        downloaded = response.read().decode("utf-8")
    if downloaded != message:
        raise R2Error("public download content mismatch")
    print(json.dumps({"smoke": "ok", "key": key, "url": url}, ensure_ascii=False))


def show_public_url(args: argparse.Namespace) -> None:
    print(public_url(Path(args.env_file), args.key))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Small Cloudflare R2 S3-compatible object helper.")
    parser.add_argument("--env-file", default="s3.env", help="local R2 env file")
    subparsers = parser.add_subparsers(dest="command", required=True)

    put_parser = subparsers.add_parser("put")
    put_parser.add_argument("--file", required=True)
    put_parser.add_argument("--key", required=True)
    put_parser.add_argument("--content-type")
    put_parser.set_defaults(func=put_object)

    smoke_parser = subparsers.add_parser("smoke")
    smoke_parser.add_argument("--key", default="runtime/installer/ping.txt")
    smoke_parser.set_defaults(func=smoke)

    url_parser = subparsers.add_parser("public-url")
    url_parser.add_argument("--key", required=True)
    url_parser.set_defaults(func=show_public_url)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
    except R2Error as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
