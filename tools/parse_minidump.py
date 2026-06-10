"""Minimal Windows minidump parser: exception, modules, heuristic stack walk.

Not a general tool; just enough to attribute a crash to a module. Reads the
exception stream (faulting code/address/thread), the module list, and scans the
faulting thread's captured stack for 8-byte values that land inside a known
module range (a poor-man's call stack, no symbols).
"""
import struct, sys, bisect

path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()

def u16(o): return struct.unpack_from("<H", data, o)[0]
def u32(o): return struct.unpack_from("<I", data, o)[0]
def u64(o): return struct.unpack_from("<Q", data, o)[0]

assert data[:4] == b"MDMP", "not a minidump"
nstreams = u32(8)
dir_rva = u32(12)

streams = {}
for i in range(nstreams):
    e = dir_rva + i * 12
    stype = u32(e)
    dsize = u32(e + 4)
    drva = u32(e + 8)
    streams[stype] = (drva, dsize)

def mdstring(rva):
    ln = u32(rva)
    raw = data[rva + 4: rva + 4 + ln]
    return raw.decode("utf-16-le", "replace")

# ---- modules ----
modules = []  # (base, size, name)
if 4 in streams:
    rva, _ = streams[4]
    n = u32(rva)
    o = rva + 4
    for i in range(n):
        base = u64(o)
        size = u32(o + 8)
        name_rva = u32(o + 20)  # after CheckSum(12) + TimeDateStamp(16)
        name = mdstring(name_rva)
        modules.append((base, size, name))
        o += 108

modules.sort()
mod_bases = [m[0] for m in modules]

def which_module(addr):
    idx = bisect.bisect_right(mod_bases, addr) - 1
    if 0 <= idx < len(modules):
        base, size, name = modules[idx]
        if base <= addr < base + size:
            short = name.split("\\")[-1]
            return short, addr - base
    return None, None

# ---- system info ----
if 7 in streams:
    rva, _ = streams[7]
    arch = u16(rva)
    major = u32(rva + 8); minor = u32(rva + 12); build = u32(rva + 16)
    archname = {0: "x86", 9: "x64", 12: "ARM64"}.get(arch, str(arch))
    print(f"System: {archname}  Windows {major}.{minor}.{build}")

# ---- exception ----
fault_tid = None
fault_rip = None
if 6 in streams:
    rva, _ = streams[6]
    fault_tid = u32(rva)
    er = rva + 8  # MINIDUMP_EXCEPTION
    code = u32(er)
    flags = u32(er + 4)
    addr = u64(er + 16)
    nparams = u32(er + 24)
    params = [u64(er + 32 + 8 * k) for k in range(min(nparams, 15))]
    fault_rip = addr
    codes = {
        0xC0000005: "ACCESS_VIOLATION",
        0xC00000FD: "STACK_OVERFLOW",
        0xC000001D: "ILLEGAL_INSTRUCTION",
        0x80000003: "BREAKPOINT",
        0xC0000094: "INT_DIVIDE_BY_ZERO",
        0xC0000374: "HEAP_CORRUPTION",
        0xC0000409: "STACK_BUFFER_OVERRUN",
        0xE06D7363: "C++ EXCEPTION (throw)",
    }
    # the exception stream carries its OWN ThreadContext (fault-time registers),
    # at offset 160 (after ThreadId(8) + MINIDUMP_EXCEPTION(152)).
    exc_ctx_rva = u32(rva + 164)
    cname = codes.get(code, "?")
    print(f"\nException: 0x{code:08X} {cname}  flags=0x{flags:08X}  thread={fault_tid}")
    mod, off = which_module(addr)
    if mod:
        print(f"  faulting address: 0x{addr:016X}  -> {mod}+0x{off:X}")
    else:
        print(f"  faulting address: 0x{addr:016X}  -> (not in any module)")
    if code == 0xC0000005 and len(params) >= 2:
        access = {0: "READ", 1: "WRITE", 8: "EXECUTE"}.get(params[0], str(params[0]))
        tgt = params[1]
        m2, o2 = which_module(tgt)
        loc = f" -> {m2}+0x{o2:X}" if m2 else ""
        print(f"  {access} of 0x{tgt:016X}{loc}")

# ---- threads + stack scan ----
threads = []  # (tid, stack_start, stack_rva, stack_size, ctx_rva)
if 3 in streams:
    rva, _ = streams[3]
    n = u32(rva)
    o = rva + 4
    for i in range(n):
        tid = u32(o)
        # ThreadId(0) SuspendCount(4) PriorityClass(8) Priority(12) Teb(16,8)
        # Stack@24: StartOfMemoryRange(24,8) DataSize(32,4) Rva(36,4)
        # ThreadContext@40: DataSize(40,4) Rva(44,4)
        stack_start = u64(o + 24)
        stack_size = u32(o + 32)
        stack_rva = u32(o + 36)
        ctx_rva = u32(o + 44)
        threads.append((tid, stack_start, stack_rva, stack_size, ctx_rva))
        o += 48

def ctx_regs(ctx_rva):
    # x64 CONTEXT: Rsp@0x98, Rbp@0xA0, Rip@0xF8 (after the home/control regs)
    try:
        rsp = u64(ctx_rva + 0x98)
        rbp = u64(ctx_rva + 0xA0)
        rip = u64(ctx_rva + 0xF8)
        return rsp, rbp, rip
    except Exception:
        return None, None, None

def stack_scan(tid):
    th = next((t for t in threads if t[0] == tid), None)
    if not th:
        print(f"  (thread {tid} not in thread list)")
        return
    _, start, srva, ssize, ctx_rva = th
    rsp, rbp, rip = ctx_regs(ctx_rva)
    if rip is not None:
        m, o = which_module(rip)
        print(f"  RIP=0x{rip:016X} {m}+0x{o:X}" if m else f"  RIP=0x{rip:016X}")
        print(f"  RSP=0x{rsp:016X}  RBP=0x{rbp:016X}")
    print(f"  stack 0x{start:016X} size {ssize} bytes")
    # scan from RSP if it lies inside the captured region, else from the start
    begin = 0
    if rsp and start <= rsp < start + ssize:
        begin = rsp - start
    seen = 0
    for off in range(begin, ssize - 8, 8):
        val = struct.unpack_from("<Q", data, srva + off)[0]
        mod, moff = which_module(val)
        if mod:
            print(f"    +0x{off:05X}  0x{val:016X}  {mod}+0x{moff:X}")
            seen += 1
            if seen >= 70:
                print("    ... (truncated)")
                break

def walk_from(ctx_rva, label):
    rsp, rbp, rip = ctx_regs(ctx_rva)
    print(f"\n{label}")
    if rip is not None:
        m, o = which_module(rip)
        print(f"  RIP=0x{rip:016X}  {m}+0x{o:X}" if m else f"  RIP=0x{rip:016X}  (no module)")
        print(f"  RSP=0x{rsp:016X}")
    # find the captured stack region that contains RSP
    th = next((t for t in threads if rsp and t[1] <= rsp < t[1] + t[3]), None)
    if not th:
        print("  (RSP not in any captured stack region)")
        return
    _, start, srva, ssize, _ = th
    begin = rsp - start
    seen = 0
    for off in range(begin, ssize - 8, 8):
        val = struct.unpack_from("<Q", data, srva + off)[0]
        mod, moff = which_module(val)
        if mod:
            print(f"    0x{val:016X}  {mod}+0x{moff:X}")
            seen += 1
            if seen >= 40:
                break

if fault_tid is not None and exc_ctx_rva:
    walk_from(exc_ctx_rva, f"FAULT-TIME stack of thread {fault_tid} (exception context):")

if fault_tid is not None:
    print(f"\nFaulting thread {fault_tid} full captured-stack scan:")
    stack_scan(fault_tid)

print(f"\nLoaded modules ({len(modules)}):")
for base, size, name in modules:
    short = name.split("\\")[-1]
    print(f"  0x{base:016X}  0x{size:08X}  {short}")
