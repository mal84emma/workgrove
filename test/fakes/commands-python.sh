#!/usr/bin/env bash
# Model command identities for synthetic PIDs; real process tests use the actual helper.
set -euo pipefail
args=("$@")
for ((position=0;position<${#args[@]};position++)); do
  case ${args[position]} in
    */lib/workgrove/commands.py)
      "$COMMANDS_REAL_PYTHON" -I -B -c '
import json,sys
operation,*args=sys.argv[1:]
if operation == "probe":sys.exit(0)
generation=args[0];data=json.load(sys.stdin)
if operation == "capture":
 pid=int(args[1]);assert pid>1 and args[2] and int(args[3])>1
 birth="bsd:1:1" if sys.platform=="darwin" else "ticks:1"
 print(json.dumps(dict(version=1,generation=generation,boot="00000000-0000-0000-0000-000000000001",platform=sys.platform,
  records=[dict(pid=pid,birth=birth,comm="fixture-provider",role="runtime")])))
else:
 assert operation in ("stop","observe","validate") and data["generation"]==generation and data["records"]
' "${args[@]:position+1}"
      exit ;;
  esac
done
exec "$COMMANDS_REAL_PYTHON" "$@"
