#!/usr/bin/env bash

set -euo pipefail

STATE_DIR="${FAKE_KCADM_STATE_DIR:?FAKE_KCADM_STATE_DIR is required}"
mkdir -p "$STATE_DIR"
printf '%s\n' "$*" >>"$STATE_DIR/calls.log"

setting_value() {
  local wanted="$1"
  shift
  while (($#)); do
    if [[ "$1" == "-s" ]] && (($# > 1)); then
      shift
      if [[ "$1" == "$wanted="* ]]; then
        printf '%s\n' "${1#*=}"
        return 0
      fi
    fi
    shift
  done
  return 1
}

write_settings() {
  local file="$1"
  shift
  : >"$file"
  while (($#)); do
    if [[ "$1" == "-s" ]] && (($# > 1)); then
      shift
      printf '%s\n' "$1" >>"$file"
    fi
    shift
  done
}

command_name="${1:-}"
if (($#)); then
  shift
fi

case "$command_name" in
  config)
    [ "${1:-}" = "credentials" ] || exit 2
    attempts_file="$STATE_DIR/login-attempts"
    attempts=0
    [ ! -f "$attempts_file" ] || attempts="$(<"$attempts_file")"
    attempts=$((attempts + 1))
    printf '%s\n' "$attempts" >"$attempts_file"
    if ((attempts <= ${FAKE_KCADM_LOGIN_FAILURES:-0})); then
      exit 1
    fi
    ;;
  get)
    resource="${1:-}"
    case "$resource" in
      realms/mcp)
        [ -f "$STATE_DIR/realm" ]
        ;;
      identity-provider/instances/ds-sso)
        [ -f "$STATE_DIR/idp" ]
        ;;
      identity-provider/instances/ds-sso/mappers)
        [ ! -f "$STATE_DIR/idp-mapper" ] || printf '%s\n' "idp-mapper-loginid,loginid"
        ;;
      client-scopes)
        [ ! -f "$STATE_DIR/scope" ] || printf '%s\n' "scope-mock,mcp:mock:use"
        ;;
      client-scopes/scope-mock/protocol-mappers/models)
        [ ! -f "$STATE_DIR/audience-mapper" ] || printf '%s\n' "scope-audience,mock-audience"
        [ ! -f "$STATE_DIR/loginid-mapper" ] || printf '%s\n' "scope-loginid,loginid"
        ;;
      clients)
        [ ! -f "$STATE_DIR/client" ] || printf '%s\n' "client-cli"
        ;;
      clients/client-cli/optional-client-scopes)
        [ ! -f "$STATE_DIR/optional-scope" ] || printf '%s\n' "scope-mock,mcp:mock:use"
        ;;
      *)
        echo "unsupported fake get resource: $resource" >&2
        exit 2
        ;;
    esac
    ;;
  create)
    resource="${1:-}"
    if (($#)); then
      shift
    fi
    case "$resource" in
      realms)
        write_settings "$STATE_DIR/realm" "$@"
        ;;
      identity-provider/instances)
        write_settings "$STATE_DIR/idp" "$@"
        ;;
      identity-provider/instances/ds-sso/mappers)
        write_settings "$STATE_DIR/idp-mapper" "$@"
        ;;
      client-scopes)
        write_settings "$STATE_DIR/scope" "$@"
        printf '%s\n' "scope-mock"
        ;;
      client-scopes/scope-mock/protocol-mappers/models)
        mapper_name="$(setting_value name "$@")"
        case "$mapper_name" in
          mock-audience) write_settings "$STATE_DIR/audience-mapper" "$@" ;;
          loginid) write_settings "$STATE_DIR/loginid-mapper" "$@" ;;
          *) exit 2 ;;
        esac
        ;;
      clients)
        write_settings "$STATE_DIR/client" "$@"
        printf '%s\n' "client-cli"
        ;;
      *)
        echo "unsupported fake create resource: $resource" >&2
        exit 2
        ;;
    esac
    ;;
  update)
    resource="${1:-}"
    if (($#)); then
      shift
    fi
    case "$resource" in
      realms/mcp) write_settings "$STATE_DIR/realm" "$@" ;;
      identity-provider/instances/ds-sso) write_settings "$STATE_DIR/idp" "$@" ;;
      identity-provider/instances/ds-sso/mappers/idp-mapper-loginid) write_settings "$STATE_DIR/idp-mapper" "$@" ;;
      client-scopes/scope-mock) write_settings "$STATE_DIR/scope" "$@" ;;
      client-scopes/scope-mock/protocol-mappers/models/scope-audience) write_settings "$STATE_DIR/audience-mapper" "$@" ;;
      client-scopes/scope-mock/protocol-mappers/models/scope-loginid) write_settings "$STATE_DIR/loginid-mapper" "$@" ;;
      clients/client-cli) write_settings "$STATE_DIR/client" "$@" ;;
      clients/client-cli/optional-client-scopes/scope-mock)
        [ "${FAKE_KCADM_FAIL_ATTACH:-0}" != "1" ] || exit 1
        : >"$STATE_DIR/optional-scope"
        ;;
      *)
        echo "unsupported fake update resource: $resource" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    echo "unsupported fake command: $command_name" >&2
    exit 2
    ;;
esac
