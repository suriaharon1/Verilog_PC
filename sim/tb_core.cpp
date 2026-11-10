// tb_core.cpp
// Verilator testbench for core_top.
//
// Models a RAM at 0x8000_0000 on the core's bus, loads a flat binary into it,
// and watches stores to the riscv-tests `tohost` word:
//   1          -> PASS
//   odd, != 1  -> FAIL, failing test case = value >> 1
// A cycle timeout turns a hung program into a failure.
//
// Usage:
//   Vcore_top <program.bin> --tohost 0xADDR [--timeout N] [--trace]
//             [--random-wait] [--seed N] [--wave out.fst]
//             [--commit-log out.log]
//
// --commit-log writes one line per retired instruction in the same format as
// `spike --log-commits`, so scripts/lockstep.py can diff the two. Trapping
// instructions are left out, because Spike does not log them either.
//
// Exit codes: 0 pass, 1 fail, 2 timeout, 3 bus error, 4 usage error.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include <verilated.h>
#include <verilated_fst_c.h>

#include "Vcore_top.h"

static const uint32_t RAM_BASE = 0x80000000u;
static const uint32_t RAM_SIZE = 64u * 1024u * 1024u;

struct Options
{
    std::string bin;
    uint32_t tohost = 0;
    bool have_tohost = false;
    uint64_t timeout = 2000000;
    bool trace = false;
    bool random_wait = false;
    uint32_t seed = 1;
    std::string wave;
    std::string commit_log;
};

static void usage(const char* prog)
{
    std::fprintf(stderr,
        "usage: %s <program.bin> --tohost 0xADDR [--timeout N] [--trace]\n"
        "          [--random-wait] [--seed N] [--wave out.fst]\n"
        "          [--commit-log out.log]\n", prog);
}

static bool parse_args(int argc, char** argv, Options& opt)
{
    for (int i = 1; i < argc; i++)
    {
        std::string a = argv[i];
        if (a == "--tohost" && i + 1 < argc)
        {
            opt.tohost = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 0));
            opt.have_tohost = true;
        }
        else if (a == "--timeout" && i + 1 < argc)
        {
            opt.timeout = std::strtoull(argv[++i], nullptr, 0);
        }
        else if (a == "--trace")
        {
            opt.trace = true;
        }
        else if (a == "--random-wait")
        {
            opt.random_wait = true;
        }
        else if (a == "--seed" && i + 1 < argc)
        {
            opt.seed = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 0));
        }
        else if (a == "--wave" && i + 1 < argc)
        {
            opt.wave = argv[++i];
        }
        else if (a == "--commit-log" && i + 1 < argc)
        {
            opt.commit_log = argv[++i];
        }
        else if (!a.empty() && a[0] == '+')
        {
            // Verilator plusargs, ignore here.
        }
        else if (opt.bin.empty() && !a.empty() && a[0] != '-')
        {
            opt.bin = a;
        }
        else
        {
            return false;
        }
    }
    return !opt.bin.empty() && opt.have_tohost;
}

static bool load_bin(const std::string& path, std::vector<uint8_t>& ram)
{
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f)
    {
        std::fprintf(stderr, "error: cannot open %s\n", path.c_str());
        return false;
    }
    size_t n = std::fread(ram.data(), 1, ram.size(), f);
    std::fclose(f);
    if (n == 0)
    {
        std::fprintf(stderr, "error: %s is empty\n", path.c_str());
        return false;
    }
    return true;
}

int main(int argc, char** argv)
{
    Options opt;
    if (!parse_args(argc, argv, opt))
    {
        usage(argv[0]);
        return 4;
    }

    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    ctx->randReset(2);                 // randomize uninitialized state
    ctx->randSeed(static_cast<int>(opt.seed));
    ctx->traceEverOn(!opt.wave.empty());

    auto top = std::make_unique<Vcore_top>(ctx.get());

    std::unique_ptr<VerilatedFstC> tfp;
    if (!opt.wave.empty())
    {
        tfp = std::make_unique<VerilatedFstC>();
        top->trace(tfp.get(), 99);
        tfp->open(opt.wave.c_str());
    }

    std::vector<uint8_t> ram(RAM_SIZE, 0);
    if (!load_bin(opt.bin, ram))
    {
        return 4;
    }

    FILE* clog = nullptr;
    if (!opt.commit_log.empty())
    {
        clog = std::fopen(opt.commit_log.c_str(), "w");
        if (!clog)
        {
            std::fprintf(stderr, "error: cannot write %s\n", opt.commit_log.c_str());
            return 4;
        }
    }

    std::mt19937 rng(opt.seed);
    uint64_t time = 0;

    auto dump = [&]()
    {
        if (tfp)
        {
            tfp->dump(time);
        }
        time++;
    };

    // Reset
    top->clk = 0;
    top->rst = 1;
    top->mem_ready = 0;
    top->mem_rdata = 0;
    for (int i = 0; i < 5; i++)
    {
        top->clk = 0;
        top->eval();
        dump();
        top->clk = 1;
        top->eval();
        dump();
    }
    top->rst = 0;

    int result = 2;        // timeout unless told otherwise
    uint32_t fail_case = 0;
    uint64_t cycle = 0;
    uint64_t retired = 0;

    for (cycle = 0; cycle < opt.timeout; cycle++)
    {
        // Low phase: let the core's outputs settle.
        top->clk = 0;
        top->eval();

        // Bus response for this cycle.
        bool ready = false;
        uint32_t rdata = 0xDEADBEEFu;   // garbage unless ready, to catch early sampling
        bool finish = false;

        if (top->mem_valid)
        {
            ready = !opt.random_wait || (rng() & 1u);
        }

        if (ready)
        {
            uint32_t addr = top->mem_addr;
            if ((addr & 3u) != 0 || addr < RAM_BASE || addr - RAM_BASE > RAM_SIZE - 4)
            {
                std::fprintf(stderr, "BUS ERROR: access to 0x%08x at cycle %llu\n",
                             addr, static_cast<unsigned long long>(cycle));
                result = 3;
                break;
            }
            uint32_t off = addr - RAM_BASE;
            uint32_t word;
            std::memcpy(&word, &ram[off], 4);
            uint8_t strb = top->mem_wstrb;
            if (strb == 0)
            {
                rdata = word;
            }
            else
            {
                uint32_t wdata = top->mem_wdata;
                for (int b = 0; b < 4; b++)
                {
                    if (strb & (1u << b))
                    {
                        ram[off + b] = static_cast<uint8_t>(wdata >> (8 * b));
                    }
                }
                if (addr == opt.tohost && wdata != 0)
                {
                    if (wdata == 1)
                    {
                        result = 0;
                    }
                    else
                    {
                        result = 1;
                        fail_case = wdata >> 1;
                    }
                    finish = true;
                }
            }
        }

        top->mem_ready = ready ? 1 : 0;
        top->mem_rdata = rdata;
        top->eval();
        dump();

        if (top->trace_valid)
        {
            retired++;
            if (opt.trace)
            {
                std::printf("%10llu  pc=%08x  insn=%08x", static_cast<unsigned long long>(cycle),
                            top->trace_pc, top->trace_insn);
                if (top->trace_trap)
                {
                    std::printf("  TRAP");
                }
                else if (top->trace_rd_we)
                {
                    std::printf("  x%-2u <= %08x", top->trace_rd, top->trace_rd_wdata);
                }
                std::printf("\n");
            }
            if (clog && !top->trace_trap)
            {
                // Spike format: core   0: <priv> 0x<pc> (0x<insn>) [x<rd> 0x<val>] [mem 0x<addr> [0x<data>]]
                std::fprintf(clog, "core   0: 3 0x%08x (0x%08x)", top->trace_pc, top->trace_insn);
                if (top->trace_rd_we)
                {
                    std::fprintf(clog, " x%-2u 0x%08x", top->trace_rd, top->trace_rd_wdata);
                }
                if (top->trace_mem_valid)
                {
                    std::fprintf(clog, " mem 0x%08x", top->trace_mem_addr);
                    if (top->trace_mem_store)
                    {
                        int digits = 2 << top->trace_mem_size;   // 2, 4, or 8 hex digits
                        std::fprintf(clog, " 0x%0*x", digits, top->trace_mem_wdata);
                    }
                }
                std::fprintf(clog, "\n");
            }
        }

        // Rising edge.
        top->clk = 1;
        top->eval();
        dump();

        if (finish)
        {
            cycle++;
            break;
        }
    }

    if (tfp)
    {
        tfp->close();
    }
    if (clog)
    {
        std::fclose(clog);
    }
    top->final();

    double cpi = retired ? static_cast<double>(cycle) / static_cast<double>(retired) : 0.0;
    if (result == 0)
    {
        std::printf("PASS  (%llu cycles, %llu instructions, CPI %.2f)\n",
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned long long>(retired), cpi);
    }
    else if (result == 1)
    {
        std::printf("FAIL  test case %u  (%llu cycles)\n", fail_case,
                    static_cast<unsigned long long>(cycle));
    }
    else if (result == 2)
    {
        std::printf("TIMEOUT after %llu cycles\n", static_cast<unsigned long long>(cycle));
    }
    else
    {
        std::printf("BUS ERROR\n");
    }
    return result;
}
