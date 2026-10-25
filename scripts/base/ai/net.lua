-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Integer neural networks of the AI (OpenLF2 extension, docs/ai-plan.md "Learning"): a small network that a tool
-- trained outside the game (tools/ai-imitate.py) runs here with whole numbers only, so every computer of a network
-- game gets the same answer. Fixed point: a value v is the integer v * scale. The inputs (whole numbers) become
-- input * scale; each layer computes floor(sum(weight * value) / scale) + bias, with weights and biases as integers
-- scaled by `scale`, and the hidden layers keep the positive part (ReLU). The sums stay far below 2^53 for the small
-- inputs and weights that the tool writes.
--
-- A network: {scale, layers = {{inputs, outputs, weights = {row by row: outputs x inputs}, biases = {...}}...}}.
local net = {}

local scratch_a, scratch_b = {}, {}

-- The outputs of `network` for the integer `inputs` (an array), in a reused array: read it at once.
local fixed = {}
function net.run(network, inputs)
    local scale = network.scale
    for position = 1, #inputs do fixed[position] = inputs[position] * scale end
    for position = #inputs + 1, #fixed do fixed[position] = nil end
    local current, following = fixed, scratch_a
    for number, layer in ipairs(network.layers) do
        local weights, biases, count_in = layer.weights, layer.biases, layer.inputs
        for out = 1, layer.outputs do
            local sum, base = 0, (out - 1) * count_in
            for position = 1, count_in do sum = sum + weights[base + position] * current[position] end
            sum = math.floor(sum / scale) + biases[out]
            if number < #network.layers and sum < 0 then sum = 0 end
            following[out] = sum
        end
        for position = layer.outputs + 1, #following do following[position] = nil end
        current = following
        following = following == scratch_a and scratch_b or scratch_a
    end
    return current
end

-- The index of the largest output (the first one on a tie).
function net.argmax(outputs)
    local best, best_value = 1, outputs[1]
    for position = 2, #outputs do
        if outputs[position] > best_value then best, best_value = position, outputs[position] end
    end
    return best
end
return net
