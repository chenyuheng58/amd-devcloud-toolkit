#!/usr/bin/env bash
# net_bench.sh - measure download/upload throughput from an AMD Developer Cloud GPU droplet
#
# Why: GPU time is billed hourly, so it matters whether checkpoint uploads go to
# object storage in the same region (fast) or across the Pacific to a repo in China (slow).
# This script prints MB/s and the estimated time to move a 100 GB checkpoint for each target.
#
# Usage:
#   chmod +x net_bench.sh
#   export HF_TOKEN=hf_xxx                       # optional: test HuggingFace upload
#   export MODELSCOPE_TOKEN=xxx                  # optional: test ModelScope upload
#   export S3_ACCESS_KEY=xxx S3_SECRET_KEY=xxx \
#          S3_ENDPOINT=https://sfo3.digitaloceanspaces.com S3_BUCKET=your-bucket
#   ./net_bench.sh
#
# Requirements: curl, awk, dd. Optional: rclone (Spaces), huggingface_hub, modelscope.

set -u
SIZE_MB=${SIZE_MB:-200}
TMP=/tmp/nb_${SIZE_MB}m.bin
PASS=0
FAIL=0

say() { printf "\n== %s ==\n" "$*"; }
ok()  { printf "  [ok] %s\n" "$*"; PASS=$((PASS+1)); }
bad() { printf "  [fail] %s\n" "$*"; FAIL=$((FAIL+1)); }

rate() {
  awk -v s="$1" -v m="$2" 'BEGIN{
    if (s<=0) { print "  n/a"; exit }
    r=m/s; h=(102400/r)/3600;
    printf "  %.2f MB/s  |  100GB would take %.1f h\n", r, h
  }'
}

say "0. environment"
echo "  host: $(hostname)  public ip: $(curl -s --max-time 8 https://ifconfig.me || echo unknown)"
echo "  creating ${SIZE_MB}MB test file"
dd if=/dev/urandom of="$TMP" bs=1M count="$SIZE_MB" status=none && ok "test file ready" || { bad "dd failed"; exit 1; }

say "1. download throughput (pulling models/datasets)"
t=$( { /usr/bin/time -f "%e" curl -sL --max-time 120 -o /dev/null \
     "https://huggingface.co/openai-community/gpt2/resolve/main/pytorch_model.bin"; } 2>&1 | tail -1 )
if [ -n "${t:-}" ] && awk -v x="$t" 'BEGIN{exit !(x>0)}'; then
  ok "HuggingFace ${t}s"; rate "$t" 548
else bad "HuggingFace download failed"; fi

t=$( { /usr/bin/time -f "%e" curl -sL --max-time 120 -o /dev/null \
     "https://modelscope.cn/models/qwen/Qwen2.5-0.5B-Instruct/resolve/master/model.safetensors"; } 2>&1 | tail -1 )
if [ -n "${t:-}" ] && awk -v x="$t" 'BEGIN{exit !(x>0)}'; then
  ok "ModelScope ${t}s"; rate "$t" 988
else bad "ModelScope download failed/timeout"; fi

say "2. upload throughput (writing checkpoints)"

if [ -n "${S3_ENDPOINT:-}" ] && [ -n "${S3_BUCKET:-}" ] && command -v rclone >/dev/null; then
  export RCLONE_CONFIG_SPACES_TYPE=s3
  export RCLONE_CONFIG_SPACES_PROVIDER=DigitalOcean
  export RCLONE_CONFIG_SPACES_ACCESS_KEY_ID="$S3_ACCESS_KEY"
  export RCLONE_CONFIG_SPACES_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
  export RCLONE_CONFIG_SPACES_ENDPOINT="$S3_ENDPOINT"
  start=$(date +%s)
  if rclone copy "$TMP" "spaces:${S3_BUCKET}/_bench/" --s3-chunk-size 64M --transfers 1 -q; then
    el=$(( $(date +%s) - start )); ok "Spaces(same region) ${el}s"; rate "$el" "$SIZE_MB"
  else bad "Spaces upload failed"; fi
else
  echo "  - skipped: set S3_* env vars and install rclone"
fi

if [ -n "${HF_TOKEN:-}" ] && command -v huggingface-cli >/dev/null; then
  start=$(date +%s)
  if huggingface-cli upload "${HF_REPO:-your-name/bench-tmp}" "$TMP" "_bench/$(basename "$TMP")" \
       --repo-type dataset --token "$HF_TOKEN" >/dev/null 2>&1; then
    el=$(( $(date +%s) - start )); ok "HuggingFace ${el}s"; rate "$el" "$SIZE_MB"
  else bad "HuggingFace upload failed"; fi
else
  echo "  - skipped: set HF_TOKEN and pip install huggingface_hub"
fi

say "3. round-trip latency"
for h in huggingface.co modelscope.cn sfo3.digitaloceanspaces.com; do
  c=$(curl -s -o /dev/null -w "%{time_connect}" --max-time 10 "https://$h" 2>/dev/null || echo "")
  if [ -n "$c" ]; then printf "  %-32s %.0f ms\n" "$h" "$(awk -v x="$c" 'BEGIN{print x*1000}')"; else printf "  %-32s unreachable\n" "$h"; fi
done

rm -f "$TMP"
say "done: $PASS passed, $FAIL failed"
echo "pick the highest throughput as your checkpoint primary, use a second one as off-site backup"
