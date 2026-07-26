#pragma once

#include <cstdint>

namespace rex::thorium {

struct AdaptivePerformancePolicy {
  std::uint32_t renderer_process_limit;
  std::uint32_t v8_old_space_megabytes;
  bool optimize_for_size;
  // v1.3: raster threads scale with CPU throughput instead of a fixed 4.
  std::uint32_t raster_threads;
  // v1.3: low-memory machines skip the warm spare renderer (~150 MB saved);
  // larger machines keep it for faster cross-site navigation.
  bool disable_spare_renderer;

  constexpr bool operator==(const AdaptivePerformancePolicy &) const = default;
};

// Pure policy kept separate from CEF and sysctl so capacity tiers can be
// validated at compile time and exercised by a future standalone test target.
constexpr AdaptivePerformancePolicy SelectAdaptivePerformancePolicy(
    std::uint64_t physical_memory_bytes,
    std::uint32_t logical_cpu_count) {
  constexpr std::uint64_t kGiB = 1024ULL * 1024ULL * 1024ULL;

  // Failed probes use a bounded mid-range Apple Silicon profile.
  const std::uint64_t memory =
      physical_memory_bytes == 0 ? 16ULL * kGiB : physical_memory_bytes;
  const std::uint32_t cpus = logical_cpu_count == 0 ? 8 : logical_cpu_count;

  // Budget one renderer slot per 2 GiB, then cap by available CPU throughput.
  const std::uint64_t memory_slots_unbounded = memory / (2ULL * kGiB);
  const std::uint32_t memory_slots =
      memory_slots_unbounded < 2
          ? 2
          : (memory_slots_unbounded > 16
                 ? 16
                 : static_cast<std::uint32_t>(memory_slots_unbounded));
  const std::uint32_t cpu_slots = cpus < 2 ? 2 : (cpus > 16 ? 16 : cpus);
  const std::uint32_t renderer_limit =
      memory_slots < cpu_slots ? memory_slots : cpu_slots;

  // V8 limits remain bounded per renderer; larger heaps are reserved for
  // machines that can absorb their worst-case shared-memory pressure.
  const std::uint32_t old_space_megabytes =
      memory <= 8ULL * kGiB
          ? 512
          : (memory <= 16ULL * kGiB
                 ? 768
                 : (memory <= 32ULL * kGiB ? 1024 : 1536));

  // Raster threads follow CPU width with diminishing returns past 8.
  const std::uint32_t raster_threads =
      cpus <= 8 ? 4 : (cpus <= 12 ? 6 : 8);

  const bool low_memory = memory <= 8ULL * kGiB;
  return {renderer_limit, old_space_megabytes, low_memory, raster_threads,
          low_memory};
}

}  // namespace rex::thorium
