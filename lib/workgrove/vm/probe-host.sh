#!/usr/bin/env sh
# Report the VM hardware to the Mac.
# The Mac supplies version.sh before this script.
PATH="$HOME/.local/bin:$PATH"; export PATH
if [ -f "$HOME/.config/workgrove/env.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.config/workgrove/env.sh"
fi
printf 'probe_schema\t2\n'
version=$(wt_vm_version)
printf 'wt_version\t%s\n' "$version"
cpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
mem_kib=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
printf 'cpu\t%s\nmem_kib\t%s\n' "$cpu" "$mem_kib"
if command -v nvidia-smi >/dev/null 2>&1 &&
   gpu_rows=$(timeout -k 2 10 nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader,nounits 2>/dev/null); then
  printf 'gpu_status\tok\n'
  if [ -n "$gpu_rows" ]; then
    printf '%s\n' "$gpu_rows" | while IFS=, read -r index model vram; do
      printf 'gpu\t%s\t%s\t%s\n' "$index" "$model" "$vram"
    done
  fi
else
  # A failed nvidia-smi is not proof of absent hardware. A complete PCI scan with no
  # NVIDIA display device is; keep unknown if sysfs is missing or any entry is unreadable.
  gpu_status=unknown
  if [ -d /sys/bus/pci/devices ]; then
    pci_seen=0 pci_readable=1 nvidia_gpu=0
    for pci in /sys/bus/pci/devices/*; do
      [ -d "$pci" ] || continue
      pci_seen=1
      if [ ! -r "$pci/vendor" ] || [ ! -r "$pci/class" ] ||
         ! IFS= read -r vendor <"$pci/vendor" || ! IFS= read -r class <"$pci/class"; then
        pci_readable=0
        break
      fi
      case "$vendor:$class" in 0x10de:0x03*) nvidia_gpu=1 ;; esac
    done
    if [ "$pci_seen" -eq 1 ] && [ "$pci_readable" -eq 1 ] && [ "$nvidia_gpu" -eq 0 ]; then
      gpu_status=none
    fi
  fi
  printf 'gpu_status\t%s\n' "$gpu_status"
fi
