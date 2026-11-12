// tb_muldiv.cpp
// Unit test for muldiv.v against a C++ reference model built on 64-bit math.
//   - all 8 ops x every pair of edge values (0, 1, -1, INT_MIN, INT_MAX, ...)
//   - random operands, including small divisors
//   - divide by zero and signed overflow are covered by the edge values
//   - checks the cycle count: multiply 2 cycles, divide 34 cycles
//   - random idle gaps between requests, plus back-to-back requests

#include <cstdint>
#include <cstdio>
#include <memory>
#include <random>

#include <verilated.h>

#include "Vmuldiv.h"

static const char* OP_NAMES[8] = {"mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"};

static uint32_t ref(int op, uint32_t a, uint32_t b)
{
    int32_t sa = static_cast<int32_t>(a);
    int32_t sb = static_cast<int32_t>(b);
    switch (op)
    {
        case 0: return a * b;
        case 1: return static_cast<uint32_t>((static_cast<int64_t>(sa) * static_cast<int64_t>(sb)) >> 32);
        case 2: return static_cast<uint32_t>((static_cast<int64_t>(sa) * static_cast<int64_t>(static_cast<uint64_t>(b))) >> 32);
        case 3: return static_cast<uint32_t>((static_cast<uint64_t>(a) * static_cast<uint64_t>(b)) >> 32);
        case 4:
            if (b == 0)
            {
                return 0xFFFFFFFFu;
            }
            if (a == 0x80000000u && b == 0xFFFFFFFFu)
            {
                return 0x80000000u;
            }
            return static_cast<uint32_t>(sa / sb);
        case 5:
            return b == 0 ? 0xFFFFFFFFu : a / b;
        case 6:
            if (b == 0)
            {
                return a;
            }
            if (a == 0x80000000u && b == 0xFFFFFFFFu)
            {
                return 0;
            }
            return static_cast<uint32_t>(sa % sb);
        case 7:
            return b == 0 ? a : a % b;
        default:
            return 0;
    }
}

int main(int argc, char** argv)
{
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    auto dut = std::make_unique<Vmuldiv>(ctx.get());

    std::mt19937 rng(2468);
    uint64_t checks = 0;
    uint64_t errors = 0;

    auto tick = [&]()
    {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
    };

    // Reset
    dut->req = 0;
    dut->rst = 1;
    tick();
    tick();
    dut->rst = 0;

    auto run = [&](int op, uint32_t a, uint32_t b)
    {
        // Optional idle cycles before the request.
        int gap = static_cast<int>(rng() % 3);
        for (int i = 0; i < gap; i++)
        {
            dut->req = 0;
            tick();
        }

        dut->req = 1;
        dut->op = static_cast<uint8_t>(op);
        dut->a = a;
        dut->b = b;

        int cycles = 0;
        bool scrambled = false;
        while (true)
        {
            dut->clk = 0;
            dut->eval();
            cycles++;
            if (dut->done)
            {
                break;
            }
            if (cycles > 100)
            {
                std::printf("HANG %s a=%08x b=%08x\n", OP_NAMES[op], a, b);
                errors++;
                return;
            }
            dut->clk = 1;
            dut->eval();
            // After the start cycle, change the inputs: the unit must have
            // latched its operands and must not care.
            if (!scrambled)
            {
                dut->a = rng();
                dut->b = rng();
                scrambled = true;
            }
        }

        uint32_t got = dut->result;
        uint32_t want = ref(op, a, b);
        int want_cycles = (op < 4) ? 2 : 34;
        checks++;
        if (got != want || cycles != want_cycles)
        {
            errors++;
            if (errors <= 10)
            {
                std::printf("MISMATCH %-6s a=%08x b=%08x got=%08x want=%08x cycles=%d (want %d)\n",
                            OP_NAMES[op], a, b, got, want, cycles, want_cycles);
            }
        }

        // Complete the done cycle and drop req. When the next call picks a
        // gap of 0, its request starts immediately (back-to-back).
        dut->clk = 1;
        dut->eval();
        dut->req = 0;
    };

    static const uint32_t EDGE[] = {
        0x00000000u, 0x00000001u, 0x00000002u, 0x00000003u, 0x00000007u,
        0x7FFFFFFFu, 0x80000000u, 0x80000001u, 0xFFFFFFFEu, 0xFFFFFFFFu,
        0x0000FFFFu, 0xFFFF0000u, 0x12345678u,
    };

    for (int op = 0; op < 8; op++)
    {
        for (uint32_t a : EDGE)
        {
            for (uint32_t b : EDGE)
            {
                run(op, a, b);
            }
        }
        for (int i = 0; i < 20000; i++)
        {
            uint32_t a = rng();
            uint32_t b = rng();
            // Small divisors exercise long quotients.
            if ((i & 3) == 0)
            {
                b &= 0xFFu;
            }
            run(op, a, b);
        }
    }

    dut->final();
    if (errors)
    {
        std::printf("muldiv: FAIL  %llu of %llu checks wrong\n",
                    static_cast<unsigned long long>(errors), static_cast<unsigned long long>(checks));
        return 1;
    }
    std::printf("muldiv: PASS  %llu checks (mul 2 cycles, div 34 cycles)\n",
                static_cast<unsigned long long>(checks));
    return 0;
}
