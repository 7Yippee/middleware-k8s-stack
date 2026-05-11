#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${ENVIRONMENT:-all}"

usage() {
  cat <<'EOF'
Usage:
  scripts/set-image-tag.sh <component> <target-repository> <new-tag> [source-image]

Environment:
  ENVIRONMENT   dev, prod, or all. Default: all

Examples:
  scripts/set-image-tag.sh rabbitmq rabbitmq 4.1.4-debian-12-r0 docker.io/bitnamilegacy/rabbitmq:4.1.4-debian-12-r0
  scripts/set-image-tag.sh kafka kafka 4.0.1-debian-12-r0 docker.io/bitnamilegacy/kafka:4.0.1-debian-12-r0
  ENVIRONMENT=dev scripts/set-image-tag.sh redis redis 8.6.4 docker.io/bitnamilegacy/redis:latest
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 3 || $# -gt 4 ]]; then
  usage >&2
  exit 1
fi

component="$1"
target_repository="$2"
new_tag="$3"
source_image="${4:-}"
image_list="$ROOT_DIR/config/images.txt"

if [[ ! -f "$image_list" ]]; then
  echo "Image list not found: $image_list" >&2
  exit 1
fi

tmp_file="$(mktemp)"
updated="false"

while IFS= read -r line; do
  if [[ -z "$line" || "$line" == \#* ]]; then
    printf '%s\n' "$line" >> "$tmp_file"
    continue
  fi

  read -r item_component item_source item_repository item_tag rest <<< "$line"
  if [[ "$item_component" == "$component" && "$item_repository" == "$target_repository" ]]; then
    printf '%s %s %s %s\n' "$item_component" "${source_image:-$item_source}" "$item_repository" "$new_tag" >> "$tmp_file"
    updated="true"
  else
    printf '%s\n' "$line" >> "$tmp_file"
  fi
done < "$image_list"

if [[ "$updated" != "true" ]]; then
  rm -f "$tmp_file"
  echo "No image mapping found for component=$component target_repository=$target_repository" >&2
  exit 1
fi

mv "$tmp_file" "$image_list"

update_values_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  awk -v repo="tools_y/$target_repository" -v tag="$new_tag" '
    $0 ~ /^[[:space:]]*repository:[[:space:]]*/ {
      current_repo=$2
      in_target=(current_repo == repo)
    }
    in_target && $0 ~ /^[[:space:]]*tag:[[:space:]]*/ {
      sub(/tag:[[:space:]].*/, "tag: " tag)
      in_target=0
    }
    { print }
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

case "$ENVIRONMENT" in
  all)
    update_values_file "$ROOT_DIR/envs/dev/$component.yaml"
    update_values_file "$ROOT_DIR/envs/prod/$component.yaml"
    ;;
  dev|prod)
    update_values_file "$ROOT_DIR/envs/$ENVIRONMENT/$component.yaml"
    ;;
  *)
    echo "ENVIRONMENT must be dev, prod, or all." >&2
    exit 1
    ;;
esac

echo "Updated $component/$target_repository to tag $new_tag."
echo "Next: scripts/mirror-images.sh $component"
echo "Then: scripts/deploy.sh $component"

