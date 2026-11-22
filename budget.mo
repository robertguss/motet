## Exact 128-bit Decimal USD spend and step-budget actor for Motet bots.
module Budget
expose BudgetActor, BudgetError(..), BotQuota(..), compute_cost_usd, tier_rates
use Types{BudgetSnapshot}

max_limit_usd = 100000.0
max_tokens_per_turn = 10_000_000

enum BudgetError
  InvalidLimit
  InvalidTokens
  LimitExceeded(bot_name: Text, spent_usd: Decimal, limit_usd: Decimal)
end

struct BotQuota
  bot_name: Text
  limit_usd: Decimal
  spent_usd: Decimal
  turns: Int
  input_tokens: Int
  output_tokens: Int
end

struct BudgetState
  quotas: Map(Text, BotQuota)
end

## Per-million (input, output) USD rates by named model tier.
fn tier_rates(tier: Text) : (Decimal, Decimal)
  examples
    tier_rates("fast") == (0.30, 1.50)
    tier_rates("smart") == (3.00, 15.00)
    tier_rates("local") == (0.00, 0.00)
  end

  low = tier.trim.ascii_lowercase
  if low == "local" or low == "free"
    (0.00, 0.00)
  else if low == "fast" or low == "mini" or low == "haiku"
    (0.30, 1.50)
  else if low == "frontier" or low == "opus"
    (15.00, 75.00)
  else
    (3.00, 15.00)
  end
end

## Exact sub-cent USD cost using 128-bit Decimal for bounded token counts.
fn compute_cost_usd(input_tokens: Int, output_tokens: Int, cached_input_tokens: Int, tier: Text) : Result(
  Decimal,
  BudgetError
)
  promise "token costs are nonnegative for valid bounded inputs"
    result is Ok(cost) implies cost >= 0.0
    (input_tokens < 0 or output_tokens < 0 or cached_input_tokens < 0) implies
      result == Error(InvalidTokens)
  end

  examples
    compute_cost_usd(1000, 100, 0, "smart") == Ok(0.0045)
    compute_cost_usd(1000, 100, 800, "smart") == Ok(0.00234)
    compute_cost_usd(1000, 100, 0, "local") == Ok(0.0)
  end

  if input_tokens < 0 or
    input_tokens > max_tokens_per_turn or
    output_tokens < 0 or
    output_tokens > max_tokens_per_turn or
    cached_input_tokens < 0 or
    cached_input_tokens > input_tokens
    return Error(InvalidTokens)
  end
  (in_rate, out_rate) = tier_rates(tier)
  uncached = input_tokens - cached_input_tokens
  uncached_cost = (uncached.to_decimal * in_rate) / 1000000.0
  # Prompt cache reads cost ~10% of uncached input tokens.
  cached_cost = (cached_input_tokens.to_decimal * in_rate) / 10000000.0
  out_cost = (output_tokens.to_decimal * out_rate) / 1000000.0
  Ok((uncached_cost + cached_cost + out_cost).round(6))
end

fn quotas_valid?(state: BudgetState) : Bool
  for q in state.quotas.values
    return false if q.spent_usd < 0.0 or q.spent_usd > q.limit_usd
  end
  true
end

actor BudgetActor
  state BudgetState = BudgetState(quotas: {})
  calls configure, can_spend, record_spend, snapshot, all_snapshots
  every 1.day reset_daily

  promise
    quotas_valid?(after)
  end

  promise on record_spend
    reply is Error(_) implies after == before
  end
end

fn to_snapshot(q: BotQuota) : BudgetSnapshot
  rem = if q.limit_usd > q.spent_usd: q.limit_usd - q.spent_usd else: 0.0
  BudgetSnapshot(
    bot_name: q.bot_name,
    limit_usd: q.limit_usd,
    spent_usd: q.spent_usd,
    remaining_usd: rem,
    turns: q.turns,
    input_tokens: q.input_tokens,
    output_tokens: q.output_tokens
  )
end

fn configure(state: BudgetState, _now: Time, bot_name: Text, limit_usd: Decimal) : Result(
  (BudgetState, BudgetSnapshot),
  BudgetError
)
  clean = bot_name.trim
  return Error(InvalidLimit) if clean.empty?
  return Error(InvalidLimit) if limit_usd <= 0.0 or limit_usd > max_limit_usd
  next_q = case state.quotas.get(clean)
    Some(prev):
      return Error(InvalidLimit) if limit_usd < prev.spent_usd
      BotQuota(
        bot_name: clean,
        limit_usd: limit_usd,
        spent_usd: prev.spent_usd,
        turns: prev.turns,
        input_tokens: prev.input_tokens,
        output_tokens: prev.output_tokens
      )
    None: BotQuota(
      bot_name: clean,
      limit_usd: limit_usd,
      spent_usd: 0.0,
      turns: 0,
      input_tokens: 0,
      output_tokens: 0
    )
  end
  next = BudgetState(quotas: state.quotas.set(clean, next_q))
  Ok((next, to_snapshot(next_q)))
end

fn can_spend(state: BudgetState, _now: Time, bot_name: Text, default_limit: Decimal) : Bool
  case state.quotas.get(bot_name)
    Some(q): q.spent_usd < q.limit_usd
    None: default_limit > 0.0
  end
end

fn record_spend(
  state: BudgetState,
  _now: Time,
  bot_name: Text,
  default_limit: Decimal,
  input_tokens: Int,
  output_tokens: Int,
  cached_input_tokens: Int,
  tier: Text
) : Result((BudgetState, BudgetSnapshot), BudgetError)
  clean = bot_name.trim
  return Error(InvalidLimit) if clean.empty?
  cost = try compute_cost_usd(input_tokens, output_tokens, cached_input_tokens, tier)
  base = case state.quotas.get(clean)
    Some(q): q
    None:
      lim = if default_limit > 0.0 and default_limit <= max_limit_usd: default_limit else: 5.0
      BotQuota(
        bot_name: clean,
        limit_usd: lim,
        spent_usd: 0.0,
        turns: 0,
        input_tokens: 0,
        output_tokens: 0
      )
  end
  next_spent = (base.spent_usd + cost).round(6)
  if next_spent > base.limit_usd
    return Error(LimitExceeded(bot_name: clean, spent_usd: next_spent, limit_usd: base.limit_usd))
  end
  updated = BotQuota(
    bot_name: clean,
    limit_usd: base.limit_usd,
    spent_usd: next_spent,
    turns: base.turns.saturating_add(1),
    input_tokens: base.input_tokens.saturating_add(input_tokens),
    output_tokens: base.output_tokens.saturating_add(output_tokens)
  )
  next = BudgetState(quotas: state.quotas.set(clean, updated))
  Ok((next, to_snapshot(updated)))
end

fn snapshot(state: BudgetState, _now: Time, bot_name: Text) : Option(BudgetSnapshot)
  state.quotas.get(bot_name).map(fn(q) to_snapshot(q) end)
end

fn all_snapshots(state: BudgetState, _now: Time) : List(BudgetSnapshot)
  state.quotas.values.map(fn(q) to_snapshot(q) end)
end

fn reset_daily(state: BudgetState, _now: Time) : BudgetState
  var next = {}
  for (k, q) in state.quotas.entries
    next = next.set(
      k,
      BotQuota(
        bot_name: q.bot_name,
        limit_usd: q.limit_usd,
        spent_usd: 0.0,
        turns: 0,
        input_tokens: 0,
        output_tokens: 0
      )
    )
  end
  BudgetState(quotas: next)
end

test "BudgetActor enforces exact Decimal USD caps and daily resets"
  actor_b = Actor.start(BudgetActor)
  assert actor_b.configure("watcher", 0.01) is Ok(_)
  assert actor_b.record_spend("watcher", 0.01, 1000, 100, 0, "smart") is Ok(snap1)
  assert snap1.spent_usd == 0.0045
  assert actor_b.record_spend("watcher", 0.01, 2000, 1000, 0, "smart") is
    Error(LimitExceeded(bot_name: _, spent_usd: _, limit_usd: _))
  Actor.advance(actor_b, 1.day)
  assert actor_b.record_spend("watcher", 0.01, 1000, 100, 0, "smart") is Ok(snap2)
  assert snap2.spent_usd == 0.0045
end
