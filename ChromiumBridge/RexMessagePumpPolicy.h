#pragma once

#include <climits>
#include <cstdint>

namespace rex::message_pump {

// Match CEF's external-pump sample: bound wake latency without running a
// continuously repeating timer. The marker is only used for our watchdog.
constexpr std::int64_t kMaximumTimerDelayMs = 1000 / 30;
constexpr std::int64_t kFallbackDelayMarker = INT_MAX;

enum class ScheduleAction {
  KeepPendingTimer,
  RunImmediately,
  SetTimer,
};

struct ScheduleDecision {
  ScheduleAction action;
  std::int64_t delay_ms;

  constexpr bool operator==(const ScheduleDecision &) const = default;
};

constexpr ScheduleDecision SelectSchedule(std::int64_t requested_delay_ms,
                                          bool timer_pending) {
  if (requested_delay_ms == kFallbackDelayMarker && timer_pending) {
    return {ScheduleAction::KeepPendingTimer, 0};
  }
  if (requested_delay_ms <= 0) {
    return {ScheduleAction::RunImmediately, 0};
  }
  return {ScheduleAction::SetTimer,
          requested_delay_ms > kMaximumTimerDelayMs
              ? kMaximumTimerDelayMs
              : requested_delay_ms};
}

static_assert(SelectSchedule(0, false) ==
              ScheduleDecision{ScheduleAction::RunImmediately, 0});
static_assert(SelectSchedule(-1, true) ==
              ScheduleDecision{ScheduleAction::RunImmediately, 0});
static_assert(SelectSchedule(10, false) ==
              ScheduleDecision{ScheduleAction::SetTimer, 10});
static_assert(SelectSchedule(1000, false) ==
              ScheduleDecision{ScheduleAction::SetTimer,
                               kMaximumTimerDelayMs});
static_assert(SelectSchedule(kFallbackDelayMarker, true) ==
              ScheduleDecision{ScheduleAction::KeepPendingTimer, 0});

}  // namespace rex::message_pump
