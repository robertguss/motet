## BEAM actor tracking standing bot routines and self-scheduled check-ins.
module Scheduler
expose SchedulerActor, TrackedRoutine(..), SchedulerOverview(..)

struct TrackedRoutine
  key: Text
  bot_name: Text
  name: Text
  due?: Bool
  runs: Int
end

struct SchedulerOverview
  ticks: Int
  total_runs: Int
  routines: List(TrackedRoutine)
end

struct SchedulerState
  routines: Map(Text, TrackedRoutine)
  ticks: Int
  total_runs: Int
end

actor SchedulerActor
  state SchedulerState = SchedulerState(routines: {}, ticks: 0, total_runs: 0)
  calls register_routine, mark_ran, overview
  every 1.minute tick_due

  promise
    after.ticks >= before.ticks
    after.total_runs >= before.total_runs
  end
end

fn register_routine(state: SchedulerState, _now: Time, bot_name: Text, name: Text) : (
  SchedulerState,
  TrackedRoutine
)
  key = "#{bot_name}:#{name}"
  item = case state.routines.get(key)
    Some(prev): prev
    None: TrackedRoutine(key: key, bot_name: bot_name, name: name, due?: true, runs: 0)
  end
  (
    SchedulerState(
      routines: state.routines.set(key, item),
      ticks: state.ticks,
      total_runs: state.total_runs
    ),
    item
  )
end

fn mark_ran(state: SchedulerState, _now: Time, bot_name: Text, name: Text) : (
  SchedulerState,
  TrackedRoutine
)
  key = "#{bot_name}:#{name}"
  prev_runs = case state.routines.get(key)
    Some(prev): prev.runs
    None: 0
  end
  updated = TrackedRoutine(
    key: key,
    bot_name: bot_name,
    name: name,
    due?: false,
    runs: prev_runs.saturating_add(1)
  )
  next = SchedulerState(
    routines: state.routines.set(key, updated),
    ticks: state.ticks,
    total_runs: state.total_runs.saturating_add(1)
  )
  (next, updated)
end

fn overview(state: SchedulerState, _now: Time) : SchedulerOverview
  SchedulerOverview(
    ticks: state.ticks,
    total_runs: state.total_runs,
    routines: state.routines.values
  )
end

fn tick_due(state: SchedulerState, _now: Time) : SchedulerState
  var next = {}
  for (k, r) in state.routines.entries
    next = next.set(
      k,
      TrackedRoutine(key: r.key, bot_name: r.bot_name, name: r.name, due?: true, runs: r.runs)
    )
  end
  SchedulerState(routines: next, ticks: state.ticks.saturating_add(1), total_runs: state.total_runs)
end

test "SchedulerActor marks routines due on timer ticks"
  sched = Actor.start(SchedulerActor)
  r0 = sched.register_routine("watcher", "t3-health")
  assert r0.due?
  r1 = sched.mark_ran("watcher", "t3-health")
  assert not r1.due? and r1.runs == 1
  Actor.advance(sched, 1.minute)
  ov = sched.overview
  assert ov.ticks >= 1 and ov.total_runs == 1
  assert ov.routines.first is Some(after_tick) and after_tick.due?
end
