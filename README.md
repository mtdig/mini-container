# Anatomy of a Contianer Runtime

## rootfs

### Download Alpine minirootfs

```bash
curl -fSL -o alpine-minirootfs.tar.gz \
  https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-minirootfs-3.21.3-x86_64.tar.gz

mkdir -p rootfs
sudo tar -xzf alpine-minirootfs.tar.gz -C rootfs

# set up DNS inside the container
echo "nameserver 8.8.8.8" | sudo tee rootfs/etc/resolv.conf
```

## Build & Run

sudo zig build run -- ./rootfs 67108864 /bin/sh