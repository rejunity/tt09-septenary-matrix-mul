# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_ena(dut):
    dut._log.info("Start")

    # Set the clock period to 10 us (100 KHz)
    clock = Clock(dut.clk, 10, units="us")
    cocotb.start_soon(clock.start())

    # Reset
    dut._log.info("Reset")
    dut.ena.value = 1
    # dut.ui_in.value = 81 # 1 1 1 8'd081
    # dut.ui_in.value = 82 # 2 1 1 8'd081
    dut.ui_in.value = 47 # 2 1 1.5 8'd047
    dut.uio_in.value = 0b0010_1110
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    dut._log.info("Calculate")
    # await ClockCycles(dut.clk, 256)
    for n in range(256):
        dut.uio_in.value = 0b0010_1110 if (n & 1 == 0) else 0b0000_0110
        await ClockCycles(dut.clk, 1)

    dut._log.info("Move results to output queue")
    dut.ena.value = 0
    dut.ui_in.value  = 0
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 1)
    dut.ena.value = 1

    dut._log.info("Read output")
    for n in range(16):
        await ClockCycles(dut.clk, 1)
        print(dut.uo_out.value)

@cocotb.test()
async def test_w255(dut):
    dut._log.info("Start")

    # Set the clock period to 10 us (100 KHz)
    clock = Clock(dut.clk, 10, units="us")
    cocotb.start_soon(clock.start())

    # Reset
    dut._log.info("Reset")
    dut.ena.value = 1
    # dut.ui_in.value = 81 # 1 1 1 8'd081
    # dut.ui_in.value = 82 # 2 1 1 8'd081
    dut.ui_in.value = 47 # 2 1 1.5 8'd047
    dut.uio_in.value = 0b0010_1110
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    dut._log.info("Calculate")
    # await ClockCycles(dut.clk, 256)
    for n in range(256):
        dut.uio_in.value = 0b0010_1110 if (n & 1 == 0) else 0b0000_0110
        await ClockCycles(dut.clk, 1)

    dut._log.info("Move results to output queue")
    dut.ui_in.value  = 255
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 1)
    dut.ui_in.value  = 0

    dut._log.info("Read output")
    for n in range(16):
        await ClockCycles(dut.clk, 1)
        print(dut.uo_out.value)
