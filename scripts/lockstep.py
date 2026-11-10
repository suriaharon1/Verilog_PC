#!/usr/bin/env python3
"""lockstep.py: compare the core's commit log against Spike, instruction by instruction.

For each ELF:
  1. Run the Verilator testbench with --commit-log to get the core's log.
  2. Run Spike with --log-commits on the same ELF (the reference model).
  3. Walk both logs in order and report the FIRST retired instruction where
     they disagree (pc, instruction bits, register write, or memory access).

Usage:
  scripts/lockstep.py build/tests/rv32ui-p-*.elf
  scripts/lockstep.py --sim path/to/other/Vcore_top build/tests/rv32ui-p-add.elf

Notes on making the two logs comparable:
  - Spike starts in its own boot ROM at 0x1000; those lines are skipped.
  - Spike does not log instructions that trap (ecall, illegal, ...); the
    testbench leaves them out too.
  - Spike keeps running after the test writes tohost, so it is stopped at the
    first nonzero store to tohost.
  - Reads of cycle/time/instret counters legitimately differ and are masked.
  - CSR write fields (c773_mtvec ...) are ignored for now; only GPR writes and
    memory accesses are compared.
"""

import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SIM = os.path.join(ROOT, "build", "sim", "Vcore_top")
# Must describe exactly what the core implements:
#   zicntr  cycle/time/instret counters
#   zicclsm misaligned loads/stores handled in hardware
DEFAULT_ISA = "rv32i_zicsr_zicntr_zifencei_zicclsm"
RAM_BASE = 0x80000000

LINE_RE = re.compile(r"^core\s+\d+:\s+\d+\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)(.*)$")
REG_RE = re.compile(r"\bx(\d+)\s+0x([0-9a-f]+)")
MEM_RE = re.compile(r"\bmem\s+0x([0-9a-f]+)(?:\s+0x([0-9a-f]+))?")


class Commit:
    """One retired instruction, parsed from a Spike-format log line."""

    __slots__ = ("pc", "insn", "rd", "rd_val", "mem_addr", "mem_data", "text")

    def __init__(self, pc, insn, rd, rd_val, mem_addr, mem_data, text):
        self.pc = pc
        self.insn = insn
        self.rd = rd
        self.rd_val = rd_val
        self.mem_addr = mem_addr
        self.mem_data = mem_data
        self.text = text


def parse_line(line):
    m = LINE_RE.match(line.strip())
    if not m:
        return None
    pc = int(m.group(1), 16)
    insn = int(m.group(2), 16)
    rest = m.group(3)
    rd = rd_val = mem_addr = mem_data = None
    r = REG_RE.search(rest)
    if r:
        rd = int(r.group(1))
        rd_val = int(r.group(2), 16)
    mm = MEM_RE.search(rest)
    if mm:
        mem_addr = int(mm.group(1), 16)
        if mm.group(2) is not None:
            mem_data = int(mm.group(2), 16)
    return Commit(pc, insn, rd, rd_val, mem_addr, mem_data, line.rstrip("\n"))


def is_counter_read(insn):
    """True for a CSR instruction whose CSR is a cycle/time/instret counter."""
    if (insn & 0x7F) != 0x73 or ((insn >> 12) & 0x7) == 0:
        return False
    csr = insn >> 20
    return (0xB00 <= csr <= 0xB1F or 0xB80 <= csr <= 0xB9F or
            0xC00 <= csr <= 0xC1F or 0xC80 <= csr <= 0xC9F)


def is_tohost_store(c, tohost):
    return c.mem_addr == tohost and c.mem_data is not None and c.mem_data != 0


def find_tohost(elf):
    nm = os.environ.get("RISCV_PREFIX", "riscv64-unknown-elf-") + "nm"
    out = subprocess.run([nm, elf], capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == "tohost":
            return int(parts[0], 16)
    raise RuntimeError("no tohost symbol in " + elf)


def run_core(sim, elf, tohost, log_path, timeout_cycles):
    binfile = os.path.splitext(elf)[0] + ".bin"
    res = subprocess.run(
        [sim, binfile, "--tohost", hex(tohost), "--timeout", str(timeout_cycles),
         "--commit-log", log_path],
        capture_output=True, text=True)
    status = res.stdout.strip().splitlines()[-1] if res.stdout.strip() else "(no output)"
    commits = []
    with open(log_path) as f:
        for line in f:
            c = parse_line(line)
            if c:
                commits.append(c)
    return commits, status


def run_spike(spike, isa, elf, tohost, max_commits, log_path):
    """Stream Spike's commit log, stopping at the tohost store or max_commits."""
    proc = subprocess.Popen(
        [spike, "--isa=" + isa, "--priv=m", "--log-commits", elf],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    commits = []
    started = False
    try:
        with open(log_path, "w") as out:
            for line in proc.stderr:
                c = parse_line(line)
                if c is None:
                    continue
                if not started:
                    if c.pc < RAM_BASE:
                        continue            # Spike boot ROM
                    started = True
                out.write(line)
                commits.append(c)
                if is_tohost_store(c, tohost) or len(commits) >= max_commits:
                    break
    finally:
        proc.kill()
        proc.wait()
    return commits


def describe_diff(a, b):
    diffs = []
    if a.pc != b.pc:
        diffs.append("pc: core 0x%08x, spike 0x%08x" % (a.pc, b.pc))
    if a.insn != b.insn:
        diffs.append("instruction: core 0x%08x, spike 0x%08x" % (a.insn, b.insn))
    if (a.rd, a.rd_val) != (b.rd, b.rd_val):
        fmt = lambda c: "none" if c.rd is None else "x%d = 0x%08x" % (c.rd, c.rd_val)
        diffs.append("register write: core %s, spike %s" % (fmt(a), fmt(b)))
    if a.mem_addr != b.mem_addr:
        fmt = lambda v: "none" if v is None else "0x%08x" % v
        diffs.append("memory address: core %s, spike %s" % (fmt(a.mem_addr), fmt(b.mem_addr)))
    if a.mem_data != b.mem_data:
        fmt = lambda v: "none" if v is None else "0x%x" % v
        diffs.append("store data: core %s, spike %s" % (fmt(a.mem_data), fmt(b.mem_data)))
    return diffs


def commits_match(a, b):
    if a.pc != b.pc or a.insn != b.insn:
        return False
    if a.mem_addr != b.mem_addr or a.mem_data != b.mem_data:
        return False
    if a.rd != b.rd:
        return False
    if a.rd_val != b.rd_val and not is_counter_read(a.insn):
        return False
    return True


def compare(core, spike, context):
    """Return None if the logs match, otherwise a multi-line report."""
    n = min(len(core), len(spike))
    for i in range(n):
        if not commits_match(core[i], spike[i]):
            lines = ["first mismatch at instruction #%d" % (i + 1)]
            lines += ["  " + d for d in describe_diff(core[i], spike[i])]
            lines.append("  context (matching instructions before it):")
            for j in range(max(0, i - context), i):
                lines.append("        " + core[j].text)
            lines.append("  core:  " + core[i].text)
            lines.append("  spike: " + spike[i].text)
            return "\n".join(lines)
    if len(core) != len(spike):
        return ("logs agree for %d instructions, then lengths differ (core %d, spike %d)\n"
                "  last common: %s" % (n, len(core), len(spike), core[n - 1].text if n else "(none)"))
    return None


def main():
    ap = argparse.ArgumentParser(description="Lockstep-compare the core against Spike.")
    ap.add_argument("elfs", nargs="+", help="test ELF files (a .bin must sit next to each)")
    ap.add_argument("--sim", default=DEFAULT_SIM, help="Verilator testbench binary")
    ap.add_argument("--spike", default="spike", help="Spike binary")
    ap.add_argument("--isa", default=DEFAULT_ISA, help="Spike ISA string")
    ap.add_argument("--timeout", type=int, default=2000000, help="core cycle limit")
    ap.add_argument("--context", type=int, default=5, help="lines of context before a mismatch")
    ap.add_argument("--logs", metavar="DIR", default=os.path.join(ROOT, "build", "lockstep"),
                    help="where to write both logs (default: build/lockstep)")
    args = ap.parse_args()

    if not os.access(args.sim, os.X_OK):
        sys.exit("error: %s not built (run: make sim)" % args.sim)

    log_dir = args.logs
    os.makedirs(log_dir, exist_ok=True)

    passed = 0
    failed = []
    for elf in args.elfs:
        name = os.path.splitext(os.path.basename(elf))[0]
        tohost = find_tohost(elf)
        core_log = os.path.join(log_dir, name + ".core.log")
        spike_log = os.path.join(log_dir, name + ".spike.log")

        core, status = run_core(args.sim, elf, tohost, core_log, args.timeout)
        spike = run_spike(args.spike, args.isa, elf, tohost, len(core) + 1000, spike_log)
        report = compare(core, spike, args.context)

        if report is None:
            passed += 1
            print("%-24s MATCH  (%d instructions)  core: %s" % (name, len(core), status))
        else:
            failed.append(name)
            print("%-24s MISMATCH  core: %s" % (name, status))
            for line in report.splitlines():
                print("    " + line)
            print("    logs: %s, %s" % (core_log, spike_log))

    print("----------------------------------------")
    print("lockstep: %d matched, %d mismatched, %d total" % (passed, len(failed), passed + len(failed)))
    if failed:
        print("mismatched: " + " ".join(failed))
        sys.exit(1)


if __name__ == "__main__":
    main()
