// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
#include <array>
#include <cstdint>

namespace openlf2 {
// The C runtime rand() the original game uses (214013/2531011 LCG, bits 16..30).
class CrtRandom {
public:
    explicit CrtRandom(std::uint32_t seed) : state_(seed) {}
    std::int32_t next() {
        state_ = state_ * 214013U + 2531011U;
        return static_cast<std::int32_t>((state_ >> 16) & 0x7fffU);
    }
    [[nodiscard]] std::uint32_t state() const { return state_; }
    void restore(std::uint32_t state) { state_ = state; }
private:
    std::uint32_t state_;
};

class CompatibilityRandom {
public:
    static constexpr std::size_t table_size = 3000;

    explicit CompatibilityRandom(std::uint32_t seed) : crt_(seed) {}
    void fill_table() {
        for (auto& entry : table_) entry = static_cast<std::uint8_t>(crt_.next() % 255 + 1);
    }
    std::int32_t next(std::int32_t range) {
        if (range <= 0) return 0;
        sequence_ = (sequence_ + 1) % 1234;
        index_ = (index_ + 1) % static_cast<std::int32_t>(table_size);
        return (table_[static_cast<std::size_t>(index_)] + sequence_) % range;
    }
    std::int32_t crt() { return crt_.next(); }
    void reset_sequence() { sequence_ = 0; }
    [[nodiscard]] const std::array<std::uint8_t, table_size>& table() const { return table_; }
    [[nodiscard]] std::int32_t index() const { return index_; }
    void restore(const std::array<std::uint8_t, table_size>& table, std::int32_t index) {
        table_ = table;
        index_ = index;
    }
    // Where both streams are, without the table (which a match does not change): a rollback restores it.
    [[nodiscard]] std::int32_t sequence() const { return sequence_; }
    [[nodiscard]] std::uint32_t crt_state() const { return crt_.state(); }
    void restore_position(std::int32_t index, std::int32_t sequence, std::uint32_t crt_state) {
        index_ = index;
        sequence_ = sequence;
        crt_.restore(crt_state);
    }

private:
    CrtRandom crt_;
    std::array<std::uint8_t, table_size> table_{};
    std::int32_t sequence_ = 0;
    std::int32_t index_ = 0;
};
}
