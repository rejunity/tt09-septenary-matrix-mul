![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)


# FPGA/ASIC for low-precision 2.67 bits/param Neural Network accelerator

This implementation builds on top of 1.58 bit systolic array: https://github.com/rejunity/tiny-asic-1_58bit-matrix-mul, but instead of ternary weights it uses **septenary and quinary weights**.

Using septenary and quinary weights 3 weights can be stored in 1 byte - **2.67 bit per parameter**.

3 parameters are stored in 8 bits:
- 2 septenary {-2,-1,-.5,0,.5,1,2} and
- 1 quinary {-2,-1,0,1,2}

## Observations based on chip synthesis for 130 nm process
- A single 2.67bpp *(bit per param)* MAC unit is **~25% larger** in area than 1.58bpp ternary MAC unit.
- An array of 2.67bpp MAC units taking **the same area** as an array of 1.58bpp ternary MAC unit will provide **~20% less** operations per sec.
- Given the same memory bandwidth 2.67bpp array is **~40% slower**.

To outperform ternary:
- 2.76bpp compressed network must achieve the same classification performance with **~40% less parameters** i.e. 591 parameters instead of 1000 parameters OR
- given the same amount of netwok parameters 2.76bpp accelerator would need to be **75% larger in area** (probably x3 times more power consumption) to maintain the same inference speed!


## Measurements

Sizes of the currently synthesized and measured systolic arrays using OpenLane and eFabless 130nm PDK via [Tiny Tapeout](https://tinytapeout.com):
- 1.58bpp - 5x1 .. 30x6 grids
- 2.67bpp - 3x1 .. 18x6 grids


## Intent & ASIC
Low-precision weight is inspired by Keller Jordan post: https://x.com/kellerjordan0/status/1837874116533407990 This implementation is an exploration of the design space - intent is to measure how chip area, precsion and memory bandwidth affects the performance of the systolic array and AI accelerators.

This ASIC will be fabricated using eFabless 130 nm process via [Tiny Tapeout](https://tinytapeout.com).


# ASIC 1.58 bit aka TERNARY weight LLMs 

See [The Era of 1-bit LLMs: All Large Language Models are in 1.58 Bits](https://arxiv.org/pdf/2402.17764.pdf) paper that reduces weights of the [Large Language Model](https://en.wikipedia.org/wiki/Large_language_model) to ternary representation `{-1, 0, 1}`.


# What is Tiny Tapeout?

TinyTapeout is an educational project that aims to make it easier and cheaper than ever to get your digital designs manufactured on a real chip.

To learn more and get started, visit https://tinytapeout.com.
- [FAQ](https://tinytapeout.com/faq/)
- [Digital design lessons](https://tinytapeout.com/digital_design/)
- [Join the community](https://tinytapeout.com/discord)
