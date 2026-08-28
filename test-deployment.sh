#!/usr/bin/env bash
set -euo pipefail

artifact_root="$(cd "$(dirname "$0")" && pwd -P)"
public_root="$artifact_root/public"
image_name="chibbo-library-deploy:test"
container_name="chibbo-library-deploy-test"

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for required in \
  "$artifact_root/.dockerignore" \
  "$artifact_root/Dockerfile" \
  "$artifact_root/nginx.conf" \
  "$public_root/index.html" \
  "$public_root/work/wk_3rqr0aa1.html" \
  "$public_root/person/pe_hh1ptvn5.html" \
  "$public_root/browse.html" \
  "$public_root/assets/covers/wk_3rqr0aa1.webp" \
  "$public_root/api/v1/manifest.json" \
  "$public_root/opds/root.json"; do
  test -f "$required" || die "required artifact is missing: ${required#"$artifact_root"/}"
done

for forbidden in catalog review quarantine raw .git .venv tmp; do
  match="$(find "$public_root" -type d -name "$forbidden" -print -quit)"
  test -z "$match" || die "forbidden source directory was published: $match"
done

if rg -I -n --hidden \
  '(^|[^A-Za-z0-9])(gho_|github_pat_|COOLIFY_API_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY|GEMINI_API_KEY|PRIVATE KEY-----)' \
  "$artifact_root/Dockerfile" "$artifact_root/nginx.conf" "$public_root"; then
  die "secret-like material was found in the deployment artifact"
fi

oversized="$(find "$public_root" -type f -size +99999999c -print -quit)"
test -z "$oversized" || die "GitHub-incompatible file is at least 100 MB: $oversized"

docker build --tag "$image_name" "$artifact_root"

runtime_tmp="$(mktemp -d)"
cleanup() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  rm -rf "$runtime_tmp"
}
trap cleanup EXIT

docker rm -f "$container_name" >/dev/null 2>&1 || true
docker run --detach --name "$container_name" --publish 127.0.0.1::8080 "$image_name" >/dev/null
host_port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$container_name")"
base_url="http://127.0.0.1:$host_port"

for _attempt in $(seq 1 30); do
  if curl --fail --silent "$base_url/healthz" >/dev/null; then
    break
  fi
  sleep 0.2
done
curl --fail --silent "$base_url/healthz" >/dev/null || die "container did not become healthy"

probe() {
  local route="$1" expected_type="$2" marker="$3"
  local label headers body status
  label="$(printf '%s' "$route" | tr '/?' '__')"
  headers="$runtime_tmp/$label.headers"
  body="$runtime_tmp/$label.body"
  status="$(curl --silent --show-error --location --dump-header "$headers" \
    --output "$body" --write-out '%{http_code}' "$base_url$route")"
  test "$status" = 200 || die "$route returned HTTP $status"
  grep -Eiq "^content-type: *$expected_type" "$headers" \
    || die "$route did not return $expected_type"
  if test -n "$marker"; then
    grep -Fq "$marker" "$body" || die "$route did not contain expected marker: $marker"
  fi
  test -s "$body" || die "$route returned an empty body"
  printf 'PASS %s HTTP 200 %s\n' "$route" "$expected_type"
}

probe /healthz text/plain ok
probe / text/html 'Discover Amharic books'
probe /work/wk_3rqr0aa1.html text/html '01 ብር'
probe /person/pe_hh1ptvn5.html text/html 'Author'
probe /browse.html text/html 'By Amharic letter'
probe /assets/covers/wk_3rqr0aa1.webp image/webp ''
probe /api/v1/manifest.json application/json '83a93da65c4204de2a048922e2ed34916ac838cd'
probe /opds/root.json application/json 'Chibbo Library'

curl --fail --silent "$base_url/api/v1/manifest.json" \
  | jq -e '.commit == "83a93da65c4204de2a048922e2ed34916ac838cd" and .counts.works == 1608 and .counts.people == 1267' \
  >/dev/null
curl --fail --silent "$base_url/opds/root.json" \
  | jq -e '.metadata.title == "Chibbo Library" and .metadata.numberOfItems == 1608' \
  >/dev/null

for public_route in / /work/wk_3rqr0aa1.html /person/pe_hh1ptvn5.html /browse.html; do
  if curl --fail --silent "$base_url$public_route" \
    | rg -i 'Every record here is a draft|Every record is a draft|Built from commit|Catalogued from|given name first|not ours|one concept spelled four|missing on purpose|>People<|>Works<'; then
    die "$public_route contains internal-facing copy"
  fi
done

printf 'PASS deployment artifact contract\n'
