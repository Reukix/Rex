#include "RexThoriumFlags.h"

#include "RexThoriumPolicy.h"

#include <cstdint>
#include <set>
#include <sstream>
#include <string>
#include <sys/sysctl.h>
#include <vector>

namespace rex::thorium {
namespace {

constexpr std::uint64_t kGiB = 1024ULL * 1024ULL * 1024ULL;

static_assert(SelectAdaptivePerformancePolicy(8ULL * kGiB, 8) ==
              AdaptivePerformancePolicy{4, 512, true, 4, true});
static_assert(SelectAdaptivePerformancePolicy(16ULL * kGiB, 8) ==
              AdaptivePerformancePolicy{8, 768, false, 4, false});
static_assert(SelectAdaptivePerformancePolicy(24ULL * kGiB, 10) ==
              AdaptivePerformancePolicy{10, 1024, false, 6, false});
static_assert(SelectAdaptivePerformancePolicy(128ULL * kGiB, 32) ==
              AdaptivePerformancePolicy{16, 1536, false, 8, false});
static_assert(SelectAdaptivePerformancePolicy(0, 0) ==
              AdaptivePerformancePolicy{8, 768, false, 4, false});

std::uint64_t PhysicalMemoryBytes() {
  std::uint64_t value = 0;
  size_t size = sizeof(value);
  return sysctlbyname("hw.memsize", &value, &size, nullptr, 0) == 0 &&
                 size == sizeof(value)
             ? value
             : 0;
}

std::uint32_t LogicalCPUCount() {
  std::uint32_t value = 0;
  size_t size = sizeof(value);
  return sysctlbyname("hw.logicalcpu", &value, &size, nullptr, 0) == 0 &&
                 size == sizeof(value)
             ? value
             : 0;
}

void AppendIfMissing(CefRefPtr<CefCommandLine> command_line,
                     const char *name,
                     const char *value = nullptr) {
  if (!command_line || !name) return;
  if (command_line->HasSwitch(name)) return;
  if (value) {
    command_line->AppendSwitchWithValue(name, value);
  } else {
    command_line->AppendSwitch(name);
  }
}

std::vector<std::string> SplitCSV(const std::string &value) {
  std::vector<std::string> parts;
  std::stringstream stream(value);
  std::string item;
  while (std::getline(stream, item, ',')) {
    if (!item.empty()) parts.push_back(item);
  }
  return parts;
}

// Merge CSV switch values so CEF defaults and Rex policy coexist.
void MergeCSVSwitch(CefRefPtr<CefCommandLine> command_line,
                    const char *name,
                    const char *extra_values) {
  if (!command_line || !name || !extra_values) return;
  std::set<std::string> values;
  if (command_line->HasSwitch(name)) {
    for (const auto &part : SplitCSV(command_line->GetSwitchValue(name).ToString())) {
      values.insert(part);
    }
  }
  for (const auto &part : SplitCSV(extra_values)) {
    values.insert(part);
  }
  std::string merged;
  for (const auto &part : values) {
    if (!merged.empty()) merged.push_back(',');
    merged += part;
  }
  if (!merged.empty()) {
    command_line->AppendSwitchWithValue(name, merged);
  }
}

void RemoveFromCSVSwitch(CefRefPtr<CefCommandLine> command_line,
                         const char *name,
                         const char *remove_value) {
  if (!command_line || !name || !remove_value || !command_line->HasSwitch(name)) return;
  std::set<std::string> values;
  for (const auto &part : SplitCSV(command_line->GetSwitchValue(name).ToString())) {
    if (part != remove_value) values.insert(part);
  }
  std::string merged;
  for (const auto &part : values) {
    if (!merged.empty()) merged.push_back(',');
    merged += part;
  }
  // CefCommandLine has no RemoveSwitch; overwrite with cleaned CSV.
  command_line->AppendSwitchWithValue(name, merged);
}

// Aggressive Thorium compositor flags that caused CEF reparent white tiles
// on macOS arm64 host views. Keep them forced off.
void ForceDisablePaintRiskSwitches(CefRefPtr<CefCommandLine> command_line) {
  if (!command_line) return;
  AppendIfMissing(command_line, "disable-zero-copy");
  AppendIfMissing(command_line, "disable-gpu-memory-buffer-compositor-resources");
  AppendIfMissing(command_line, "disable-gpu-memory-buffer-video-frames");
  RemoveFromCSVSwitch(command_line, "enable-features", "RawDraw");
  RemoveFromCSVSwitch(command_line, "enable-features", "CanvasOopRasterizationRawDraw");
  MergeCSVSwitch(command_line, "disable-features",
                 "RawDraw,CanvasOopRasterizationRawDraw,"
                 "InterestFeedContentSuggestions");
}

}  // namespace

void ApplyBrowserProcessFlags(CefRefPtr<CefCommandLine> command_line) {
  if (!command_line) return;

  // Baseline from Rex.
  AppendIfMissing(command_line, "no-proxy-server");

  // Thorium-style graphics and compositor throughput on Apple Silicon.
  // Conservative subset: GPU raster + Canvas OOP + network/process policy.
  // Never re-enable zero-copy / RawDraw / native GPU memory buffer compositor.
  AppendIfMissing(command_line, "enable-gpu-rasterization");
  AppendIfMissing(command_line, "canvas-oop-rasterization");
  MergeCSVSwitch(command_line, "enable-features",
                 "CanvasOopRasterization,ParallelDownloading,"
                 "BackForwardCache,PartitionedCookies");
  ForceDisablePaintRiskSwitches(command_line);

  // Networking / IO responsiveness (Thorium-inspired safe subset).
  AppendIfMissing(command_line, "enable-quic");
  AppendIfMissing(command_line, "enable-tcp-fast-open");
  AppendIfMissing(command_line, "max-active-webgl-contexts", "16");

  // v1.3: pin ANGLE to Metal explicitly so the GPU process never probes the
  // legacy OpenGL path on Apple Silicon.
  AppendIfMissing(command_line, "use-angle", "metal");

  // Bound renderer parallelism, raster threads and V8 heaps to this Mac's
  // shared-memory and CPU capacity. Explicit overrides remain authoritative.
  const AdaptivePerformancePolicy policy = SelectAdaptivePerformancePolicy(
      PhysicalMemoryBytes(), LogicalCPUCount());
  const std::string renderer_limit =
      std::to_string(policy.renderer_process_limit);
  const std::string raster_threads = std::to_string(policy.raster_threads);
  std::string js_flags = "--max-old-space-size=" +
                         std::to_string(policy.v8_old_space_megabytes);
  if (policy.optimize_for_size) {
    js_flags += " --optimize-for-size";
  }
  AppendIfMissing(command_line, "num-raster-threads", raster_threads.c_str());
  AppendIfMissing(command_line, "process-per-site");
  AppendIfMissing(command_line, "renderer-process-limit",
                  renderer_limit.c_str());
  AppendIfMissing(command_line, "js-flags", js_flags.c_str());
  if (policy.disable_spare_renderer) {
    // Low-memory tier: skip the pre-warmed spare renderer process.
    MergeCSVSwitch(command_line, "disable-features",
                   "SpareRendererForSitePerProcess");
  }

  // Reduce background noise similar to Thorium privacy defaults.
  MergeCSVSwitch(command_line, "disable-features",
                 "AutofillServerCommunication,OptimizationHints,MediaRouter");
}

void ApplyChildProcessFlags(CefRefPtr<CefCommandLine> command_line) {
  if (!command_line) return;
  AppendIfMissing(command_line, "no-proxy-server");
  AppendIfMissing(command_line, "enable-gpu-rasterization");
  AppendIfMissing(command_line, "canvas-oop-rasterization");
  AppendIfMissing(command_line, "use-angle", "metal");
  ForceDisablePaintRiskSwitches(command_line);
}

}  // namespace rex::thorium
