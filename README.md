# Anatomy of a Contianer Runtime

- [Anatomy of a Contianer Runtime](#anatomy-of-a-contianer-runtime)
  - [Introduction](#introduction)
  - [rootfs](#rootfs)
    - [Download Alpine minirootfs](#download-alpine-minirootfs)
  - [Build \& Run](#build--run)
  - [Sources](#sources)


## Introduction

Recent lab exercises @hogent triggered my curiosity.  I know containers run isolated.  They share resources with the host and are more lightweight than virtual machines.  The filesystem of a container is layered with overlayfs, at least docker.

In the process, I discovered Talos for Kubernetes.  That's for another time.

I quickly understood that it's a matter of a handful of kernel features: cgroups, namespaces, unshare, ...





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



## Sources

- [Talos - The Kubernetes Operating System](https://www.talos.dev/)
- [Portainer on Talos with Kubernetes](https://docs.portainer.io/admin/environments/add/kube-create/omni)
- [The State of Immutable Linux](https://youtu.be/jvdPuTcdGXs?si=dDtiQstHnhKKlgYq)
- [Kubernetes Components - An Overview](https://kubernetes.io/docs/concepts/overview/components/)
- [OrbStack vs Apple Containers vs Docker on macOS: How They Really Differ Under the Hood](https://dev.to/tuliopc23/orbstack-vs-apple-containers-vs-docker-on-macos-how-they-really-differ-under-the-hood-53fj)
- [Ene cursus over Operating Systems](https://hogenttin.github.io/operating-systems/npe/)
- [What even is a container: namespaces and cgroups](https://jvns.ca/blog/2016/10/10/what-even-is-a-container/)
- [A Forking Server](<https://www2.lawrence.edu/fast/GREGGJ/CMSC480/process/forking.html#:~:text=Calling%20fork()%20in%20a,is%20called%20the%20child%20process.>)
- [Fork](https://man7.org/linux/man-pages/man2/fork.2.html)
- [Build a Container from Scratch in Go (Modern Namespaces + cgroup v2)](https://dev.to/faizanfirdousi/build-a-container-from-scratch-in-go-modern-namespaces-cgroup-v2-5556)
- [unshare](https://man7.org/linux/man-pages/man1/unshare.1.html)
- [bubblewrap](https://github.com/containers/bubblewrap)