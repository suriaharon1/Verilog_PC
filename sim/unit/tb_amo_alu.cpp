// tb_amo_alu.cpp
// Unit test for amo_alu.v: every AMO op on edge-case and random operands,
// compared against a C++ reference.

#include <cstdint>
#include <cstdio>
#include <memory>
#include <random>

#include <verilated.h>

#include "Vamo_alu.h"

struct Op
{
    uint8_t funct5;
    const char* name;
};

static const Op OPS[] = {
    {0x00, "amoadd"},  {0x01, "amoswap"}, {0x04, "amoxor"},  {0x0C, "amoand"},
    {0x08, "amoor"},   {0x10, "amomin"},  {0x14, "amomax"},  {0x18, "amominu"},
    {0x1C, "amomaxu"},
};

static uint32_t ref(uint8_t f5, uint32_t old, uint32_t src)
{
    int32_t so = static_cast<int32_t>(old);
    int32_t ss = static_cast<int32_t>(src);
    switch (f5)
    {
        case 0x00: return old + src;
        case 0x01: return src;
        case 0x04: return old ^ src;
        case 0x0C: return old & src;
        case 0x08: return old | src;
        case 0x10: return so < ss ? old : src;
        case 0x14: return so < ss ? src : old;
        case 0x18: return old < src ? old : src;
        case 0x1C: return old < src ? src : old;
        default:   return old;
    }
}

int main(int argc, char** argv)
{
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    auto dut = std::make_unique<Vamo_alu>(ctx.get());

    static const uint32_t EDGE[] = {
        0x00000000u, 0x00000001u, 0x7FFFFFFFu, 0x80000000u, 0x80000001u,
        0xFFFFFFFEu, 0xFFFFFFFFu, 0x0000FFFFu, 0xFFFF0000u,
    };

    std::mt19937 rng(1357);
    uint64_t checks = 0;
    uint64_t errors = 0;

    auto check = [&](const Op& op, uint32_t old, uint32_t src)
    {
        dut->funct5 = op.funct5;
        dut->old = old;
        dut->src = src;
        dut->eval();
        uint32_t want = ref(op.funct5, old, src);
        checks++;
        if (dut->result != want)
        {
            errors++;
            if (errors <= 10)
            {
                std::printf("MISMATCH %-7s old=%08x src=%08x got=%08x want=%08x\n",
                            op.name, old, src, dut->result, want);
            }
        }
    };

    for (const Op& op : OPS)
    {
        for (uint32_t a : EDGE)
        {
            for (uint32_t b : EDGE)
            {
                check(op, a, b);
            }
        }
        for (int i = 0; i < 50000; i++)
        {
            check(op, rng(), rng());
        }
    }

    dut->final();
    if (errors)
    {
        std::printf("amo_alu: FAIL  %llu of %llu checks wrong\n",
                    static_cast<unsigned long long>(errors), static_cast<unsigned long long>(checks));
        return 1;
    }
    std::printf("amo_alu: PASS  %llu checks\n", static_cast<unsigned long long>(checks));
    return 0;
}
