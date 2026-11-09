// tb_regfile.cpp
// Unit test for regfile.v against a shadow array:
//   - random writes and reads on both ports
//   - x0 reads zero and ignores writes
//   - a write only lands on the rising edge (reads are combinational)

#include <cstdint>
#include <cstdio>
#include <memory>
#include <random>

#include <verilated.h>

#include "Vregfile.h"

int main(int argc, char** argv)
{
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    auto dut = std::make_unique<Vregfile>(ctx.get());

    uint32_t shadow[32] = {0};
    std::mt19937 rng(54321);
    uint64_t errors = 0;
    uint64_t checks = 0;

    auto tick = [&]()
    {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
    };

    auto expect = [&](const char* what, uint32_t got, uint32_t want)
    {
        checks++;
        if (got != want)
        {
            errors++;
            if (errors <= 10)
            {
                std::printf("MISMATCH %s got=%08x want=%08x\n", what, got, want);
            }
        }
    };

    // Initialize every register so the shadow model is exact.
    dut->we = 1;
    for (uint32_t r = 0; r < 32; r++)
    {
        uint32_t v = rng();
        dut->rd_addr = r;
        dut->rd_data = v;
        tick();
        if (r != 0)
        {
            shadow[r] = v;
        }
    }

    for (int i = 0; i < 200000; i++)
    {
        uint32_t ra = rng() & 31u;
        uint32_t rb = rng() & 31u;
        uint32_t rd = rng() & 31u;
        uint32_t v = rng();
        bool we = (rng() & 1u) != 0;

        dut->rs1_addr = ra;
        dut->rs2_addr = rb;
        dut->we = we ? 1 : 0;
        dut->rd_addr = rd;
        dut->rd_data = v;
        dut->clk = 0;
        dut->eval();

        // Before the edge: old values, even if rd == ra.
        expect("rs1 pre-edge", dut->rs1_data, shadow[ra]);
        expect("rs2 pre-edge", dut->rs2_data, shadow[rb]);

        dut->clk = 1;
        dut->eval();
        if (we && rd != 0)
        {
            shadow[rd] = v;
        }

        // After the edge: new values visible.
        expect("rs1 post-edge", dut->rs1_data, shadow[ra]);
        expect("rs2 post-edge", dut->rs2_data, shadow[rb]);
    }

    // Explicit x0 check.
    dut->we = 1;
    dut->rd_addr = 0;
    dut->rd_data = 0xFFFFFFFFu;
    tick();
    dut->rs1_addr = 0;
    dut->rs2_addr = 0;
    dut->eval();
    expect("x0 port 1", dut->rs1_data, 0);
    expect("x0 port 2", dut->rs2_data, 0);

    dut->final();
    if (errors)
    {
        std::printf("regfile: FAIL  %llu of %llu checks wrong\n",
                    static_cast<unsigned long long>(errors), static_cast<unsigned long long>(checks));
        return 1;
    }
    std::printf("regfile: PASS  %llu checks\n", static_cast<unsigned long long>(checks));
    return 0;
}
