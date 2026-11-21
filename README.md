# amd-devcloud-toolkit

Helpers for evaluating an AMD Developer Cloud (MI300X) GPU droplet before committing a training run.

## Why this exists

GPU droplets are billed by the hour, and a 100 GB checkpoint has to go somewhere before the droplet is destroyed. Two things decide whether a workload is viable on rented GPU time:

- how fast the box can **pull** models and datasets (HuggingFace vs ModelScope)
- how fast it can **push** checkpoints out, and to which storage backend

`net_bench.sh` measures both in one pass, so the storage decision is based on measured throughput instead of guesses.

## What it measures

| Target | Direction | Notes |
|---|---|---|
| HuggingFace Hub | download + upload | upload optional, needs `HF_TOKEN` |
| ModelScope | download + upload | upload optional, needs `MODELSCOPE_TOKEN` |
| DigitalOcean Spaces | upload | S3 API via `rclone` |
| all three | RTT | TCP connect time |

Every result is printed as MB/s plus the estimated time to move a 100 GB checkpoint.

## Usage

```bash
git clone https://github.com/chenyuheng58/amd-devcloud-toolkit
cd amd-devcloud-toolkit
chmod +x net_bench.sh
./net_bench.sh          # download + latency only
```

With upload targets:

```bash
export S3_ACCESS_KEY=... S3_SECRET_KEY=... \
       S3_ENDPOINT=https://sfo3.digitaloceanspaces.com S3_BUCKET=my-bucket
export HF_TOKEN=hf_xxx
./net_bench.sh
```

## Notes

- writes a 200 MB random file to `/tmp` and removes it afterwards; set `SIZE_MB` to change the size
- credentials are read from environment variables only, never written to disk
- needs `curl`, `dd`, `awk`; `rclone`, `huggingface_hub` and `modelscope` are optional

## Status

Early. Exercised on a CUDA box; the MI300X / ROCm run is pending GPU access approval.
