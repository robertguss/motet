## Deterministic policy engine and "Needs You" approval-queue actor.
## Host-enforced rules — never trusting the working LLM to police itself.
module Policy
expose PolicyActor, PolicyOutcome(..), PolicyStats(..), matches_pattern?, evaluate_action
use Types{ApprovalDecision, EffectClass, PolicyRule, TrustLevel}

struct PolicyOutcome
  decision: ApprovalDecision
  reason: Text
end

struct PolicyStats
  allowed: Int
  asked: Int
  denied: Int
  pending_inbox: Int
  resolved_inbox: Int
end

struct PolicyState
  allowed: Int
  asked: Int
  denied: Int
  pending_inbox: Int
  resolved_inbox: Int
end

## Simple prefix/exact wildcard match (`*`, `t3.*`, or exact tool name).
fn matches_pattern?(pattern: Text, tool_name: Text) : Bool
  examples
    matches_pattern?("*", "file_write")
    matches_pattern?("t3code:*", "t3code:t3_thread_launch")
    matches_pattern?("file_write", "file_write")
    not matches_pattern?("t3code:*", "file_write")
  end

  p = pattern.trim
  return true if p == "*"
  case p.drop_suffix("*")
    Some(prefix): tool_name.starts_with?(prefix)
    None: p == tool_name
  end
end

## Evaluates deterministic host policy for one proposed tool action.
## Non-negotiable invariants:
## - External-trust triggers (webhooks/emails) NEVER auto-allow WriteExternal or Irreversible.
## - Unattended Routine triggers NEVER auto-allow Irreversible actions, and default read-only.
fn evaluate_action(
  bot_name: Text,
  trust: TrustLevel,
  effect: EffectClass,
  tool_name: Text,
  routine_read_only?: Bool,
  rules: List(PolicyRule)
) : PolicyOutcome
  promise "external triggers never auto-allow external writes or irreversible actions"
    (trust == External and (effect == WriteExternal or effect == Irreversible)) implies
      result.decision != Allow
    (trust == Routine and effect == Irreversible) implies result.decision != Allow
  end

  examples
    evaluate_action("watcher", External, WriteExternal, "t3code:t3_thread_launch", false, [])
      .decision ==
      AskFirst
    evaluate_action("watcher", Routine, Read, "t3code:t3_thread_list", true, []).decision == Allow
    evaluate_action("watcher", Routine, WriteLocal, "file_write", true, []).decision == AskFirst
    evaluate_action("watcher", Routine, Irreversible, "t3code:pull_request_merge", true, [])
      .decision ==
      AskFirst
    evaluate_action("chief", Owner, Irreversible, "t3code:pull_request_merge", false, []).decision ==
      AskFirst
  end

  # Hard ceiling 1: External untrusted content cannot trigger external writes or irreversible ops.
  if trust == External
    return case effect
      Read: PolicyOutcome(decision: Allow, reason: "read-only action allowed")
      WriteLocal: PolicyOutcome(
        decision: AskFirst,
        reason: "external trigger cannot write local files without owner approval"
      )
      WriteExternal: PolicyOutcome(
        decision: AskFirst,
        reason: "external trigger cannot perform external actions without owner approval"
      )
      Irreversible: PolicyOutcome(
        decision: Deny,
        reason: "external trigger is forbidden from irreversible actions"
      )
    end
  end

  # Hard ceiling 2: Unattended routines cannot auto-execute irreversible actions.
  if trust == Routine and effect == Irreversible
    return PolicyOutcome(
      decision: AskFirst,
      reason: "irreversible action paused for Needs You approval during unattended routine"
    )
  end

  # Check custom user rules (most specific bot match first, then "*" wildcard bot).
  matched = rules.find(fn(r)
    (r.bot_name == bot_name or r.bot_name == "*") and matches_pattern?(r.tool_pattern, tool_name)
  end)
  case matched
    Some(rule):
      if trust == Routine and routine_read_only? and effect != Read and rule.decision == Allow
        return PolicyOutcome(
          decision: AskFirst,
          reason: "routine is read-only; paused for Needs You approval"
        )
      end
      return PolicyOutcome(
        decision: rule.decision,
        reason: if rule.note.empty?: "matched policy rule #{rule.tool_pattern}" else: rule.note
      )
    None: Unit
  end

  # Default policy matrix by trust level and effect class.
  case trust
    Owner:
      case effect
        Read: PolicyOutcome(decision: Allow, reason: "read-only tool allowed")
        WriteLocal: PolicyOutcome(
          decision: Allow,
          reason: "confined workspace write allowed for owner"
        )
        WriteExternal: PolicyOutcome(
          decision: AskFirst,
          reason: "external action paused for Needs You approval (add an Allow rule to automate)"
        )
        Irreversible: PolicyOutcome(
          decision: AskFirst,
          reason: "irreversible action always requires Needs You approval"
        )
      end
    Routine:
      case effect
        Read: PolicyOutcome(decision: Allow, reason: "proactive read-only monitoring allowed")
        WriteLocal:
          if routine_read_only?
            PolicyOutcome(decision: AskFirst, reason: "read-only routine paused local write")
          else
            PolicyOutcome(decision: Allow, reason: "scoped routine local write allowed")
          end
        WriteExternal: PolicyOutcome(
          decision: AskFirst,
          reason: "unattended routine paused external action for Needs You review"
        )
        Irreversible: PolicyOutcome(
          decision: AskFirst,
          reason: "irreversible action requires Needs You review"
        )
      end
    External: PolicyOutcome(decision: AskFirst, reason: "external event requires review")
  end
end

actor PolicyActor
  state PolicyState = PolicyState(
    allowed: 0,
    asked: 0,
    denied: 0,
    pending_inbox: 0,
    resolved_inbox: 0
  )
  calls record_decision, record_resolved, stats

  promise
    after.allowed >= before.allowed
    after.asked >= before.asked
    after.denied >= before.denied
    after.pending_inbox >= 0
    after.resolved_inbox >= before.resolved_inbox
  end
end

fn to_stats(s: PolicyState) : PolicyStats
  PolicyStats(
    allowed: s.allowed,
    asked: s.asked,
    denied: s.denied,
    pending_inbox: s.pending_inbox,
    resolved_inbox: s.resolved_inbox
  )
end

fn record_decision(s: PolicyState, _now: Time, decision: ApprovalDecision) : (
  PolicyState,
  PolicyStats
)
  next = case decision
    Allow: PolicyState(
      allowed: s.allowed.saturating_add(1),
      asked: s.asked,
      denied: s.denied,
      pending_inbox: s.pending_inbox,
      resolved_inbox: s.resolved_inbox
    )
    AskFirst: PolicyState(
      allowed: s.allowed,
      asked: s.asked.saturating_add(1),
      denied: s.denied,
      pending_inbox: s.pending_inbox.saturating_add(1),
      resolved_inbox: s.resolved_inbox
    )
    Deny: PolicyState(
      allowed: s.allowed,
      asked: s.asked,
      denied: s.denied.saturating_add(1),
      pending_inbox: s.pending_inbox,
      resolved_inbox: s.resolved_inbox
    )
  end
  (next, to_stats(next))
end

fn record_resolved(s: PolicyState, _now: Time) : (PolicyState, PolicyStats)
  next_pending = if s.pending_inbox > 0: s.pending_inbox - 1 else: 0
  next = PolicyState(
    allowed: s.allowed,
    asked: s.asked,
    denied: s.denied,
    pending_inbox: next_pending,
    resolved_inbox: s.resolved_inbox.saturating_add(1)
  )
  (next, to_stats(next))
end

fn stats(s: PolicyState, _now: Time) : PolicyStats
  to_stats(s)
end

test "PolicyActor tracks decisions and inbox resolutions"
  pol = Actor.start(PolicyActor)
  s1 = pol.record_decision(AskFirst)
  assert s1.asked == 1 and s1.pending_inbox == 1
  s2 = pol.record_resolved
  assert s2.pending_inbox == 0 and s2.resolved_inbox == 1
end
