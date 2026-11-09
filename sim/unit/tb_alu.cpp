// tb_alu.cpp
// Unit test for alu.v: compares every operation against a C++ reference
// model on edge-case operands and random vectors.

#include <cstdint>
#include <cstdio>
#include <memory>
#include <random>

#include <verilated.h>

#include "Valu.h"

struct Op
{
    uint8_t code;
    const char* name;
};

static const Op OPS[] = {
    {0x0, "add"}, {0x8, "sub"}, {0x1, "sll"}, {0x2, "slt"}, {0x3, "sltu"},
    {0x4, "xor"}, {0x5, "srl"}, {0xD, "sra"}, {0x6, "or"},  {0x7, "and"},
};

static uint32_t ref(uint8_t op, uint32_t a, uint32_t b)
{
    uint32_t sh = b & 31u;
    switch (op)
    {
        case 0x0: return a + b;
        case 0x8: return a - b;
        case 0x1: return a << sh;
        case 0x2: return static_cast<int32_t>(a) < static_cast<int32_t>(b) ? 1u : 0u;
        case 0x3: return a < b ? 1u : 0u;
        case 0x4: return a ^ b;
        case 0x5: return a >> sh;
        case 0xD: return static_cast<uint32_t>(static_cast<int32_t>(a) >> sh);
        case 0x6: return a | b;
        case 0x7: return a & b;
        default:  return 0;
    }
}

int main(int argc, char** argv)
{
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    auto dut = std::make_unique<Valu>(ctx.get());

    static const uint32_t EDGE[] = {
        0x00000000u, 0x00000001u, 0x00000002u, 0x0000001Fu, 0x00000020u,
        0x7FFFFFFFu, 0x80000000u, 0x80000001u, 0xFFFFFFFEu, 0xFFFFFFFFu,
    };

    std::mt19937 rng(12345);
    uint64_t checks = 0;
    uint64_t errors = 0;

    auto check = [&](const Op& op, uint32_t a, uint32_t b)
    {
        dut->op = op.code;
        dut->a = a;
        dut->b = b;
        dut->eval();
        uint32_t expect = ref(op.code, a, b);
        checks++;
        if (dut->y != expect)
        {
            errors++;
            if (errors <= 10)
            {
                std::printf("MISMATCH %-4s a=%08x b=%08x got=%08x expect=%08x\n",
                            op.name, a, b, dut->y, expect);
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
        for (int i = 0; i < 100000; i++)
        {
            check(op, rng(), rng());
        }
    }

    dut->final();
    if (errors)
    {
        std::printf("alu: FAIL  %llu of %llu checks wrong\n",
                    static_cast<unsigned long long>(errors), static_cast<unsigned long long>(checks));
        return 1;
    }
    std::printf("alu: PASS  %llu checks\n", static_cast<unsigned long long>(checks));
    return 0;
}
