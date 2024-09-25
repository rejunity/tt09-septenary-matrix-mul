import itertools

def all_combinations(possible_set, repeats):
    return itertools.product(possible_set, repeat=repeats)  # Generates all combinations
def find_max_size(combinations, pack_fn):
    max_size = 0
    for combo in combinations:
        max_size = max(pack_fn(combo)+1, max_size)
    return max_size
def check_if_all_unique(combinations, pack_fn):
    max_size = find_max_size(combinations, pack_fn)
    unique = [0] * max_size
    for combo in combinations:
        packed = pack_fn(combo)
        if unique[packed] != 0:
            return False, packed, unique
        unique[packed] += 1
    return True
def check_if_all_match(combinations, pack_fn, unpack_fn):
    for combo in combinations:
        unpacked = unpack_fn(pack_fn(combo))
        if list(combo) != list(unpacked):
            return False, combo, "!=", unpacked
    return True

def pack_ternary_weights(weights):
    packed = 0
    for i in weights:
        if i == 0: w =   00
        if i > 0:  w = 0b01
        if i < 0:  w = 0b10
        packed = (packed * 3) + w
    return packed

def unpack_ternary_weights(packed, number_of_weights=5):
    weights = []
    for _ in range(number_of_weights):
        w = packed % 3
        weights.append(w if w != 0b10 else -1)
        packed //= 3
    return weights[::-1]
ternary = [-1,0,1]
assert find_max_size(all_combinations(ternary, 5), pack_ternary_weights) <= 255
assert find_max_size(all_combinations(ternary, 5), pack_ternary_weights) <= 3**5
assert check_if_all_unique(all_combinations(ternary, 5), pack_ternary_weights) == True
assert check_if_all_match(all_combinations(ternary, 5),  pack_ternary_weights, unpack_ternary_weights) == True

# septenery_mapping = {-2:6, -1:5, -.5:4, 0:0, .5:1, 1:2, 2:3} # 7 states
# quinary_mapping_a = {-2:4, -1:3,        0:0,       1:1, 2:2} # 5 states
# quinary_mapping_b = {      -1:4, -.5:3, 0:0, .5:1, 1:2     } # 5 states

def find_closest_index(arr, target):
    return min(range(len(arr)), key=lambda i: abs(arr[i] - target))

septenery_mapping = [0, .5, 1, 2, -.5, -1, -2] # 7 positions
quinary_mapping_a = [0,     1, 2,      -1, -2] # 5 positions
quinary_mapping_b = [0, .5, 1, 2, -.5, -1    ] # 5 positions
# quinary_mapping_a = {-2:4, -1:3,        0:0,       1:1, 2:2} # 5 states
# quinary_mapping_b = {      -1:4, -.5:3, 0:0, .5:1, 1:2     } # 5 states

def pack_775_weights(weights, quinary_mapping = quinary_mapping_a):
    packed = 0
    for w, n in zip(weights, itertools.cycle([7,7,5])):
        mapping = quinary_mapping if (n == 5) else septenery_mapping
        packed = (packed * n) + find_closest_index(mapping, w)
    return packed

def unpack_775_weights(packed, number_of_weights=3, quinary_mapping = quinary_mapping_a):
    weights = []
    # Inverting the dictionary
    for _, n in zip(range(number_of_weights), itertools.cycle(reversed([7,7,5]))):
        mapping = quinary_mapping if (n == 5) else septenery_mapping
        weights.append(mapping[packed % n])
        packed //= n
    return weights[::-1]

quinary   = [-2,-1,    0,   1,2]
septenery = [-2,-1,-.5,0,.5,1,2]
assert find_max_size(all_combinations(septenery, 3), pack_775_weights) <= 255
assert find_max_size(all_combinations(septenery, 3), pack_775_weights) == 7*7*5
assert check_if_all_unique(all_combinations(septenery, 3), pack_775_weights) == True
assert check_if_all_match(all_combinations(quinary, 3), pack_775_weights, unpack_775_weights) == True
assert check_if_all_match(itertools.product(septenery, septenery, quinary), pack_775_weights, unpack_775_weights) == True



def generate_verilog_module_to_unpack_ternary_weights(reverse_weight_order = True):
    print(\
        "module unpack_ternary_weights(input      [7:0] packed_weights,\n"
        "                              output reg [4:0] zero,\n"
        "                              output reg [4:0] sign);\n"
        "    always @(*) begin\n"
        "        case(packed_weights)")

    unpack_weights = unpack_ternary_weights
    for i in range(3**5):
        weights_zero = 0b111_11 # if i != 0 else 1
        weights_sign = 0
        unpacked = unpack_weights(i)
        for w in (reversed(unpacked) if reverse_weight_order else unpacked):
            weights_zero = (weights_zero << 1) | (w == 0)
            weights_sign = (weights_sign << 1) | (w  < 0)
        weights_zero &= 0b111_11

        pretty_printed = ''.join([f"{str(n):>3}" for n in unpack_weights(i)])
        print(f"        8'd{str(i).zfill(3)}: begin"
            f" zero = 5'b{bin(weights_zero)[2:].zfill(5)};"
            f" sign = 5'b{bin(weights_sign)[2:].zfill(5)};"
            f" end // {pretty_printed}")
    print(\
        "        default: {zero, sign} = {5'b11_111, 5'b0}; // Default case\n"
        "        endcase\n"
        "    end\n"
        "endmodule\n")

def generate_verilog_module_to_unpack_775_weights(reverse_weight_order = True):
    print(\
        "module unpack_775_weights(input      [7:0] packed_weights,\n"
        "                          output reg [2:0] zero,\n"
        "                          output reg [2:0] sign,\n"
        "                          output reg [2:0] mul2,\n"
        "                          output reg [2:0] div2);\n"
        "    always @(*) begin\n"
        "        case(packed_weights)")

    unpack_weights = unpack_775_weights
    for i in range(7*7*5):
        zero = 0b111 # if i != 0 else 1
        sign = 0
        mul2 = 0
        div2 = 0
        unpacked = unpack_weights(i)
        for w in (reversed(unpacked) if reverse_weight_order else unpacked):
            zero = (zero << 1) | (w == 0)
            sign = (sign << 1) | (w  < 0)
            mul2 = (mul2 << 1) | (abs(w) ==  2)
            div2 = (div2 << 1) | (abs(w) == .5)
        zero &= 0b111

        pretty_printed = ''.join([f"{str(n):>5}" \
            for n in (reversed(unpacked) if reverse_weight_order else unpacked)])
        print(f"        8'd{str(i).zfill(3)}: begin"
            f" zero = 3'b{bin(zero)[2:].zfill(3)};"
            f" sign = 3'b{bin(sign)[2:].zfill(3)};"
            f" mul2 = 3'b{bin(mul2)[2:].zfill(3)};"
            f" div2 = 3'b{bin(div2)[2:].zfill(3)};"
            f" end // {pretty_printed}")
    print(\
        "        default: {zero, sign, mul2, div2} = {3'b111, 3'b0, 3'b0, 3'b0}; // Default case\n"
        "        endcase\n"
        "    end\n"
        "endmodule\n")


#generate_verilog_module_to_unpack_ternary_weights()
generate_verilog_module_to_unpack_775_weights()
