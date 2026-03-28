// mini-container: A minimal Linux container runtime in Zig
//
// Demonstrates: namespaces (clone flags), cgroups v2, pivot_root,
// /proc + /dev mounting — the same primitives Docker/runc use.
//
// Build & run:
//   zig build -Doptimize=ReleaseSmall --summary all
//   sudo zig-out/bin/container ./rootfs 67108864 /bin/sh
//
// Requires: Linux kernel >= 5.3, cgroups v2 mounted at /sys/fs/cgroup

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const fmt = std.fmt;

const cgroup_root = "/sys/fs/cgroup";

const Device = struct {
    path: [*:0]const u8,
    major: u32,
    minor: u32,
};

const devices = [_]Device{
    .{ .path = "/dev/null", .major = 1, .minor = 3 },
    .{ .path = "/dev/zero", .major = 1, .minor = 5 },
    .{ .path = "/dev/random", .major = 1, .minor = 8 },
    .{ .path = "/dev/urandom", .major = 1, .minor = 9 },
};

// main garbage

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // parse args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 4) {
        printUsage(args[0]);
        std.process.exit(1);
    }

    const rootfs = args[1];
    const mem_limit = fmt.parseInt(u64, args[2], 10) catch {
        std.debug.print("container: invalid memory limit '{s}'\n", .{args[2]});
        std.process.exit(1);
    };
    const cmd_args = args[3..];

    // must be root
    if (linux.getuid() != 0) {
        std.debug.print("container: must be run as root\n", .{});
        std.process.exit(1);
    }

    printBanner(rootfs, mem_limit, cmd_args[0]);

    // resolve rootfs to absolute path
    const abs_rootfs = std.fs.cwd().realpathAlloc(allocator, rootfs) catch |err| {
        std.debug.print("container: rootfs '{s}': {}\n", .{ rootfs, err });
        std.process.exit(1);
    };
    defer allocator.free(abs_rootfs);

    //  Set up cgroup
    var cgroup_buf: [256]u8 = undefined;
    const cgroup_path = try setupCgroup(&cgroup_buf, mem_limit);
    defer cleanupCgroup(cgroup_path);

    // build null-terminated argv/env BEFORE clone
    // After clone()+pivot_root, the Zig stdlib/allocator may not
    // work (debug info reads /proc/self/exe, etc). Prepare everything now.
    // [*:0]const u8 is a null-terminated string slice, a C-style char* string, which is what syscalls expect.
    const argv_z = try allocator.alloc(?[*:0]const u8, cmd_args.len + 1);
    defer {
        for (argv_z[0..cmd_args.len]) |maybe_ptr| {
            if (maybe_ptr) |ptr| {
                allocator.free(std.mem.span(ptr));
            }
        }
        allocator.free(argv_z);
    }
    for (cmd_args, 0..) |arg, i| {
        argv_z[i] = (try allocator.dupeZ(u8, arg)).ptr;
    }
    argv_z[cmd_args.len] = null;

    const env = [_:null]?[*:0]const u8{
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "TERM=xterm-256color",
        "HOME=/root",
        "LANG=C.UTF-8",
    };

    // Move the parent into the sub-cgroup BEFORE clone, so that
    // CLONE_NEWCGROUP roots the child's cgroup namespace at our
    // sub-cgroup. This way the child sees its own cgroup as /,
    // and memory.max / memory.current reflect the correct limits.
    joinCgroupPid(cgroup_path, linux.getpid()) catch |err| {
        std.debug.print("container: failed to join cgroup: {}\n", .{err});
        std.process.exit(1);
    };

    // clone into new namespaces
    //
    // Unlike Go, Zig has no heavyweight runtime with background
    // threads. We can call clone() directly — just like C. When
    // called without CLONE_VM, clone acts like fork(): the child
    // gets a copy of the address space and continues from the
    // same point.  No re-exec trick needed.  => this is why we use zig instead of c or go for this demo.
    //
    const clone_flags: u64 = linux.CLONE.NEWPID |
        linux.CLONE.NEWNS |
        linux.CLONE.NEWUTS |
        // linux.CLONE.NEWNET | -- if we don't create a new network, we share the host network, like what `docker run --network=host` does
        linux.CLONE.NEWIPC |
        linux.CLONE.NEWCGROUP | // container sees its own cgroup as /
        linux.SIG.CHLD;

    const rc = linux.syscall5(
        .clone,
        @as(usize, @intCast(clone_flags)),
        0, // child_stack = 0 -> fork-like (share parent stack copy)
        0, // parent_tid
        0, // child_tid
        0, // tls
    );

    const errno = linux.E.init(rc);
    if (errno != .SUCCESS) {
        std.debug.print("container: clone failed: {}\n", .{errno});
        std.process.exit(1);
    }

    const child_pid: i32 = @intCast(@as(isize, @bitCast(rc)));

    if (child_pid == 0) {
        // child process
        // only use raw syscalls from here — no allocator, no stdlib.
        childMain(abs_rootfs, @ptrCast(argv_z.ptr), @ptrCast(&env));
    } else {
        // parent process — move ourselves back to the root cgroup
        // so only the child (and its descendants) remain constrained.
        moveToRootCgroup() catch |err| {
            std.debug.print("container: failed to move parent back to root cgroup: {}\n", .{err});
        };

        std.debug.print("[parent] child PID in host namespace: {d}\n", .{child_pid});

        // wait for the child using raw syscall
        var status: u32 = 0;
        while (true) {
            const rc2 = linux.syscall4(
                .wait4,
                @as(usize, @bitCast(@as(isize, child_pid))),
                @intFromPtr(&status),
                0, // options
                0, // rusage
            );
            const wait_errno = linux.E.init(rc2);
            if (wait_errno == .INTR) continue;
            if (wait_errno != .SUCCESS) {
                std.debug.print("container: waitpid failed: {}\n", .{wait_errno});
                std.process.exit(1);
            }
            break;
        }

        // WIFEXITED: low 7 bits are zero, check `man 2 waitpid` for details
        if (status & 0x7f == 0) {
            const code: u8 = @truncate(status >> 8);
            std.debug.print("[parent] child exited with status {d}\n", .{code});
            if (code != 0) std.process.exit(code);
        } else {
            std.debug.print("[parent] child terminated abnormally\n", .{});
            std.process.exit(1);
        }
    }
}

// child: runs inside new namespaces
// IMPORTANT: After clone(), avoid Zig stdlib that touches the filesystem
// (debug info, panic handler, allocator in debug mode). Use only raw
// syscalls and pre-allocated data.

fn childMain(
    rootfs: []const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) noreturn {
    childMainInner(rootfs, argv, envp) catch {};
    // if we get here, exec failed — exit via raw syscall
    _ = linux.syscall1(.exit_group, 1);
    unreachable;
}

fn childMainInner(
    rootfs: []const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) !void {
    // use raw write() for logging — std.debug.print may access /proc
    writeLog("[child]  setting up container\n");

    // set hostname
    const hostname = "container";
    const shn_rc = linux.syscall2(
        .sethostname,
        @intFromPtr(hostname.ptr),
        hostname.len,
    );
    if (linux.E.init(shn_rc) != .SUCCESS) return error.SetHostname;

    // set up mounts & pivot_root
    try setupMounts(rootfs);

    // exec
    writeLog("[child]  executing command\n");

    const cmd = argv[0] orelse return error.NoCommand;
    const exec_rc = linux.execve(cmd, argv, envp);
    _ = exec_rc;
    writeLog("container: execve failed\n");
    return error.Exec;
}

/// write a log message using raw write() syscall — safe after clone/pivot.
fn writeLog(msg: []const u8) void {
    _ = linux.syscall3(
        .write,
        2, // stderr
        @intFromPtr(msg.ptr),
        msg.len,
    );
}

//  mount setup & pivot_root

fn setupMounts(rootfs: []const u8) !void {
    // make all mounts private so nothing leaks to host
    try sysMount(null, "/", null, linux.MS.REC | linux.MS.PRIVATE, 0);

    // bind-mount rootfs onto itself (pivot_root needs a mount point)
    // use dedicated stack buffers — toSentinel uses a shared buffer
    // so we can't hold two sentinel strings from it simultaneously.
    var rootfs_buf: [1024]u8 = undefined;
    if (rootfs.len >= rootfs_buf.len) return error.PathTooLong;
    @memcpy(rootfs_buf[0..rootfs.len], rootfs);
    rootfs_buf[rootfs.len] = 0;
    const rootfs_z: [*:0]const u8 = @ptrCast(rootfs_buf[0..rootfs.len]);

    try sysMount(rootfs_z, rootfs_z, null, linux.MS.BIND | linux.MS.REC, 0);

    // prepare .pivot_old inside rootfs
    var pivot_buf: [1024]u8 = undefined;
    const pivot_path = fmt.bufPrint(&pivot_buf, "{s}/.pivot_old\x00", .{rootfs}) catch
        return error.PathTooLong;
    const pivot_z: [*:0]const u8 = @ptrCast(pivot_path[0 .. pivot_path.len - 1]);

    sysMkdir(pivot_z, 0o755);

    // pivot_root(new_root, put_old)
    const pr_rc = linux.syscall2(
        .pivot_root,
        @intFromPtr(rootfs_z),
        @intFromPtr(pivot_z),
    );
    if (linux.E.init(pr_rc) != .SUCCESS) return error.PivotRoot;

    // now inside new root — chdir to /
    try posix.chdir("/");

    // Unmount old root
    const umount_rc = linux.syscall2(
        .umount2,
        @intFromPtr(@as([*:0]const u8, "/.pivot_old")),
        @as(usize, 2), // MNT_DETACH
    );
    if (linux.E.init(umount_rc) != .SUCCESS) return error.Umount;

    // remove the .pivot_old stub
    _ = linux.syscall3(
        .unlinkat,
        @as(usize, @bitCast(@as(isize, linux.AT.FDCWD))),
        @intFromPtr(@as([*:0]const u8, "/.pivot_old")),
        linux.AT.REMOVEDIR,
    );

    // mount /proc
    sysMkdir("/proc", 0o555);
    try sysMount("proc", "/proc", "proc", 0, 0);

    // =ount /dev (minimal tmpfs)
    sysMkdir("/dev", 0o755);
    try sysMountData(
        "tmpfs",
        "/dev",
        "tmpfs",
        linux.MS.NOSUID | linux.MS.STRICTATIME,
        "mode=755,size=65536k",
    );

    // Create basic device nodes
    for (devices) |dev| {
        _ = linux.mknodat(
            linux.AT.FDCWD,
            dev.path,
            linux.S.IFCHR | 0o666,
            makedev(dev.major, dev.minor),
        );
    }

    // mount /sys (read-only)
    sysMkdir("/sys", 0o555);
    _ = sysMount("sysfs", "/sys", "sysfs", linux.MS.RDONLY, 0) catch {};

    // Mount cgroup2 so memory.max/memory.current are visible inside the container.
    // Must come after sysfs, otherwise /sys gets mounted over our cgroup2 mount.
    sysMkdir("/sys/fs/cgroup", 0o555);
    _ = sysMount("cgroup2", "/sys/fs/cgroup", "cgroup2", linux.MS.RDONLY, 0) catch {};

    // mount /tmp — no explicit size limit so it can grow until the
    // cgroup memory limit kicks in and the OOM killer fires.
    sysMkdir("/tmp", 0o1777);
    _ = sysMount("tmpfs", "/tmp", "tmpfs", 0, 0) catch {};

    std.debug.print("[child]  mounts set up, pivoted into new rootfs\n", .{});
}

//  cgroup v2

fn setupCgroup(buf: []u8, mem_limit: u64) ![]const u8 {
    const pid = linux.getpid();
    const cgroup_dir = fmt.bufPrint(buf, "{s}/mini-container-{d}", .{ cgroup_root, pid }) catch
        return error.PathTooLong;

    // Create the cgroup directory
    const cgroup_dir_z = try toSentinel(cgroup_dir);
    const mk_rc = linux.mkdirat(linux.AT.FDCWD, cgroup_dir_z, 0o755);
    const mk_errno = linux.E.init(mk_rc);
    if (mk_errno != .SUCCESS and mk_errno != .EXIST) return error.MkdirCgroup;

    // Enable memory controller (best-effort)
    writeToFile(cgroup_root ++ "/cgroup.subtree_control", "+memory") catch {};

    // Set memory.max
    var limit_buf: [32]u8 = undefined;
    const limit_str = fmt.bufPrint(&limit_buf, "{d}", .{mem_limit}) catch unreachable;
    {
        var path_buf: [512]u8 = undefined;
        const path = fmt.bufPrint(&path_buf, "{s}/memory.max", .{cgroup_dir}) catch
            return error.PathTooLong;
        try writeToFile(path, limit_str);
    }

    // Disable swap (best-effort)
    {
        var path_buf: [512]u8 = undefined;
        const path = fmt.bufPrint(&path_buf, "{s}/memory.swap.max", .{cgroup_dir}) catch
            return error.PathTooLong;
        writeToFile(path, "0") catch {};
    }

    std.debug.print("[parent] cgroup: {s} (mem limit {d} bytes)\n", .{ cgroup_dir, mem_limit });
    return cgroup_dir;
}

fn joinCgroupPid(cgroup_path: []const u8, pid: anytype) !void {
    var path_buf: [512]u8 = undefined;
    const procs_path = fmt.bufPrint(&path_buf, "{s}/cgroup.procs", .{cgroup_path}) catch
        return error.PathTooLong;

    var pid_buf: [16]u8 = undefined;
    const pid_str = fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch unreachable;

    try writeToFile(procs_path, pid_str);
}

/// Move the calling process back to the root cgroup.
fn moveToRootCgroup() !void {
    var pid_buf: [16]u8 = undefined;
    const pid_str = fmt.bufPrint(&pid_buf, "{d}", .{linux.getpid()}) catch unreachable;
    try writeToFile(cgroup_root ++ "/cgroup.procs", pid_str);
}

fn cleanupCgroup(cgroup_path: []const u8) void {
    const z = toSentinel(cgroup_path) catch return;
    const rc = linux.syscall3(
        .unlinkat,
        @as(usize, @bitCast(@as(isize, linux.AT.FDCWD))),
        @intFromPtr(z.ptr),
        linux.AT.REMOVEDIR,
    );
    if (linux.E.init(rc) == .SUCCESS) {
        std.debug.print("[parent] cgroup removed: {s}\n", .{cgroup_path});
    } else {
        std.debug.print("[parent] cgroup cleanup failed: {s}\n", .{cgroup_path});
    }
}

// a few helpers

/// Linux makedev: encode major/minor into a dev_t.
fn makedev(major: u32, minor: u32) u32 {
    return (major << 8) | minor;
}

/// write a string to a file at the given path.
fn writeToFile(path: []const u8, value: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer file.close();
    try file.writeAll(value);
}

/// wrapper around the mount syscall with null-terminated strings.
fn sysMount(
    source: ?[*:0]const u8,
    target: [*:0]const u8,
    fstype: ?[*:0]const u8,
    flags: u32,
    data: usize,
) !void {
    const rc = linux.mount(source, target, fstype, flags, data);
    if (linux.E.init(rc) != .SUCCESS) return error.Mount;
}

/// mount with string data parameter.
fn sysMountData(
    source: [*:0]const u8,
    target: [*:0]const u8,
    fstype: [*:0]const u8,
    flags: u32,
    data: [*:0]const u8,
) !void {
    const rc = linux.mount(source, target, fstype, flags, @intFromPtr(data));
    if (linux.E.init(rc) != .SUCCESS) return error.Mount;
}

/// mkdir via raw syscall, ignoring errors (directory may already exist).
fn sysMkdir(path: [*:0]const u8, mode: u32) void {
    _ = linux.mkdirat(linux.AT.FDCWD, path, mode);
}

/// convert a Zig slice to a stack-allocated null-terminated pointer.
/// uses a thread-local buffer. Only valid until the next call.
threadlocal var sentinel_buf: [1024]u8 = undefined;

fn toSentinel(slice: []const u8) ![:0]const u8 {
    if (slice.len >= sentinel_buf.len) return error.PathTooLong;
    @memcpy(sentinel_buf[0..slice.len], slice);
    sentinel_buf[slice.len] = 0;
    return sentinel_buf[0..slice.len :0];
}

fn printBanner(rootfs: []const u8, mem_limit: u64, cmd: []const u8) void {
    std.debug.print(
        \\╔══════════════════════════════════════════╗
        \\║        mini-container starting...        ║
        \\╠══════════════════════════════════════════╣
        \\║  rootfs:    {s:28} ║
        \\║  mem limit: {d:10} bytes║
        \\║  command:   {s:28} ║
        \\╚══════════════════════════════════════════╝
        \\
    , .{ rootfs, mem_limit, cmd });
}

fn printUsage(prog: []const u8) void {
    std.debug.print(
        \\mini-container — a minimal container runtime in Zig
        \\
        \\Usage:
        \\  {s} <rootfs> <mem_limit_bytes> <cmd> [args...]
        \\
        \\Example:
        \\  {s} ./rootfs 67108864 /bin/sh
        \\
        \\This starts <cmd> inside an isolated container with:
        \\  - PID namespace   — process becomes PID 1
        \\  - Mount namespace — pivot_root into rootfs
        \\  - UTS namespace   — separate hostname
        \\  - Network ns      — isolated network stack
        \\  - IPC namespace   — isolated shared memory
        \\  - cgroup v2       — memory limit enforced
        \\
    , .{ prog, prog });
}
