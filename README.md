# Anatomy of a Naive Linux Container Runtime

- [Anatomy of a Naive Linux Container Runtime](#anatomy-of-a-naive-linux-container-runtime)
  - [Introduction](#introduction)
  - [pivot\_root vs chroot](#pivot_root-vs-chroot)
  - [container runtime sequence](#container-runtime-sequence)
  - [rootfs](#rootfs)
    - [Download Alpine minirootfs](#download-alpine-minirootfs)
  - [Build \& Run](#build--run)
  - [TEST cgroups limits](#test-cgroups-limits)
  - [TODO](#todo)
    - [rootless (WIP)](#rootless-wip)
  - [Why Zig?](#why-zig)
    - [Go's re-exec problem](#gos-re-exec-problem)
    - [crun](#crun)
    - [Zig](#zig)
  - [Sources](#sources)


## Introduction

Recent lab exercises @hogent triggered my curiosity.  I know that containers run isolated, but differently than by virtualizing hardware.  They share resources with the host and are more lightweight than virtual machines.  The filesystem of a container is layered with overlayfs, at least for Docker (OverlayFS / overlayfs2).  That's pretty much it.  Pretty vague.

After looking around a bit, I came to understand that it's a matter of a handful of kernel features: cgroups, namespaces, unshare, pivot_root, ...

- cgroups ([linux control groups](https://man7.org/linux/man-pages/man7/cgroups.7.html)): handling resources and limits
- namespaces ([linux namespaces](https://man7.org/linux/man-pages/man7/namespaces.7.html)) with CLONE flags: this manage the isolation
- pivot_root ([change the root filesystem](https://man7.org/linux/man-pages/man8/pivot_root.8.html)): swap container's root filesystem
- unshare ([run program in new namespaces](https://man7.org/linux/man-pages/man1/unshare.1.html))

_the gist of it_ (with only new pid and /proc remount, no separate rootfs)

```bash
$ nix-shell -p util-linux --run "sudo unshare --fork --pid --mount-proc bash"
warning: $HOME ('/home/jeroen') is not owned by you, falling back to the one defined in the 'passwd' file ('/root')
warning: Nix search path entry '/nix/var/nix/profiles/per-user/root/channels' does not exist, ignoring

[root@nixos:/home/jeroen/projects/mini-container]# ps aux
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root           1  0.0  0.0   9328  5600 pts/10   S    20:13   0:00 bash
root           5  0.0  0.0  10496  3984 pts/10   R+   20:16   0:00 ps aux

[root@nixos:/home/jeroen/projects/mini-container]#
```

In the process, I also discovered Talos for Kubernetes.  That's for another time.


## pivot_root vs chroot
`chroot` only changes the process's path resolution root. The kernel just says "when this process resolves /, start from this directory instead." But the process's actual mount namespace is untouched -- the old root filesystem is still fully mounted and accessible. A privileged process can escape by using `fchdir` on a file descriptor opened before the chroot, or by creating a new mount namespace, or even by doing a second chroot with relative paths. It was never designed as a security boundary -- it was designed for system recovery and building packages.  This is what we use when we install linux.

`pivot_root` actually changes which mount is at the root of the mount namespace. It swaps the current root mount with a new one and moves the old root to a specified mountpoint. After that, you can (and should) unmount the old root entirely. Once it's unmounted, there's nothing to escape back to -- the old filesystem is simply gone from the namespace. This is why container runtimes use it.

`chroot` is cosmetic where `pivot_root` is structural

## container runtime sequence

The typical sequence a container runtime follows looks roughly like this:

1. Set up the overlayfs (stack the image layers, add writable upper layer)
2. Create a cgroup and set resource limits (memory, CPU, ...)
3. Move the parent into the sub-cgroup so CLONE_NEWCGROUP roots correctly
4. clone() with CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWCGROUP | ...
5. Parent moves itself back to root cgroup (only child stays constrained)
6. In the child: mount /proc, /sys, /dev, cgroup2 inside the new rootfs
7. pivot_root to the new rootfs, unmount the old root
8. Drop capabilities, set seccomp filters for syscall filtering
9. exec the container's entrypoint


## rootfs

### Download Alpine minirootfs

We want a separate and new filesystem, isolated from the host filesystem.  For demonstration purposes, we also want a linux distribution with a package manager.  Alpine is known for its minimal size. `musl` vs `glibc`, but it'll do.

```bash
curl -fSL -o alpine-minirootfs.tar.gz \
  https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.3-aarch64.tar.gz

mkdir -p rootfs
sudo tar -xzf alpine-minirootfs.tar.gz -C rootfs
echo "nameserver 8.8.8.8" | sudo tee rootfs/etc/resolv.conf
```

For x86_64 my NixOS (aarch64) has binfmt_misc configured with QEMU user-mode emulation. When the kernel sees an x86_64 ELF binary, it transparently invokes qemu-x86_64 to translate the instructions at runtime. 

```bash
$ grep emulatedSystems /etc/nixos -R
/etc/nixos/configuration.nix:  boot.binfmt.emulatedSystems = [ "x86_64-linux" ];
```

```bash
curl -fSL -o alpine-minirootfs.tar.gz \
  https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-minirootfs-3.21.3-x86_64.tar.gz

mkdir -p rootfs
sudo tar -xzf alpine-minirootfs.tar.gz -C rootfs

# set up DNS inside the container
echo "nameserver 8.8.8.8" | sudo tee rootfs/etc/resolv.conf
```

## Build & Run

build

```bash
$ zig build -Doptimize=ReleaseSmall --summary all

Build Summary: 3/3 steps succeeded
install success
└─ install container success
   └─ compile exe container ReleaseSmall native success 417ms MaxRSS:129M

```


run

```bash
$ sudo zig-out/bin/container ./rootfs 134217728 /bin/sh
```

aarch64 / arm64

<img src="img/alpine-container-aarch64.png" width="1000" alt="install apk"> 

x86_64

<img src="img/alpine-container.png" width="1000" alt="install apk"> 


## TEST cgroups limits

Run the container with 128MiB and write 50MiB blocks to tmpfs (in-memory).  We expect it to OOM at the 3rd block.


```bash
$ sudo zig-out/bin/container ./rootfs 134217728 /bin/sh
╔══════════════════════════════════════════╗
║        mini-container starting...        ║
╠══════════════════════════════════════════╣
║  rootfs:                        ./rootfs ║
║  mem limit:  134217728 bytes║
║  command:                        /bin/sh ║
╚══════════════════════════════════════════╝
[parent] cgroup: /sys/fs/cgroup/mini-container-184769 (mem limit 134217728 bytes)
[child]  setting up container
[parent] child PID in host namespace: 184770
[child]  mounts set up, pivoted into new rootfs
[child]  executing command
/ # while true; do cat /sys/fs/cgroup/memory.current; head -c 52428800 /dev/zero | cat >> /tmp/balloon; sleep 0.2; done
75874304
95780864
Killed
100433920
Killed
133398528
[parent] child terminated abnormally
```

```bash
$ dmesg | tail -n 2
[38505.055786] oom-kill:constraint=CONSTRAINT_MEMCG,nodemask=(null),cpuset=mini-container-184255,mems_allowed=0,oom_memcg=/mini-container-184255,task_memcg=/mini-container-184255,task=sh,pid=184256,uid=0
[38505.055794] Memory cgroup out of memory: Killed process 184256 (sh) total-vm:155376kB, anon-rss:3504kB, file-rss:3216kB, shmem-rss:0kB, UID:0 pgtables:112kB oom_score_adj:0
$
```


## TODO

- [ ] overlay2
- [ ] rootless
- [ ] ...


### rootless (WIP)

Almost everything the container does requires root (CAP_SYS_ADMIN):

- clone() with CLONE_NEWPID, CLONE_NEWNS, CLONE_NEWNET, CLONE_NEWIPC -- all need root
- mount(), pivot_root() -- need root
- mknod() for /dev/null etc. -- needs root
- Writing to /sys/fs/cgroup -- needs root

The escape hatch is CLONE_NEWUSER. This is how rootless Podman and rootless Docker work. A user namespace lets an unprivileged UID become UID 0 inside the container. Once it's "root" inside a user namespace, the kernel grants it capabilities for the other namespace operations (mount, pivot_root, etc.) -- but only within that namespace. It can't actually touch host resources.

We need to add:

1. Add CLONE_NEWUSER to the clone flags
After clone, write uid/gid mappings from the parent:

/proc/<child_pid>/uid_map  ->  "0 1000 1"   (container root = host uid 1000)
/proc/<child_pid>/gid_map  ->  "0 1000 1"

2. Write "deny" to /proc/<child_pid>/setgroups first (kernel requirement)

The tricky part is synchronization -- the child has to wait until the parent has written the mappings before it calls mount() or pivot_root(). We'd typically use a pipe: child blocks on read(), parent writes the mappings then closes the pipe, child proceeds.

To be continued ...


## Why Zig?

Most container runtimes are written in Go. Docker, containerd, runc, Podman's upper layers - all Go. This makes sense for the higher-level orchestration tooling, but for the low-level runtime that actually calls `clone()`, `setns()`, `pivot_root()`, and `execve()`, Go is an awkward fit. The reason comes down to one thing: Go is multi-threaded from the start, and Linux namespaces require single-threaded control.

To understand why, you need to know that Linux namespaces are a per-thread property, not per-process. Each thread in a process can belong to a different set of namespaces. The syscalls that manipulate namespaces - `clone()`, `unshare()`, `setns()` - only affect the -calling thread-. The kernel does this deliberately: threads are the actual schedulable entities (tasks), and a "process" in Linux is really just a group of threads that happen to share resources.

This design works perfectly when you have one thread: call `unshare(CLONE_NEWPID)` and your entire process is now in a new PID namespace. But when the Go runtime has already spawned 3-5 OS threads before your code even starts, that `unshare()` call only moves *one* of them. The rest stay in the old namespace. You now have a process that's half in the container and half out - an incoherent state that the kernel rightly rejects for certain operations (e.g., `CLONE_NEWUSER` from a multi-threaded process returns `EINVAL` - [invalid argument](https://man7.org/linux/man-pages/man3/errno.3.html)).

### Go's re-exec problem

When a Go program starts, the runtime immediately spawns multiple OS threads for the garbage collector, the network poller, goroutine scheduling, etc. By the time `main()` runs, you already have several threads. This is a problem because:

- `clone(CLONE_NEWPID)` only puts the calling thread into the new PID namespace. The other Go runtime threads remain in the old namespace.
- `setns()` to join a mount or PID namespace only affects the calling thread. The other threads still see the old namespace.
- `unshare(CLONE_NEWUSER)` from a multi-threaded process fails with `EINVAL` on many kernel versions.

The kernel fundamentally expects namespace transitions to happen in a single-threaded context. Go violates this assumption by design.

**runc's workaround: the nsexec hack.** runc solves this by embedding a C function (`nsexec()`) that runs via a cgo constructor - `__attribute__((constructor))` - which means it executes *before* the Go runtime boots and starts its threads. But to trigger this constructor, runc has to re-exec itself: the parent process fork/execs `/proc/self/exe` (itself), and the re-launched copy runs the C constructor in a single-threaded state, does the namespace setup, and only then lets Go take over. This is the "re-exec" pattern.

The result is ~1200 lines of carefully-written C ([nsexec.c](https://github.com/opencontainers/runc/blob/main/libcontainer/nsenter/nsexec.c)) that bootstraps the namespace environment before Go can interfere, parent/child communication over pipes, and multiple fork stages just to work around the language runtime. As the runc developers themselves document: "nsexec must be run before the Go runtime in order to use the Linux kernel namespace."

### crun

[crun](https://github.com/containers/crun) is an OCI-compliant container runtime written entirely in C by Giuseppe Scrivano (Red Hat). It exists precisely because of Go's limitations in this space. From crun's own README:

> "While most of the tools used in the Linux containers ecosystem are written in Go, I believe C is a better fit for a lower level tool like a container runtime. runc, the most used implementation of the OCI runtime specs written in Go, re-execs itself and uses a module written in C for setting up the environment before the container process starts."

The results speak for themselves: crun is ~2x faster than runc for container startup and uses drastically less memory - it can run containers with as little as 512KB of memory, while runc fails under 4MB because the Go runtime itself needs that much just to exist.


### Zig

I discovered zig at v0.10.  Early stages, immature, but functional and very promising.  Fairly easy to get started.  I did Advent of Code 2021 as a learning zig project and had started a refresh-project of the cool xymon monitoring tool in zig, but abandoned it because of breaking changes, moving target.

At the time of this writing, we're at v0.15.2 and nearing the first production release.  So I wanted to give it another go.  At the same time, I'm trying out claude.ai to give me a hand with picking it back up and even though it struggles with zig because of its small user base and available zig projects, it's better than a few years ago.  However, it's still pre-1.0 and the ecosystem is small. For a project whose entire purpose is to make syscalls in the right order, that hardly matters. We don't need a web framework or an ORM - we need `clone()` and `pivot_root()`, and Zig gives us those with less ceremony than any alternative.

Zig sits in a sweet spot for this use case:

- **No runtime threads.** When `main()` starts, there's one thread. Period. We can call `clone()` directly and know exactly what happens - the child gets a copy of our single-threaded address space. No re-exec trick needed.
- **Direct syscall access.** `std.os.linux` exposes raw syscalls. We call `clone()`, `mount()`, `pivot_root()`, `execve()` directly - same as C, but with bounds-checked slices and a real type system.
- **No hidden allocations.** After `clone()`, we avoid the allocator entirely and use only stack buffers and raw syscalls. In Go you can't avoid GC; in Zig you have full control.
- **Single-file build.** `zig build` - no CMakeLists.txt, no configure scripts, no pkg-config. Cross-compilation to aarch64 is `zig build -Dtarget=aarch64-linux`.
- **Readable.** The entire runtime is one ~500 line file. Someone reading it can follow the exact sequence of syscalls without navigating cgo constructors, re-exec pipes, or fork stages.


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
- [runc nsenter - C bootstrapper that runs before Go's runtime](https://github.com/opencontainers/runc/blob/main/libcontainer/nsenter/README.md)
- [runc nsexec.c - the 1200-line C workaround for Go's threading](https://github.com/opencontainers/runc/blob/main/libcontainer/nsenter/nsexec.c)
- [crun - OCI runtime in C, created because Go is a poor fit](https://github.com/containers/crun)
- [youki - OCI runtime in Rust](https://github.com/containers/youki)
- [Namespaces in Go - reexec (Ed King)](https://medium.com/@teddyking/namespaces-in-go-reexec-3d1295b91af8)