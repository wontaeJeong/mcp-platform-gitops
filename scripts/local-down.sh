#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="$ROOT_DIR/local"
ENV_FILE="$LOCAL_DIR/.env"
IMAGES_FILE="$LOCAL_DIR/.images.env"

compose=(docker compose)
if [ -f "$ENV_FILE" ]; then
  compose+=(--env-file "$ENV_FILE")
fi
if [ -f "$IMAGES_FILE" ]; then
  compose+=(--env-file "$IMAGES_FILE")
else
  export GATEWAY_IMAGE="localhost:5000/unused-gateway:compose-cleanup"
  export MOCK_IMAGE="localhost:5000/unused-mock:compose-cleanup"
fi
compose+=(-f "$LOCAL_DIR/compose.yaml")

"${compose[@]}" down --volumes --remove-orphans
rm -f \
  "$LOCAL_DIR/.keycloak.env" \
  "$LOCAL_DIR/.gateway.env" \
  "$LOCAL_DIR/.mock.env" \
  "$IMAGES_FILE" \
  "$LOCAL_DIR"/.verify-* \
  "$LOCAL_DIR"/.pkce-*
rm -rf "$ROOT_DIR/scripts/__pycache__"

echo "PASS: local containers, network, volumes, and generated artifacts removed"
