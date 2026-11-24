#pragma once
#include <array>
#include <atomic>
#include <cstdint>
#include <type_traits>

namespace loop2
{
// Bounded multi-producer/single-consumer sequence queue. No locks or allocation.
// Producers may fail on full/contention; callers must provide an overflow policy.
template <typename T, size_t Capacity>
class RealtimeQueue
{
    static_assert(Capacity > 1 && (Capacity & (Capacity - 1)) == 0);
    static_assert(std::is_trivially_copyable_v<T>);
    static_assert(std::atomic<size_t>::is_always_lock_free);
    struct Cell { std::atomic<size_t> sequence { 0 }; T value {}; };
public:
    RealtimeQueue()
    {
        for (size_t i = 0; i < Capacity; ++i) cells[i].sequence.store(i);
    }
    bool push(const T& value)
    {
        auto position = write.load(std::memory_order_relaxed);
        for (int attempt = 0; attempt < 16; ++attempt)
        {
            auto& cell = cells[position & (Capacity - 1)];
            const auto sequence = cell.sequence.load(std::memory_order_acquire);
            const auto difference = static_cast<intptr_t>(sequence - position);
            if (difference == 0)
            {
                if (write.compare_exchange_weak(position, position + 1, std::memory_order_relaxed))
                {
                    cell.value = value;
                    cell.sequence.store(position + 1, std::memory_order_release);
                    return true;
                }
            }
            else if (difference < 0) return false;
            else position = write.load(std::memory_order_relaxed);
        }
        return false;
    }
    bool pop(T& value) // only the audio consumer
    {
        auto& cell = cells[read & (Capacity - 1)];
        if (cell.sequence.load(std::memory_order_acquire) != read + 1) return false;
        value = cell.value;
        cell.sequence.store(read + Capacity, std::memory_order_release);
        ++read;
        return true;
    }
private:
    std::array<Cell, Capacity> cells;
    alignas(64) std::atomic<size_t> write { 0 };
    alignas(64) size_t read = 0;
};
}
