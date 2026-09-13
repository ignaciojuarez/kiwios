#!/bin/sh
set -eu

case "${1:-}" in
  summary)
    printf '%s\n' '{"t":"ok","msg":"Sample is ready","state":{"value":"Ready","detail":"Static template data"}}'
    ;;
  items)
    printf '%s\n' '{"t":"ok","msg":"2 sample items","state":{"columns":[{"id":"name","label":"Name"},{"id":"status","label":"Status"}],"rows":[{"id":"alpha","name":"Alpha","status":"Ready"},{"id":"beta","name":"Beta","status":"Ready"}]}}'
    ;;
  refresh)
    printf '%s\n' '{"t":"log","lvl":"info","msg":"Starting safe sample refresh"}'
    printf '%s\n' '{"t":"progress","pct":50,"msg":"Reading sample data"}'
    printf '%s\n' '{"t":"ok","msg":"Sample refresh complete"}'
    ;;
  *)
    printf '%s\n' '{"t":"error","msg":"Unknown template command"}'
    exit 2
    ;;
esac
