#!/bin/bash
# End-to-end test against real VMs, in a throwaway ALTVM_HOME (your library is never touched).
# The OS image cache is shared with your real library so the 3 GB Debian image downloads once.
#   ./scripts/e2e.sh            (uses dist/avm; run ./scripts/build.sh first)
set -uo pipefail
cd "$(dirname "$0")/.."
A="${AVM:-$PWD/dist/avm}"
export ALTVM_HOME="$(mktemp -d /tmp/altvm-e2e.XXXXXX)"
REAL_CACHE="$HOME/Library/Application Support/AltVM/Cache"
mkdir -p "$REAL_CACHE" && ln -s "$REAL_CACHE" "$ALTVM_HOME/Cache"
PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
check(){ if ( eval "$2" ) >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
wait_agent() { for _ in $(seq 1 60); do "$A" exec "$1" --timeout 5 -- true >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
cleanup() {
  for v in $("$A" list --json 2>/dev/null | python3 -c 'import json,sys;[print(v["name"]) for v in json.load(sys.stdin)]'); do "$A" stop "$v" --force >/dev/null 2>&1; done
  pkill -f "avm switch run e2e" 2>/dev/null
  rm -rf "${ALTVM_HOME:?}"
}
trap cleanup EXIT

echo "== create (catalog, unattended cloud-init)"
check "create + boot + agent ready" "'$A' create e1 --catalog debian-13 --cpus 2 --memory 2G --disk 16 --start"
check "exec + exit code" "[ \"\$('$A' exec e1 -- sh -c 'exit 3'; echo \$?)\" = 3 ]"
check "stdin forwarding (-i)" "[ \"\$(echo hi | '$A' exec e1 -i -- cat)\" = hi ]"
check "Mac folders mounted (virtiofs)" "'$A' exec e1 -- mountpoint -q /mnt/mac"
check "Rosetta binfmt registered" "'$A' exec e1 -- test -e /proc/sys/fs/binfmt_misc/rosetta"
check "FastBoot kernel synced" "for i in \$(seq 1 30); do grep -q fastBootKernel '$ALTVM_HOME/VMs/e1.altvm/spec.json' && exit 0; sleep 2; done; exit 1"

echo "== lifecycle"
"$A" stop e1 >/dev/null; "$A" start e1 >/dev/null; wait_agent e1
check "FastBoot boot" "'$A' exec e1 -- grep -q console=hvc0 /proc/cmdline"
"$A" exec e1 -- sh -c 'nohup sleep 99999 >/dev/null 2>&1 & echo $! > /root/p' >/dev/null
"$A" suspend e1 >/dev/null; "$A" start e1 >/dev/null
check "suspend/resume keeps processes" "'$A' exec e1 -- sh -c 'kill -0 \$(cat /root/p)'"
check "resume did not cold boot" "! grep -qi 'could not be restored' '$ALTVM_HOME/VMs/e1.altvm/run.log'"
sleep 2
check "guest clock resynced" "[ \$(( \$(date +%s) - \$('$A' exec e1 -- date +%s) )) -lt 5 ]"

echo "== snapshots & clones"
"$A" exec e1 -- sh -c 'echo A > /root/m; sync' >/dev/null
check "live snapshot" "'$A' snapshot create e1 snapA"
"$A" exec e1 -- sh -c 'echo B > /root/m; sync' >/dev/null
"$A" stop e1 --force >/dev/null; "$A" snapshot restore e1 snapA >/dev/null; "$A" start e1 >/dev/null; wait_agent e1
check "restore brings back disk + RAM" "[ \"\$('$A' exec e1 -- cat /root/m)\" = A ] && '$A' exec e1 -- sh -c 'kill -0 \$(cat /root/p)'"
"$A" stop e1 >/dev/null
check "CoW clone" "'$A' clone e1 e2"

echo "== networking"
"$A" switch create e2e --subnet 10.77.99 >/dev/null
"$A" set e1 switch=e2e >/dev/null; "$A" set e2 switch=e2e >/dev/null
"$A" start e1 >/dev/null; "$A" start e2 >/dev/null; wait_agent e1; wait_agent e2; sleep 3
IP2=$("$A" exec e2 -- sh -c "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1" | head -1)
check "DHCP lease on virtual switch" "[[ '$IP2' == 10.77.99.* ]]"
check "VM-to-VM ping" "'$A' exec e1 -- ping -c 2 -W 2 $IP2"
"$A" switch set e2e --latency 40 >/dev/null; sleep 2
RTT=$("$A" exec e1 -- ping -c 3 -q "$IP2" | awk -F/ '/rtt/{print int($5)}')
check "latency conditioning (rtt ${RTT}ms ≥ 75)" "[ '${RTT:-0}' -ge 75 ]"
"$A" stop e2 --force >/dev/null

echo "== enterprise"
K="$ALTVM_HOME/keys"; mkdir -p "$K"
"$A" keys generate it --dir "$K" --trust >/dev/null
"$A" stop e1 >/dev/null
check "signed image pack" "'$A' image pack e1 '$K/gold.avmimg' --sign '$K/it.key' --version 1"
check "image deploy" "'$A' image deploy '$K/gold.avmimg' e3"
python3 -c "f=open('$K/gold.avmimg','r+b');f.seek(4000);b=f.read(1);f.seek(4000);f.write(bytes([b[0]^255]))"
check "tampered image refused" "! '$A' image deploy '$K/gold.avmimg' evil"
"$A" policy init Acme | python3 -c 'import json,sys; p=json.load(sys.stdin); p["allowMicrophone"]=False; print(json.dumps(p))' > "$K/p.json"
check "policy sign + install" "'$A' policy sign '$K/p.json' --key '$K/it.key' > '$K/p.signed' && '$A' policy install '$K/p.signed'"
check "policy blocks microphone" "! '$A' set e3 mic=on"
check "audit chain intact" "'$A' audit verify"
sed -i '' '3s/"event":"[^"]*"/"event":"forged"/' "$ALTVM_HOME/audit.jsonl"
check "audit tamper detected" "! '$A' audit verify"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
