## Wall-clock IANA timezone scheduler, quiet-hours evaluator, at-most-once slot calculator,
## and BEAM actor tracking standing bot routines for Motet.
module Scheduler
expose SchedulerActor,
TrackedRoutine(..),
SchedulerOverview(..),
LocalClock(..),
utc_offset_minutes,
to_local_clock,
parse_hhmm,
in_quiet_hours?,
evaluate_wall_clock_slot,
compute_next_due_text
use Date

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

struct LocalClock
  date: Date.Date
  hour: Int
  minute: Int
  weekday_code: Text
  offset_minutes: Int
end

fn weekday_to_code(w: Date.Weekday) : Text
  case w
    Date.Monday: "mon"
    Date.Tuesday: "tue"
    Date.Wednesday: "wed"
    Date.Thursday: "thu"
    Date.Friday: "fri"
    Date.Saturday: "sat"
    Date.Sunday: "sun"
  end
end

fn is_weekday?(code: Text) : Bool
  code == "mon" or code == "tue" or code == "wed" or code == "thu" or code == "fri"
end

fn is_weekend?(code: Text) : Bool
  code == "sat" or code == "sun"
end

## Returns the day-of-month of the Nth Sunday (1-indexed) for `(year, month)`.
fn nth_sunday(year: Int, month: Int, n: Int) : Int
  var count = 0
  var d = 1
  max_d = Date.days_in_month(year, month)
  while d <= max_d
    case Date.from_ymd(year, month, d)
      Some(dt) if dt.weekday == Date.Sunday:
        count += 1
        return d if count == n
      Some(_) | None: Unit
    end
    d += 1
  end
  1
end

## Returns the day-of-month of the last Sunday in `(year, month)`.
fn last_sunday(year: Int, month: Int) : Int
  var d = Date.days_in_month(year, month)
  while d >= 1
    case Date.from_ymd(year, month, d)
      Some(dt) if dt.weekday == Date.Sunday: return d
      Some(_) | None: Unit
    end
    d -= 1
  end
  25
end

## US DST rule (2nd Sunday in March to 1st Sunday in November).
fn us_dst_active?(utc_date: Date.Date) : Bool
  m = utc_date.month
  return false if m < 3 or m > 11
  return true if m > 3 and m < 11
  if m == 3
    utc_date.day >= nth_sunday(utc_date.year, 3, 2)
  else
    utc_date.day < nth_sunday(utc_date.year, 11, 1)
  end
end

## EU DST rule (last Sunday in March to last Sunday in October).
fn eu_dst_active?(utc_date: Date.Date) : Bool
  m = utc_date.month
  return false if m < 3 or m > 10
  return true if m > 3 and m < 10
  if m == 3
    utc_date.day >= last_sunday(utc_date.year, 3)
  else
    utc_date.day < last_sunday(utc_date.year, 10)
  end
end

## Resolves UTC offset in minutes for common IANA timezones (with DST) or `UTC±H` / `UTC±HH:MM`.
fn utc_offset_minutes(tz: Text, utc_date: Date.Date) : Int
  promise "UTC offset is bounded between -12h and +14h"
    result >= -720 and result <= 840
  end

  t = tz.trim
  low = t.ascii_lowercase
  return 0 if low.empty? or low == "utc" or low == "etc/utc" or low == "gmt"
  if low == "america/los_angeles" or low == "us/pacific"
    return if us_dst_active?(utc_date): -420 else: -480
  end
  if low == "america/denver" or low == "us/mountain"
    return if us_dst_active?(utc_date): -360 else: -420
  end
  if low == "america/phoenix"
    return -420
  end
  if low == "america/chicago" or low == "us/central"
    return if us_dst_active?(utc_date): -300 else: -360
  end
  if low == "america/new_york" or low == "us/eastern"
    return if us_dst_active?(utc_date): -240 else: -300
  end
  if low == "europe/london"
    return if eu_dst_active?(utc_date): 60 else: 0
  end
  if low == "europe/berlin" or low == "europe/paris" or low == "europe/amsterdam"
    return if eu_dst_active?(utc_date): 120 else: 60
  end
  if low == "asia/tokyo"
    return 540
  end
  if low == "australia/sydney"
    return 600
  end
  # Explicit UTC+H or UTC-H fallback
  case low.drop_prefix("utc")
    Some(rest):
      r = rest.trim
      if r.starts_with?("+")
        hrs = (r.drop_prefix("+") or "0").to_int or 0
        if hrs >= 0 and hrs <= 14
          return hrs * 60
        end
      else if r.starts_with?("-")
        hrs = (r.drop_prefix("-") or "0").to_int or 0
        if hrs >= 0 and hrs <= 12
          return 0 - (hrs * 60)
        end
      end
    None: Unit
  end
  0
end

fn parse_utc_hm(ts_text: Text) : (Int, Int)
  # ISO-8601 UTC timestamp: YYYY-MM-DDTHH:MM:SSZ
  parts = ts_text.split("T")
  time_part = parts.get(1) or "00:00:00"
  hms = time_part.split(":")
  h = (hms.first or "0").to_int or 0
  m = (hms.get(1) or "0").to_int or 0
  (h, m)
end

## Converts a UTC `Time` into local date, hour, minute, and weekday in `tz`.
fn to_local_clock(now: Time, tz: Text) : LocalClock
  utc_date = Date.from_time_utc(now)
  off_mins = utc_offset_minutes(tz, utc_date)
  (uh, um) = parse_utc_hm(now.to_text)
  total_mins = (uh * 60) + um + off_mins
  if total_mins < 0
    adj = total_mins + 1440
    prev_d = utc_date.add_days(-1) or utc_date
    LocalClock(
      date: prev_d,
      hour: adj / 60,
      minute: adj % 60,
      weekday_code: weekday_to_code(prev_d.weekday),
      offset_minutes: off_mins
    )
  else if total_mins >= 1440
    adj = total_mins - 1440
    next_d = utc_date.add_days(1) or utc_date
    LocalClock(
      date: next_d,
      hour: adj / 60,
      minute: adj % 60,
      weekday_code: weekday_to_code(next_d.weekday),
      offset_minutes: off_mins
    )
  else
    LocalClock(
      date: utc_date,
      hour: total_mins / 60,
      minute: total_mins % 60,
      weekday_code: weekday_to_code(utc_date.weekday),
      offset_minutes: off_mins
    )
  end
end

## Parses `"HH:MM"` into `(hour, minute)` if valid (0..23, 0..59).
fn parse_hhmm(raw: Text) : Option((Int, Int))
  parts = raw.trim.split(":")
  return None if parts.size != 2
  h = case (parts.first or "").to_int
    Some(v) if v >= 0 and v <= 23: v
    Some(_) | None: return None
  end
  m = case (parts.get(1) or "").to_int
    Some(v) if v >= 0 and v <= 59: v
    Some(_) | None: return None
  end
  Some((h, m))
end

## Returns true when local wall-clock time falls inside `[start_hhmm, end_hhmm)` (supports overnight wrap like 22:00..07:00).
fn in_quiet_hours?(now: Time, tz: Text, start_hhmm: Text, end_hhmm: Text) : Bool
  (sh, sm) = case parse_hhmm(start_hhmm)
    Some(p): p
    None: return false
  end
  (eh, em) = case parse_hhmm(end_hhmm)
    Some(p): p
    None: return false
  end
  loc = to_local_clock(now, tz)
  cur = (loc.hour * 60) + loc.minute
  start_m = (sh * 60) + sm
  end_m = (eh * 60) + em
  return false if start_m == end_m
  if start_m < end_m
    cur >= start_m and cur < end_m
  else
    # Overnight window (e.g. 22:00 to 07:00)
    cur >= start_m or cur < end_m
  end
end

fn pad2(n: Int) : Text
  if n < 10: "0#{n}" else: "#{n}"
end

## Evaluates whether a wall-clock routine is due right now and returns its unique
## at-most-once occurrence slot key (e.g. `"2026-11-25@07:30"`).
## Supported `schedule_kind`:
## - `"daily"` (`schedule_expr = "07:30"`)
## - `"weekdays"` (`schedule_expr = "07:30"`)
## - `"weekends"` (`schedule_expr = "08:30"`)
## - `"weekly"` (`schedule_expr = "sun@19:00"`)
## - `"interval"` (returns `Some("interval:<YYYY-MM-DDTHH:MM>")` when `next_due_at <= now`)
fn evaluate_wall_clock_slot(
  now: Time,
  schedule_kind: Text,
  schedule_expr: Text,
  timezone: Text,
  next_due_at: Text
) : Option(Text)
  kind = schedule_kind.trim.ascii_lowercase
  if kind.empty? or kind == "interval"
    if next_due_at.trim.empty? or next_due_at <= now.to_text
      return Some("interval:#{Text.from_chars(now.to_text.chars.take(16))}")
    else
      return None
    end
  end

  loc = to_local_clock(now, timezone)
  now_mins = (loc.hour * 60) + loc.minute

  if kind == "weekly"
    parts = schedule_expr.trim.ascii_lowercase.split("@")
    day_code = (parts.first or "sun").trim
    hhmm_str = (parts.get(1) or "19:00").trim
    return None if loc.weekday_code != day_code
    (th, tm) = case parse_hhmm(hhmm_str)
      Some(p): p
      None: return None
    end
    target_mins = (th * 60) + tm
    # Fire once within the target day once local wall clock reaches HH:MM
    if now_mins >= target_mins
      return Some("#{loc.date.to_iso}@#{day_code}@#{pad2(th)}:#{pad2(tm)}")
    else
      return None
    end
  end

  if kind == "weekdays" and not is_weekday?(loc.weekday_code)
    return None
  end
  if kind == "weekends" and not is_weekend?(loc.weekday_code)
    return None
  end

  (th, tm) = case parse_hhmm(schedule_expr)
    Some(p): p
    None: return None
  end
  target_mins = (th * 60) + tm
  if now_mins >= target_mins
    Some("#{loc.date.to_iso}@#{pad2(th)}:#{pad2(tm)}")
  else
    None
  end
end

## Computes the next informational `next_due_at` timestamp string after a routine runs.
fn compute_next_due_text(now: Time, schedule_kind: Text, interval_seconds: Int) : Text
  kind = schedule_kind.trim.ascii_lowercase
  if kind.empty? or kind == "interval"
    secs = if interval_seconds >= 60: interval_seconds else: 60
    (now + secs.seconds).to_text
  else
    # Wall-clock routines are re-checked each minute and gated by their unique occurrence slot!
    (now + 60.seconds).to_text
  end
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

test "SchedulerActor and wall-clock IANA timezone, DST, quiet hours, and slot keys work accurately"
  sched = Actor.start(SchedulerActor)
  r0 = sched.register_routine("chief", "morning-brief")
  assert r0.due?
  r1 = sched.mark_ran("chief", "morning-brief")
  assert not r1.due? and r1.runs == 1
  Actor.advance(sched, 1.minute)
  ov = sched.overview
  assert ov.ticks >= 1 and ov.total_runs == 1

  # 2026-11-25 is Wednesday in Standard Time (America/Los_Angeles = UTC-8)
  # 15:30 UTC == 07:30 PST!
  t_pst = Time.parse("2026-11-25T15:30:00Z") or stop "time"
  loc = to_local_clock(t_pst, "America/Los_Angeles")
  assert loc.hour == 7 and loc.minute == 30 and loc.weekday_code == "wed"
  assert evaluate_wall_clock_slot(t_pst, "weekdays", "07:30", "America/Los_Angeles", "") ==
    Some("2026-11-25@07:30")
  assert evaluate_wall_clock_slot(t_pst, "weekends", "07:30", "America/Los_Angeles", "") == None

  # Overnight quiet hours: 22:00 to 07:00 PST
  t_late = Time.parse("2026-11-26T06:30:00Z") or stop "time"  # 22:30 PST
  assert in_quiet_hours?(t_late, "America/Los_Angeles", "22:00", "07:00")
  assert not in_quiet_hours?(t_pst, "America/Los_Angeles", "22:00", "07:00")

  # US Summer DST check: 2026-07-15 is PDT (UTC-7)
  t_pdt = Time.parse("2026-07-15T14:30:00Z") or stop "time"
  loc_summer = to_local_clock(t_pdt, "America/Los_Angeles")
  assert loc_summer.hour == 7 and loc_summer.minute == 30 and loc_summer.offset_minutes == -420
end
