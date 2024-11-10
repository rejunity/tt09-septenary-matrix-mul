/*
 * Copyright (c) 2024 Renaldas Zioma
 * SPDX-License-Identifier: Apache-2.0
 */

`define COMPUTE_SLICES 2

`default_nettype none

module tt_um_rejunity_e2m0_x_i8_matmul (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);
    assign uio_oe  = 0;         // bidirectional IOs set to INPUT
    assign uio_out = 0;         // drive bidirectional IO outputs to 0

    wire reset = ! rst_n;

    // unpack septenary/quinary weights - 3 weights per byte
    wire [2:0] weights_zero;
    wire [2:0] weights_sign;
    wire [2:0] weights_mul2;
    wire [2:0] weights_div2;
    unpack_775_weights unpack_775_weights(
        .packed_weights(ui_in),
        .zero(weights_zero),
        .sign(weights_sign),
        .mul2(weights_mul2),
        .div2(weights_div2)
    );

    wire       initiate_read_out = !ena || &ui_in;
    
    systolic_array systolic_array (
        .clk(clk),
        .reset(reset),

        .in_left_zero(weights_zero),
        .in_left_sign(weights_sign),
        .in_left_mul2(weights_mul2),
        .in_left_div2(weights_div2),
        .in_top(uio_in),

        .restart_inputs(initiate_read_out),
        .reset_accumulators(initiate_read_out),
        .copy_accumulator_values_to_out_queue(initiate_read_out),
        .restart_out_queue(initiate_read_out),
        
        .out(uo_out)
    );
endmodule

module systolic_array #(
    parameter integer SLICES = `COMPUTE_SLICES
) (
    input  wire       clk,
    input  wire       reset,

    input  wire [2:0] in_left_zero,
    input  wire [2:0] in_left_sign,
    input  wire [2:0] in_left_mul2,
    input  wire [2:0] in_left_div2,
    input  wire [7:0] in_top,
    input  wire       restart_inputs,
    input  wire       reset_accumulators,
    input  wire       copy_accumulator_values_to_out_queue,
    input  wire       restart_out_queue,
    //input wire      apply_shift_to_accumulators,
    //input wire      apply_relu_to_out,
    output wire [7:0] out
);
    localparam SLICE_BITS = $clog2(SLICES);
    localparam SLICES_MINUS_1 = SLICES - 1;
    localparam W = 1 * SLICES;
    localparam H = 3 * SLICES;

    // Double buffer inputs
    // xxx_curr - arguments that are fed into MAC (multiply-accumulate) units
    // xxx_next - where the inputs are written to
    // once slice_counter reaches 0, xxx_next is flushed into xxx_curr
    reg [H  -1:0] arg_left_zero_curr;
    reg [H  -1:0] arg_left_sign_curr;
    reg [H  -1:0] arg_left_mul2_curr;
    reg [H  -1:0] arg_left_div2_curr;
    reg [W*8-1:0] arg_top_curr;

    reg [H  -1:0] arg_left_zero_next;
    reg [H  -1:0] arg_left_sign_next;
    reg [H  -1:0] arg_left_mul2_next;
    reg [H  -1:0] arg_left_div2_next;
    reg [W*8-1:0] arg_top_next;

    reg  [SLICE_BITS-1:0] slice_counter;
    (* mem2reg *)
    reg  signed [17:0] accumulators      [W*H-1:0];
    wire signed [17:0] accumulators_next [W*H-1:0];
    (* mem2reg *)
    reg  signed [17:0] out_queue         [W*H-1:0];

    genvar q;
    /* verilator lint_off GENUNNAMED */
    /* verilator lint_off PINMISSING */
    generate
    for (q = 0; q < W*H; q = q+1) begin
        `ifdef SIM
            assign read_accumulators[q] = accumulators[q];
            assign read_out_queue[q]    = out_queue[q];
        `else
            // Manual injection of the delay buffers (sky130_fd_sc_hd__dlygate4sd3_1)
            //  otherwise OpenLane will do it automatically,
            //  but at much larger step in the process
            //  leading to a more complex layout and longer wiring!
            //
            // See: https://skywater-pdk.readthedocs.io/en/main/contents/libraries/sky130_fd_sc_hd/cells/dlygate4sd3/README.html
            wire  signed [17:0] accumulators_buf;
            wire  signed [17:0] out_queue_buf;
            sky130_fd_sc_hd__dlygate4sd3_1 accumulators_dlygate[17:0] ( .A(accumulators[q]), .X(accumulators_buf) );
            sky130_fd_sc_hd__dlygate4sd3_1 out_queue_dlygate[17:0]    ( .A(out_queue[q]),    .X(out_queue_buf) );
            assign read_accumulators[q] = accumulators_buf;
            assign read_out_queue[q] = out_queue_buf;
        `endif
    end
    endgenerate
    /* verilator lint_on PINMISSING */
    /* verilator lint_on GENUNNAMED */
    wire  signed [17:0] read_accumulators[W*H-1:0];
    wire  signed [17:0] read_out_queue   [W*H-1:0];

    integer n;
    always @(posedge clk) begin
        if (reset | restart_inputs | slice_counter == SLICES_MINUS_1)
            slice_counter <= 0;
        else
            slice_counter <= slice_counter + 1;

        if (reset) begin
            arg_left_zero_next <= 0;
            arg_left_sign_next <= 0;
            arg_left_mul2_next <= 0;
            arg_left_div2_next <= 0;
            arg_top_next <= 0;
        end else begin // write current inputs in_xxx into the xxx_next
            arg_left_zero_next[H-1 -: 3] <= in_left_zero;
            arg_left_sign_next[H-1 -: 3] <= in_left_sign;
            arg_left_mul2_next[H-1 -: 3] <= in_left_mul2;
            arg_left_div2_next[H-1 -: 3] <= in_left_div2;
            arg_top_next    [W*8-1 -: 8] <= in_top;

            if (SLICES > 1) begin // shift xxx_next for the next input
                arg_left_zero_next[H-1-3 : 0] <= arg_left_zero_next[H-1 : 3];
                arg_left_sign_next[H-1-3 : 0] <= arg_left_sign_next[H-1 : 3];
                arg_left_mul2_next[H-1-3 : 0] <= arg_left_mul2_next[H-1 : 3];
                arg_left_div2_next[H-1-3 : 0] <= arg_left_div2_next[H-1 : 3];
                arg_top_next    [W*8-1-8 : 0] <= arg_top_next    [W*8-1 : 8];
            end
        end

        if (slice_counter == 0) begin // xxx_next is flushed into xxx_curr,
                                      // once slice_counter reaches 0
            arg_left_zero_curr <= arg_left_zero_next;
            arg_left_sign_curr <= arg_left_sign_next;
            arg_left_mul2_curr <= arg_left_mul2_next;
            arg_left_div2_curr <= arg_left_div2_next;
            if (SLICES > 1)
                arg_top_curr <= {arg_top_next[7:0], arg_top_next[W*8-1: 8]};
            else
                arg_top_curr <= arg_top_next;
        end else begin // shift top systolic array arguments every clock cycle
            if (SLICES > 1)
                arg_top_curr <= {8'd0, arg_top_curr[W*8-1: 8]};
        end
        
        // The following loop must be unrolled, otherwise Verilator
        // will treat <= assignments inside the loop as errors
        // See similar bug report and workaround here:
        //   https://github.com/verilator/verilator/issues/2782
        // Ideally unroll_full Verilator metacommand should be used,
        // however it is supported only from Verilator 5.022 (#3260) [Jiaxun Yang]
        // Instead BLKLOOPINIT errors are suppressed for this loop
        /* verilator lint_off BLKLOOPINIT */
        for (n = 0; n < W*H; n = n + 1) begin
            if (reset | reset_accumulators)
                accumulators[n] <= 0;
            else
                accumulators[n] <= accumulators_next[n];

            if (copy_accumulator_values_to_out_queue) begin
                // To compensate accumulators_next 'being ahead' (shifted by 1 after computation):
                // (e.g. SLICES=4)
                // o[0] <= acc_n[3], o[1] <= acc_n[0], o[2] <= acc_n[1], o[3] <= acc_n[2]
                // o[4] <= acc_n[7], o[5] <= acc_n[4], o[6] <= acc_n[5], o[7] <= acc_n[6]
                if (n%W == 0)
                    out_queue[n] <= accumulators_next[n+W-1];
                else
                    out_queue[n] <= accumulators_next[n-1];

                // Alternatively the following code can be used
                // if additional (slice_counter-1) wait cycles are introduced
                // out_queue[n] <= accumulators_next[n];
            end else if (n > 0)
                out_queue[n-1]  <= read_out_queue[n];
        end
        /* verilator lint_on BLKLOOPINIT */
    end

    genvar i, j;
    generate
    for (j = 0; j < W; j = j + 1)
        for (i = 0; i < H; i = i + 1) begin : mac
            wire zero = arg_left_zero_curr[i];
            wire sign = arg_left_sign_curr[i];
            wire mul2 = arg_left_mul2_curr[i];
            wire div2 = arg_left_div2_curr[i];
            // input is u8
            // wire signed [9:0] addend = $signed(
            //   mul2 ?  {1'b0, arg_top_curr[7:0], 1'b0}:
            //   div2 ?  {1'b0, 2'b0, arg_top_curr[7:1]}:
            //           {1'b0, 1'b0, arg_top_curr[7:0]});

            // input is s8
            // sign extend to 9-bit before arithmetic shifts
            wire signed [8:0] act = $signed({arg_top_curr[7], arg_top_curr[7:0]});
            wire signed [8:0] addend =
                mul2 ?  act <<< 1:
                div2 ?  act >>> 1:
                        act;
            if (j == 0) begin : compute
                assign accumulators_next[i*W+W-1] =
                     zero   ? read_accumulators[i*W+j] + 0 :
                    (sign   ? read_accumulators[i*W+j] - addend :
                              read_accumulators[i*W+j] + addend);
            end else begin : shift
                assign accumulators_next[i*W+j-1] =
                              read_accumulators[i*W+j];
                // Suppress unused signals warning
                wire _unused_ok = &{zero, sign, mul2, div2, addend};
            end

            // for debugging purposes in wave viewer
            wire [17:0] value_curr  = read_accumulators     [i*W+j];
            wire [17:0] value_next  =      accumulators_next[i*W+j];
            wire [17:0] value_queue = read_out_queue        [i*W+j];
            wire _only_for_debug = &{value_curr, value_next, value_queue};
        end
    endgenerate

    assign out = out_queue[0][9+:8];
    // assign out = out_queue[0][7:0];
endmodule


module unpack_775_weights(input      [7:0] packed_weights,
                          output reg [2:0] zero,
                          output reg [2:0] sign,
                          output reg [2:0] mul2,
                          output reg [2:0] div2);
    always @(*) begin
        case(packed_weights)
        8'd000: begin zero = 3'b111; sign = 3'b000; mul2 = 3'b000; div2 = 3'b000; end //     0    0    0
        8'd001: begin zero = 3'b011; sign = 3'b000; mul2 = 3'b000; div2 = 3'b000; end //     1    0    0
        8'd002: begin zero = 3'b011; sign = 3'b000; mul2 = 3'b100; div2 = 3'b000; end //     2    0    0
        8'd003: begin zero = 3'b011; sign = 3'b100; mul2 = 3'b000; div2 = 3'b000; end //    -1    0    0
        8'd004: begin zero = 3'b011; sign = 3'b100; mul2 = 3'b100; div2 = 3'b000; end //    -2    0    0
        8'd005: begin zero = 3'b101; sign = 3'b000; mul2 = 3'b000; div2 = 3'b010; end //     0  0.5    0
        8'd006: begin zero = 3'b001; sign = 3'b000; mul2 = 3'b000; div2 = 3'b010; end //     1  0.5    0
        8'd007: begin zero = 3'b001; sign = 3'b000; mul2 = 3'b100; div2 = 3'b010; end //     2  0.5    0
        8'd008: begin zero = 3'b001; sign = 3'b100; mul2 = 3'b000; div2 = 3'b010; end //    -1  0.5    0
        8'd009: begin zero = 3'b001; sign = 3'b100; mul2 = 3'b100; div2 = 3'b010; end //    -2  0.5    0
        8'd010: begin zero = 3'b101; sign = 3'b000; mul2 = 3'b000; div2 = 3'b000; end //     0    1    0
        8'd011: begin zero = 3'b001; sign = 3'b000; mul2 = 3'b000; div2 = 3'b000; end //     1    1    0
        8'd012: begin zero = 3'b001; sign = 3'b000; mul2 = 3'b100; div2 = 3'b000; end //     2    1    0
        8'd013: begin zero = 3'b001; sign = 3'b100; mul2 = 3'b000; div2 = 3'b000; end //    -1    1    0
        8'd014: begin zero = 3'b001; sign = 3'b100; mul2 = 3'b100; div2 = 3'b000; end //    -2    1    0
        8'd015: begin zero = 3'b101; sign = 3'b000; mul2 = 3'b010; div2 = 3'b000; end //     0    2    0
        8'd016: begin zero = 3'b001; sign = 3'b000; mul2 = 3'b010; div2 = 3'b000; end //     1    2    0
        8'd017: begin zero = 3'b001; sign = 3'b000; mul2 = 3'b110; div2 = 3'b000; end //     2    2    0
        8'd018: begin zero = 3'b001; sign = 3'b100; mul2 = 3'b010; div2 = 3'b000; end //    -1    2    0
        8'd019: begin zero = 3'b001; sign = 3'b100; mul2 = 3'b110; div2 = 3'b000; end //    -2    2    0
        8'd020: begin zero = 3'b101; sign = 3'b010; mul2 = 3'b000; div2 = 3'b010; end //     0 -0.5    0
        8'd021: begin zero = 3'b001; sign = 3'b010; mul2 = 3'b000; div2 = 3'b010; end //     1 -0.5    0
        8'd022: begin zero = 3'b001; sign = 3'b010; mul2 = 3'b100; div2 = 3'b010; end //     2 -0.5    0
        8'd023: begin zero = 3'b001; sign = 3'b110; mul2 = 3'b000; div2 = 3'b010; end //    -1 -0.5    0
        8'd024: begin zero = 3'b001; sign = 3'b110; mul2 = 3'b100; div2 = 3'b010; end //    -2 -0.5    0
        8'd025: begin zero = 3'b101; sign = 3'b010; mul2 = 3'b000; div2 = 3'b000; end //     0   -1    0
        8'd026: begin zero = 3'b001; sign = 3'b010; mul2 = 3'b000; div2 = 3'b000; end //     1   -1    0
        8'd027: begin zero = 3'b001; sign = 3'b010; mul2 = 3'b100; div2 = 3'b000; end //     2   -1    0
        8'd028: begin zero = 3'b001; sign = 3'b110; mul2 = 3'b000; div2 = 3'b000; end //    -1   -1    0
        8'd029: begin zero = 3'b001; sign = 3'b110; mul2 = 3'b100; div2 = 3'b000; end //    -2   -1    0
        8'd030: begin zero = 3'b101; sign = 3'b010; mul2 = 3'b010; div2 = 3'b000; end //     0   -2    0
        8'd031: begin zero = 3'b001; sign = 3'b010; mul2 = 3'b010; div2 = 3'b000; end //     1   -2    0
        8'd032: begin zero = 3'b001; sign = 3'b010; mul2 = 3'b110; div2 = 3'b000; end //     2   -2    0
        8'd033: begin zero = 3'b001; sign = 3'b110; mul2 = 3'b010; div2 = 3'b000; end //    -1   -2    0
        8'd034: begin zero = 3'b001; sign = 3'b110; mul2 = 3'b110; div2 = 3'b000; end //    -2   -2    0
        8'd035: begin zero = 3'b110; sign = 3'b000; mul2 = 3'b000; div2 = 3'b001; end //     0    0  0.5
        8'd036: begin zero = 3'b010; sign = 3'b000; mul2 = 3'b000; div2 = 3'b001; end //     1    0  0.5
        8'd037: begin zero = 3'b010; sign = 3'b000; mul2 = 3'b100; div2 = 3'b001; end //     2    0  0.5
        8'd038: begin zero = 3'b010; sign = 3'b100; mul2 = 3'b000; div2 = 3'b001; end //    -1    0  0.5
        8'd039: begin zero = 3'b010; sign = 3'b100; mul2 = 3'b100; div2 = 3'b001; end //    -2    0  0.5
        8'd040: begin zero = 3'b100; sign = 3'b000; mul2 = 3'b000; div2 = 3'b011; end //     0  0.5  0.5
        8'd041: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b000; div2 = 3'b011; end //     1  0.5  0.5
        8'd042: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b100; div2 = 3'b011; end //     2  0.5  0.5
        8'd043: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b000; div2 = 3'b011; end //    -1  0.5  0.5
        8'd044: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b100; div2 = 3'b011; end //    -2  0.5  0.5
        8'd045: begin zero = 3'b100; sign = 3'b000; mul2 = 3'b000; div2 = 3'b001; end //     0    1  0.5
        8'd046: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b000; div2 = 3'b001; end //     1    1  0.5
        8'd047: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b100; div2 = 3'b001; end //     2    1  0.5
        8'd048: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b000; div2 = 3'b001; end //    -1    1  0.5
        8'd049: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b100; div2 = 3'b001; end //    -2    1  0.5
        8'd050: begin zero = 3'b100; sign = 3'b000; mul2 = 3'b010; div2 = 3'b001; end //     0    2  0.5
        8'd051: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b010; div2 = 3'b001; end //     1    2  0.5
        8'd052: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b110; div2 = 3'b001; end //     2    2  0.5
        8'd053: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b010; div2 = 3'b001; end //    -1    2  0.5
        8'd054: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b110; div2 = 3'b001; end //    -2    2  0.5
        8'd055: begin zero = 3'b100; sign = 3'b010; mul2 = 3'b000; div2 = 3'b011; end //     0 -0.5  0.5
        8'd056: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b000; div2 = 3'b011; end //     1 -0.5  0.5
        8'd057: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b100; div2 = 3'b011; end //     2 -0.5  0.5
        8'd058: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b000; div2 = 3'b011; end //    -1 -0.5  0.5
        8'd059: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b100; div2 = 3'b011; end //    -2 -0.5  0.5
        8'd060: begin zero = 3'b100; sign = 3'b010; mul2 = 3'b000; div2 = 3'b001; end //     0   -1  0.5
        8'd061: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b000; div2 = 3'b001; end //     1   -1  0.5
        8'd062: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b100; div2 = 3'b001; end //     2   -1  0.5
        8'd063: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b000; div2 = 3'b001; end //    -1   -1  0.5
        8'd064: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b100; div2 = 3'b001; end //    -2   -1  0.5
        8'd065: begin zero = 3'b100; sign = 3'b010; mul2 = 3'b010; div2 = 3'b001; end //     0   -2  0.5
        8'd066: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b010; div2 = 3'b001; end //     1   -2  0.5
        8'd067: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b110; div2 = 3'b001; end //     2   -2  0.5
        8'd068: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b010; div2 = 3'b001; end //    -1   -2  0.5
        8'd069: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b110; div2 = 3'b001; end //    -2   -2  0.5
        8'd070: begin zero = 3'b110; sign = 3'b000; mul2 = 3'b000; div2 = 3'b000; end //     0    0    1
        8'd071: begin zero = 3'b010; sign = 3'b000; mul2 = 3'b000; div2 = 3'b000; end //     1    0    1
        8'd072: begin zero = 3'b010; sign = 3'b000; mul2 = 3'b100; div2 = 3'b000; end //     2    0    1
        8'd073: begin zero = 3'b010; sign = 3'b100; mul2 = 3'b000; div2 = 3'b000; end //    -1    0    1
        8'd074: begin zero = 3'b010; sign = 3'b100; mul2 = 3'b100; div2 = 3'b000; end //    -2    0    1
        8'd075: begin zero = 3'b100; sign = 3'b000; mul2 = 3'b000; div2 = 3'b010; end //     0  0.5    1
        8'd076: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b000; div2 = 3'b010; end //     1  0.5    1
        8'd077: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b100; div2 = 3'b010; end //     2  0.5    1
        8'd078: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b000; div2 = 3'b010; end //    -1  0.5    1
        8'd079: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b100; div2 = 3'b010; end //    -2  0.5    1
        8'd080: begin zero = 3'b100; sign = 3'b000; mul2 = 3'b000; div2 = 3'b000; end //     0    1    1
        8'd081: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b000; div2 = 3'b000; end //     1    1    1
        8'd082: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b100; div2 = 3'b000; end //     2    1    1
        8'd083: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b000; div2 = 3'b000; end //    -1    1    1
        8'd084: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b100; div2 = 3'b000; end //    -2    1    1
        8'd085: begin zero = 3'b100; sign = 3'b000; mul2 = 3'b010; div2 = 3'b000; end //     0    2    1
        8'd086: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b010; div2 = 3'b000; end //     1    2    1
        8'd087: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b110; div2 = 3'b000; end //     2    2    1
        8'd088: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b010; div2 = 3'b000; end //    -1    2    1
        8'd089: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b110; div2 = 3'b000; end //    -2    2    1
        8'd090: begin zero = 3'b100; sign = 3'b010; mul2 = 3'b000; div2 = 3'b010; end //     0 -0.5    1
        8'd091: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b000; div2 = 3'b010; end //     1 -0.5    1
        8'd092: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b100; div2 = 3'b010; end //     2 -0.5    1
        8'd093: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b000; div2 = 3'b010; end //    -1 -0.5    1
        8'd094: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b100; div2 = 3'b010; end //    -2 -0.5    1
        8'd095: begin zero = 3'b100; sign = 3'b010; mul2 = 3'b000; div2 = 3'b000; end //     0   -1    1
        8'd096: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b000; div2 = 3'b000; end //     1   -1    1
        8'd097: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b100; div2 = 3'b000; end //     2   -1    1
        8'd098: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b000; div2 = 3'b000; end //    -1   -1    1
        8'd099: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b100; div2 = 3'b000; end //    -2   -1    1
        8'd100: begin zero = 3'b100; sign = 3'b010; mul2 = 3'b010; div2 = 3'b000; end //     0   -2    1
        8'd101: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b010; div2 = 3'b000; end //     1   -2    1
        8'd102: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b110; div2 = 3'b000; end //     2   -2    1
        8'd103: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b010; div2 = 3'b000; end //    -1   -2    1
        8'd104: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b110; div2 = 3'b000; end //    -2   -2    1
        8'd105: begin zero = 3'b110; sign = 3'b000; mul2 = 3'b001; div2 = 3'b000; end //     0    0    2
        8'd106: begin zero = 3'b010; sign = 3'b000; mul2 = 3'b001; div2 = 3'b000; end //     1    0    2
        8'd107: begin zero = 3'b010; sign = 3'b000; mul2 = 3'b101; div2 = 3'b000; end //     2    0    2
        8'd108: begin zero = 3'b010; sign = 3'b100; mul2 = 3'b001; div2 = 3'b000; end //    -1    0    2
        8'd109: begin zero = 3'b010; sign = 3'b100; mul2 = 3'b101; div2 = 3'b000; end //    -2    0    2
        8'd110: begin zero = 3'b100; sign = 3'b000; mul2 = 3'b001; div2 = 3'b010; end //     0  0.5    2
        8'd111: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b001; div2 = 3'b010; end //     1  0.5    2
        8'd112: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b101; div2 = 3'b010; end //     2  0.5    2
        8'd113: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b001; div2 = 3'b010; end //    -1  0.5    2
        8'd114: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b101; div2 = 3'b010; end //    -2  0.5    2
        8'd115: begin zero = 3'b100; sign = 3'b000; mul2 = 3'b001; div2 = 3'b000; end //     0    1    2
        8'd116: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b001; div2 = 3'b000; end //     1    1    2
        8'd117: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b101; div2 = 3'b000; end //     2    1    2
        8'd118: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b001; div2 = 3'b000; end //    -1    1    2
        8'd119: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b101; div2 = 3'b000; end //    -2    1    2
        8'd120: begin zero = 3'b100; sign = 3'b000; mul2 = 3'b011; div2 = 3'b000; end //     0    2    2
        8'd121: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b011; div2 = 3'b000; end //     1    2    2
        8'd122: begin zero = 3'b000; sign = 3'b000; mul2 = 3'b111; div2 = 3'b000; end //     2    2    2
        8'd123: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b011; div2 = 3'b000; end //    -1    2    2
        8'd124: begin zero = 3'b000; sign = 3'b100; mul2 = 3'b111; div2 = 3'b000; end //    -2    2    2
        8'd125: begin zero = 3'b100; sign = 3'b010; mul2 = 3'b001; div2 = 3'b010; end //     0 -0.5    2
        8'd126: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b001; div2 = 3'b010; end //     1 -0.5    2
        8'd127: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b101; div2 = 3'b010; end //     2 -0.5    2
        8'd128: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b001; div2 = 3'b010; end //    -1 -0.5    2
        8'd129: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b101; div2 = 3'b010; end //    -2 -0.5    2
        8'd130: begin zero = 3'b100; sign = 3'b010; mul2 = 3'b001; div2 = 3'b000; end //     0   -1    2
        8'd131: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b001; div2 = 3'b000; end //     1   -1    2
        8'd132: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b101; div2 = 3'b000; end //     2   -1    2
        8'd133: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b001; div2 = 3'b000; end //    -1   -1    2
        8'd134: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b101; div2 = 3'b000; end //    -2   -1    2
        8'd135: begin zero = 3'b100; sign = 3'b010; mul2 = 3'b011; div2 = 3'b000; end //     0   -2    2
        8'd136: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b011; div2 = 3'b000; end //     1   -2    2
        8'd137: begin zero = 3'b000; sign = 3'b010; mul2 = 3'b111; div2 = 3'b000; end //     2   -2    2
        8'd138: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b011; div2 = 3'b000; end //    -1   -2    2
        8'd139: begin zero = 3'b000; sign = 3'b110; mul2 = 3'b111; div2 = 3'b000; end //    -2   -2    2
        8'd140: begin zero = 3'b110; sign = 3'b001; mul2 = 3'b000; div2 = 3'b001; end //     0    0 -0.5
        8'd141: begin zero = 3'b010; sign = 3'b001; mul2 = 3'b000; div2 = 3'b001; end //     1    0 -0.5
        8'd142: begin zero = 3'b010; sign = 3'b001; mul2 = 3'b100; div2 = 3'b001; end //     2    0 -0.5
        8'd143: begin zero = 3'b010; sign = 3'b101; mul2 = 3'b000; div2 = 3'b001; end //    -1    0 -0.5
        8'd144: begin zero = 3'b010; sign = 3'b101; mul2 = 3'b100; div2 = 3'b001; end //    -2    0 -0.5
        8'd145: begin zero = 3'b100; sign = 3'b001; mul2 = 3'b000; div2 = 3'b011; end //     0  0.5 -0.5
        8'd146: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b000; div2 = 3'b011; end //     1  0.5 -0.5
        8'd147: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b100; div2 = 3'b011; end //     2  0.5 -0.5
        8'd148: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b000; div2 = 3'b011; end //    -1  0.5 -0.5
        8'd149: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b100; div2 = 3'b011; end //    -2  0.5 -0.5
        8'd150: begin zero = 3'b100; sign = 3'b001; mul2 = 3'b000; div2 = 3'b001; end //     0    1 -0.5
        8'd151: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b000; div2 = 3'b001; end //     1    1 -0.5
        8'd152: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b100; div2 = 3'b001; end //     2    1 -0.5
        8'd153: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b000; div2 = 3'b001; end //    -1    1 -0.5
        8'd154: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b100; div2 = 3'b001; end //    -2    1 -0.5
        8'd155: begin zero = 3'b100; sign = 3'b001; mul2 = 3'b010; div2 = 3'b001; end //     0    2 -0.5
        8'd156: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b010; div2 = 3'b001; end //     1    2 -0.5
        8'd157: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b110; div2 = 3'b001; end //     2    2 -0.5
        8'd158: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b010; div2 = 3'b001; end //    -1    2 -0.5
        8'd159: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b110; div2 = 3'b001; end //    -2    2 -0.5
        8'd160: begin zero = 3'b100; sign = 3'b011; mul2 = 3'b000; div2 = 3'b011; end //     0 -0.5 -0.5
        8'd161: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b000; div2 = 3'b011; end //     1 -0.5 -0.5
        8'd162: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b100; div2 = 3'b011; end //     2 -0.5 -0.5
        8'd163: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b000; div2 = 3'b011; end //    -1 -0.5 -0.5
        8'd164: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b100; div2 = 3'b011; end //    -2 -0.5 -0.5
        8'd165: begin zero = 3'b100; sign = 3'b011; mul2 = 3'b000; div2 = 3'b001; end //     0   -1 -0.5
        8'd166: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b000; div2 = 3'b001; end //     1   -1 -0.5
        8'd167: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b100; div2 = 3'b001; end //     2   -1 -0.5
        8'd168: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b000; div2 = 3'b001; end //    -1   -1 -0.5
        8'd169: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b100; div2 = 3'b001; end //    -2   -1 -0.5
        8'd170: begin zero = 3'b100; sign = 3'b011; mul2 = 3'b010; div2 = 3'b001; end //     0   -2 -0.5
        8'd171: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b010; div2 = 3'b001; end //     1   -2 -0.5
        8'd172: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b110; div2 = 3'b001; end //     2   -2 -0.5
        8'd173: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b010; div2 = 3'b001; end //    -1   -2 -0.5
        8'd174: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b110; div2 = 3'b001; end //    -2   -2 -0.5
        8'd175: begin zero = 3'b110; sign = 3'b001; mul2 = 3'b000; div2 = 3'b000; end //     0    0   -1
        8'd176: begin zero = 3'b010; sign = 3'b001; mul2 = 3'b000; div2 = 3'b000; end //     1    0   -1
        8'd177: begin zero = 3'b010; sign = 3'b001; mul2 = 3'b100; div2 = 3'b000; end //     2    0   -1
        8'd178: begin zero = 3'b010; sign = 3'b101; mul2 = 3'b000; div2 = 3'b000; end //    -1    0   -1
        8'd179: begin zero = 3'b010; sign = 3'b101; mul2 = 3'b100; div2 = 3'b000; end //    -2    0   -1
        8'd180: begin zero = 3'b100; sign = 3'b001; mul2 = 3'b000; div2 = 3'b010; end //     0  0.5   -1
        8'd181: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b000; div2 = 3'b010; end //     1  0.5   -1
        8'd182: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b100; div2 = 3'b010; end //     2  0.5   -1
        8'd183: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b000; div2 = 3'b010; end //    -1  0.5   -1
        8'd184: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b100; div2 = 3'b010; end //    -2  0.5   -1
        8'd185: begin zero = 3'b100; sign = 3'b001; mul2 = 3'b000; div2 = 3'b000; end //     0    1   -1
        8'd186: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b000; div2 = 3'b000; end //     1    1   -1
        8'd187: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b100; div2 = 3'b000; end //     2    1   -1
        8'd188: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b000; div2 = 3'b000; end //    -1    1   -1
        8'd189: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b100; div2 = 3'b000; end //    -2    1   -1
        8'd190: begin zero = 3'b100; sign = 3'b001; mul2 = 3'b010; div2 = 3'b000; end //     0    2   -1
        8'd191: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b010; div2 = 3'b000; end //     1    2   -1
        8'd192: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b110; div2 = 3'b000; end //     2    2   -1
        8'd193: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b010; div2 = 3'b000; end //    -1    2   -1
        8'd194: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b110; div2 = 3'b000; end //    -2    2   -1
        8'd195: begin zero = 3'b100; sign = 3'b011; mul2 = 3'b000; div2 = 3'b010; end //     0 -0.5   -1
        8'd196: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b000; div2 = 3'b010; end //     1 -0.5   -1
        8'd197: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b100; div2 = 3'b010; end //     2 -0.5   -1
        8'd198: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b000; div2 = 3'b010; end //    -1 -0.5   -1
        8'd199: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b100; div2 = 3'b010; end //    -2 -0.5   -1
        8'd200: begin zero = 3'b100; sign = 3'b011; mul2 = 3'b000; div2 = 3'b000; end //     0   -1   -1
        8'd201: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b000; div2 = 3'b000; end //     1   -1   -1
        8'd202: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b100; div2 = 3'b000; end //     2   -1   -1
        8'd203: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b000; div2 = 3'b000; end //    -1   -1   -1
        8'd204: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b100; div2 = 3'b000; end //    -2   -1   -1
        8'd205: begin zero = 3'b100; sign = 3'b011; mul2 = 3'b010; div2 = 3'b000; end //     0   -2   -1
        8'd206: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b010; div2 = 3'b000; end //     1   -2   -1
        8'd207: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b110; div2 = 3'b000; end //     2   -2   -1
        8'd208: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b010; div2 = 3'b000; end //    -1   -2   -1
        8'd209: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b110; div2 = 3'b000; end //    -2   -2   -1
        8'd210: begin zero = 3'b110; sign = 3'b001; mul2 = 3'b001; div2 = 3'b000; end //     0    0   -2
        8'd211: begin zero = 3'b010; sign = 3'b001; mul2 = 3'b001; div2 = 3'b000; end //     1    0   -2
        8'd212: begin zero = 3'b010; sign = 3'b001; mul2 = 3'b101; div2 = 3'b000; end //     2    0   -2
        8'd213: begin zero = 3'b010; sign = 3'b101; mul2 = 3'b001; div2 = 3'b000; end //    -1    0   -2
        8'd214: begin zero = 3'b010; sign = 3'b101; mul2 = 3'b101; div2 = 3'b000; end //    -2    0   -2
        8'd215: begin zero = 3'b100; sign = 3'b001; mul2 = 3'b001; div2 = 3'b010; end //     0  0.5   -2
        8'd216: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b001; div2 = 3'b010; end //     1  0.5   -2
        8'd217: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b101; div2 = 3'b010; end //     2  0.5   -2
        8'd218: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b001; div2 = 3'b010; end //    -1  0.5   -2
        8'd219: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b101; div2 = 3'b010; end //    -2  0.5   -2
        8'd220: begin zero = 3'b100; sign = 3'b001; mul2 = 3'b001; div2 = 3'b000; end //     0    1   -2
        8'd221: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b001; div2 = 3'b000; end //     1    1   -2
        8'd222: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b101; div2 = 3'b000; end //     2    1   -2
        8'd223: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b001; div2 = 3'b000; end //    -1    1   -2
        8'd224: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b101; div2 = 3'b000; end //    -2    1   -2
        8'd225: begin zero = 3'b100; sign = 3'b001; mul2 = 3'b011; div2 = 3'b000; end //     0    2   -2
        8'd226: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b011; div2 = 3'b000; end //     1    2   -2
        8'd227: begin zero = 3'b000; sign = 3'b001; mul2 = 3'b111; div2 = 3'b000; end //     2    2   -2
        8'd228: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b011; div2 = 3'b000; end //    -1    2   -2
        8'd229: begin zero = 3'b000; sign = 3'b101; mul2 = 3'b111; div2 = 3'b000; end //    -2    2   -2
        8'd230: begin zero = 3'b100; sign = 3'b011; mul2 = 3'b001; div2 = 3'b010; end //     0 -0.5   -2
        8'd231: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b001; div2 = 3'b010; end //     1 -0.5   -2
        8'd232: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b101; div2 = 3'b010; end //     2 -0.5   -2
        8'd233: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b001; div2 = 3'b010; end //    -1 -0.5   -2
        8'd234: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b101; div2 = 3'b010; end //    -2 -0.5   -2
        8'd235: begin zero = 3'b100; sign = 3'b011; mul2 = 3'b001; div2 = 3'b000; end //     0   -1   -2
        8'd236: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b001; div2 = 3'b000; end //     1   -1   -2
        8'd237: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b101; div2 = 3'b000; end //     2   -1   -2
        8'd238: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b001; div2 = 3'b000; end //    -1   -1   -2
        8'd239: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b101; div2 = 3'b000; end //    -2   -1   -2
        8'd240: begin zero = 3'b100; sign = 3'b011; mul2 = 3'b011; div2 = 3'b000; end //     0   -2   -2
        8'd241: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b011; div2 = 3'b000; end //     1   -2   -2
        8'd242: begin zero = 3'b000; sign = 3'b011; mul2 = 3'b111; div2 = 3'b000; end //     2   -2   -2
        8'd243: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b011; div2 = 3'b000; end //    -1   -2   -2
        8'd244: begin zero = 3'b000; sign = 3'b111; mul2 = 3'b111; div2 = 3'b000; end //    -2   -2   -2
        default: {zero, sign, mul2, div2} = {3'b111, 3'b0, 3'b0, 3'b0}; // Default case
        endcase
    end
endmodule
