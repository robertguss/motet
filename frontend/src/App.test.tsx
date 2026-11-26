import { describe, expect, it, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import App from './App';

function mockFetch() {
  let simRun = false;
  let acceptedRun = false;
  let grantRevoked = false;
  let worldLanded = false;
  let dreamLanded = false;

  return vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
    const url = String(input);
    const json = (data: unknown) =>
      new Response(JSON.stringify(data), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });

    if (url.includes('/v1/health')) {
      return json({
        status: 'ok',
        version: '0.2.0',
        bots: 5,
        pending_approvals: 1,
        connectors: 1,
        routines: 1,
        queued_runs: 0,
        vault_secrets: 2,
        'master_key_set?': true,
        'telegram_enabled?': false,
        push_subscriptions: 0,
      });
    }
    if (url.includes('/v1/bots/chief/canonical')) {
      return json({
        id: 'chief-main',
        bot_name: 'chief',
        title: 'chief · Main Chat',
        trust: 'owner',
        'canonical?': true,
        compaction_seq: 0,
        created_at: '2026-11-25T00:00:00Z',
        updated_at: '2026-11-25T00:00:00Z',
        event_count: 0,
      });
    }
    if (url.includes('/v1/bots')) {
      return json([
        {
          name: 'chief',
          role: 'Chief of Staff',
          persona: 'Coordinates specialists.',
          'is_primary?': true,
          model_tier: 'smart',
          provider: 'anthropic',
          endpoint: 'https://api.anthropic.com/v1/messages',
          api_key_env: 'ANTHROPIC_API_KEY',
          model: 'claude-sonnet-5-5',
          workspace: '.',
          allowed_programs: [],
          allowed_hosts: ['api.anthropic.com:443'],
          connectors: ['qmd'],
          read_only_connectors: ['qmd'],
          daily_budget_usd: '5.00',
          max_steps: 10,
          'active?': true,
        },
        {
          name: 'finance',
          role: 'Household Finance',
          persona: 'Manages Hearth Arvo.',
          'is_primary?': false,
          model_tier: 'gemini_flash',
          provider: 'gemini',
          endpoint: 'https://generativelanguage.googleapis.com/v1beta/models',
          api_key_env: 'GEMINI_API_KEY',
          model: 'gemini-2.5-flash',
          workspace: '.',
          allowed_programs: [],
          allowed_hosts: ['generativelanguage.googleapis.com:443'],
          connectors: ['hearth-arvo', 'gmail-personal'],
          read_only_connectors: ['gmail-personal'],
          daily_budget_usd: '3.00',
          max_steps: 10,
          'active?': true,
        },
      ]);
    }
    if (url.includes('/v1/inbox')) {
      return json([
        {
          id: 1,
          bot_name: 'finance',
          session_id: 'finance-main',
          tool_name: 'connector_call',
          arguments_json: '{"connector":"hearth-arvo","tool":"move_money","amount":50}',
          effect_class: 'write_external',
          reason: 'external action paused for Needs You approval',
          status: 'pending',
          result_text: null,
          created_at: '2026-11-25T08:00:00Z',
        },
      ]);
    }
    if (url.includes('/v1/vault/secrets')) {
      return json([
        { name: 'ANTHROPIC_API_KEY', scope: 'llm', updated_at: '2026-11-25', source: 'vault' },
      ]);
    }
    if (url.includes('/v1/analytics/audit')) {
      return json({
        generated_at: '2026-11-25T19:00:00Z',
        total_routines: 4,
        zero_value_routines: [],
        unused_bot_skills: ['stale-bot-skill (bot_proposed:chief)'],
        repeated_approval_tools: [],
        summary_markdown: '# Motet Weekly Self-Audit\n\n- **Total routines:** 4',
      });
    }
    if (url.includes('/v1/modb/verify/checkpoint')) {
      return json({
        'ok?': true,
        txid: 43,
        page_count: 19,
        bucket_count: 20,
        schema_version: 1,
        audit_entries: 41,
        last_audit_hash: 'abcdef1234567890',
        invariants_checked: 4,
        call_count: 30,
        'secrets_ok?': true,
      });
    }
    if (url.includes('/v1/modb/verify')) {
      return json({
        'ok?': true,
        txid: 42,
        page_count: 18,
        bucket_count: 20,
        schema_version: 1,
        audit_entries: 41,
        last_audit_hash: 'abcdef1234567890',
        invariants_checked: 4,
        call_count: 30,
        'secrets_ok?': true,
      });
    }
    if (url.includes('/v1/modb/audit')) {
      return json([
        {
          seq: 41,
          txid: 42,
          schema_version: 1,
          principal: 'bot:researcher',
          action: 'save_memory',
          reason: 'save noisy work log',
          at: '2026-11-25T19:00:00Z',
          summary: "execute 'save_memory' (v1)",
          payload: { scope: 'researcher', kind: 'work_log', content: 'Bad log' },
          prev_hash: '0000000000000000',
          entry_hash: 'abcdef1234567890fedcba',
        },
      ]);
    }
    if (url.includes('/v1/modb/calls')) {
      return json([
        {
          seq: 30,
          audit_seq: 41,
          schema_version: 1,
          principal: 'bot:researcher',
          grant_id: 'bot:researcher',
          grant_chain: ['system:motet', 'bot:researcher'],
          world_id: null,
          action: 'save_memory',
          args: { scope: 'researcher', content: 'Bad log' },
          reason: 'save noisy work log',
          at: '2026-11-25T19:00:00Z',
          outcome: { orig_ok: { reply: { id: 9 } } },
        },
      ]);
    }
    if (url.includes('/v1/modb/replay/baseline')) {
      return json({
        'pinned?': true,
        pin_id: '_modb_replay_baseline',
        schema_version: 1,
        txid: 10,
        pinned_at: '2026-11-25T10:00:00Z',
        call_count: 30,
        'can_pin?': false,
      });
    }
    if (url.includes('/v1/modb/replay/simulate')) {
      simRun = true;
      return json({
        id: 'replay-1',
        description: 'Selective undo simulation',
        filter: { exclude_principal: { principal: 'bot:researcher' } },
        base_live_txid: 42,
        base_audit_seq: 41,
        base_call_seq: 30,
        target_schema_version: 1,
        created_by: 'local',
        created_at: '2026-11-25T19:05:00Z',
        status: 'pending',
        summary: {
          total_calls: 1,
          excluded: 1,
          unchanged: 0,
          reply_changed: 0,
          now_refused: 0,
          now_invariant_blocked: 0,
          still_refused: 0,
          now_accepted: 0,
          migrations_run: [],
        },
        outcomes: [{ excluded: { seq: 30, action: 'save_memory', principal: 'bot:researcher' } }],
        bucket_diffs: [{ bucket: 'memories', added: 0, removed: 1, modified: 0 }],
        'stale?': false,
        'uses_delta?': true,
      });
    }
    if (url.includes('/v1/modb/replay/proposals/replay-1/accept')) {
      acceptedRun = true;
      return json({
        id: 'replay-1',
        description: 'Selective undo simulation',
        filter: { exclude_principal: { principal: 'bot:researcher' } },
        base_live_txid: 42,
        base_audit_seq: 41,
        base_call_seq: 30,
        target_schema_version: 1,
        created_by: 'local',
        created_at: '2026-11-25T19:05:00Z',
        status: { accepted: { commit_txid: 44, accepted_by: 'local', accepted_at: '2026-11-25T19:06:00Z' } },
        summary: {
          total_calls: 1,
          excluded: 1,
          unchanged: 0,
          reply_changed: 0,
          now_refused: 0,
          now_invariant_blocked: 0,
          still_refused: 0,
          now_accepted: 0,
          migrations_run: [],
        },
        outcomes: [{ excluded: { seq: 30, action: 'save_memory', principal: 'bot:researcher' } }],
        bucket_diffs: [{ bucket: 'memories', added: 0, removed: 1, modified: 0 }],
        'stale?': false,
        'uses_delta?': true,
      });
    }
    if (url.includes('/v1/modb/replay/proposals')) {
      if (!simRun) return json([]);
      return json([
        {
          id: 'replay-1',
          description: 'Selective undo simulation',
          filter: { exclude_principal: { principal: 'bot:researcher' } },
          base_live_txid: 42,
          base_audit_seq: 41,
          base_call_seq: 30,
          target_schema_version: 1,
          created_by: 'local',
          created_at: '2026-11-25T19:05:00Z',
          status: acceptedRun
            ? { accepted: { commit_txid: 44, accepted_by: 'local', accepted_at: '2026-11-25T19:06:00Z' } }
            : 'pending',
          summary: {
            total_calls: 1,
            excluded: 1,
            unchanged: 0,
            reply_changed: 0,
            now_refused: 0,
            now_invariant_blocked: 0,
            still_refused: 0,
            now_accepted: 0,
            migrations_run: [],
          },
          outcomes: [{ excluded: { seq: 30, action: 'save_memory', principal: 'bot:researcher' } }],
          bucket_diffs: [{ bucket: 'memories', added: 0, removed: 1, modified: 0 }],
          'stale?': false,
          'uses_delta?': true,
        },
      ]);
    }
    if (url.includes('/v1/modb/grants/bot%3Aresearcher/revoke')) {
      grantRevoked = true;
      return json({
        id: 'bot:researcher',
        parent_id: null,
        principal: 'bot:researcher',
        allowed_actions: ['read', 'write_local'],
        allowed_views: ['bots', 'memories'],
        allowed_releases: ['bot_activity_summary'],
        max_calls: 10000,
        used_calls: 1,
        expires_at: '2027-11-25T00:00:00Z',
        revoked: true,
        chain: ['system:motet', 'bot:researcher'],
      });
    }
    if (url.includes('/v1/modb/grants')) {
      return json([
        {
          id: 'bot:researcher',
          parent_id: null,
          principal: 'bot:researcher',
          allowed_actions: ['read', 'write_local'],
          allowed_views: ['bots', 'memories'],
          allowed_releases: ['bot_activity_summary'],
          max_calls: 10000,
          used_calls: 1,
          expires_at: '2027-11-25T00:00:00Z',
          revoked: grantRevoked,
          chain: ['system:motet', 'bot:researcher'],
        },
      ]);
    }
    if (url.includes('/v1/modb/claims')) {
      return json([]);
    }
    if (url.includes('/v1/modb/describe')) {
      return json({
        txid: 42,
        schema_version: 1,
        audit_count: 41,
        require_reason: true,
        principal: 'local',
        role: 'operator',
        allowed_views: [
          {
            name: 'bots',
            description: 'Active and paused bot configurations',
            narrows: null,
            fields: [
              { name: 'name', field_type: 'text', description: 'Unique bot slug' },
              { name: 'role', field_type: 'text', description: 'Role title' },
            ],
          },
        ],
        allowed_releases: [
          {
            name: 'memory_scope_summary',
            description: 'k-anonymous counts per memory scope',
            min_group_size: 2,
            args_description: 'none',
          },
        ],
        allowed_actions: [],
        invariants: [{ name: 'bots_valid', description: 'Valid bots' }],
        read_limits: { max_rows_scanned: 10000, max_ops: 100000, max_result_rows: 500 },
      });
    }
    if (url.includes('/v1/modb/releases/memory_scope_summary')) {
      return json({
        release: 'memory_scope_summary',
        txid: 43,
        cohort_size: 3,
        min_group_size: 2,
        answer_hash: 'aa11bb22cc33dd44',
        data: { shared: 2, finance: 1 },
      });
    }
    if (url.includes('/v1/modb/reads')) {
      return json([
        {
          seq: 1,
          txid: 42,
          principal: 'local',
          grant_id: null,
          kind: 'ad_hoc_program',
          target: 'bots',
          request_json: {},
          rows_scanned: 2,
          result_count: 2,
          answer_hash: '1122334455667788',
          at: '2026-11-25T19:00:00Z',
        },
      ]);
    }
    if (url.includes('/v1/modb/worlds/dream-preview-1/land')) {
      dreamLanded = true;
      worldLanded = true;
      return json({
        world_id: 'dream-preview-1',
        commit_txid: 45,
        calls_replayed: 1,
        reads_verified: 0,
        reads_skipped: 2,
        replies: [{}],
        grant_chain: ['system:motet', 'system:dreaming'],
      });
    }
    if (url.includes('/v1/modb/worlds/dream-preview-1/diff')) {
      return json([{ bucket: 'memories', added: 1, removed: 1, modified: 0 }]);
    }
    if (url.includes('/v1/modb/worlds')) {
      return json({
        metrics: {
          total_landed: worldLanded ? 2 : 1,
          stale_read_rejections: 0,
          invariant_rejections: 0,
          action_rejections: 0,
          grant_rejections: 0,
          needless_send_backs: 0,
          total_reads_verified: 0,
          total_reads_skipped: worldLanded ? 4 : 2,
        },
        worlds: [
          {
            id: 'dream-landed-0',
            grant_id: 'system:dreaming',
            principal: 'system:dreaming',
            base_txid: 40,
            base_pin_id: 'world:dream-landed-0',
            steps: [{ read_step: { query: 'list_active_memories' } }, { call_step: { action: 'dream_consolidate' } }],
            status: { landed: { commit_txid: 41 } },
            created_at: '2026-11-25T18:00:00Z',
            expires_at: '2026-11-25T19:00:00Z',
          },
          ...(dreamLanded
            ? [
                {
                  id: 'dream-preview-1',
                  grant_id: 'system:dreaming',
                  principal: 'system:dreaming',
                  base_txid: 42,
                  base_pin_id: 'world:dream-preview-1',
                  steps: [{ read_step: { query: 'list_active_memories' } }],
                  status: { landed: { commit_txid: 45 } },
                  created_at: '2026-11-25T19:10:00Z',
                  expires_at: '2026-11-25T20:10:00Z',
                },
              ]
            : []),
        ],
      });
    }
    if (url.includes('/v1/memory/dream/preview')) {
      return json({
        world_id: 'dream-preview-1',
        base_txid: 42,
        pruned_ids: [9],
        promoted_contents: ['Always confirm wire transfers'],
        summary: 'Preview staged 1 promotion and 1 duplicate prune',
        bucket_diffs: [{ bucket: 'memories', added: 1, removed: 1, modified: 0 }],
      });
    }
    if (url.includes('/v1/modb/query')) {
      return json({
        view: 'bots',
        txid: 42,
        rows_scanned: 2,
        ops_used: 3,
        result_count: 2,
        answer_hash: '1122334455667788',
        rows: [{ name: 'chief', role: 'Chief of Staff' }],
      });
    }
    if (url.includes('/v1/analytics')) {
      return json({
        day: '2026-11-25',
        total_spent_usd: '0.12',
        total_input_tokens: 10000,
        total_output_tokens: 1000,
        total_cached_tokens: 8200,
        cache_hit_pct: 82,
        routines_total_runs: 3,
        routines_total_skips: 14,
        pending_approvals: 1,
        active_bots: 5,
        by_bot: [],
      });
    }
    if (url.includes('/v1/vault/files')) {
      return json([{ path: 'notes/trip.md', folder: 'notes', size_bytes: 42 }]);
    }
    if (url.includes('/v1/vault/git/status')) {
      return json({
        'initialized?': true,
        branch: 'main',
        dirty_count: 0,
        last_commit: 'abc123 Add trip note',
        remote: 'origin',
      });
    }
    if (url.includes('/v1/intents')) {
      return json([
        {
          id: 1,
          bot_name: 'personal',
          name: 'watch-permit',
          watch_terms: 'permit contractor',
          instruction: 'Alert immediately',
          cooldown_seconds: 3600,
          max_fires: 5,
          fire_count: 1,
          expires_at: '2026-12-09T00:00:00Z',
          'active?': true,
          last_fired_at: null,
        },
      ]);
    }
    if (url.includes('/v1/memory/dream/history')) {
      return json([
        {
          id: 1,
          run_at: '2026-11-25T03:00:00Z',
          summary: 'Light pass pruned 1 duplicate; REM pass promoted 1 owner preference.',
          promoted_count: 1,
          pruned_count: 1,
          'rolled_back?': false,
        },
      ]);
    }
    return json([]);
  });
}

describe('Motet Control Plane Dashboard', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    mockFetch();
  });

  it('renders specialist roster, navigates to Bot Builder, Write-Only Vault, and Needs You Inbox', async () => {
    render(<App />);

    await waitFor(() => {
      expect(screen.getByText('5 bots · 1 inbox')).toBeInTheDocument();
    });

    // Switch to Bots & Builder and open Create Bot wizard
    fireEvent.click(screen.getByText('Bots & Builder'));
    await waitFor(() => {
      expect(screen.getByText('Household Finance')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByText('Create Bot'));
    expect(screen.getByText('Create Dedicated Bot')).toBeInTheDocument();
    fireEvent.click(screen.getByText('Cancel'));

    // Switch to Vault & Secrets
    fireEvent.click(screen.getByText('Vault & Secrets'));
    await waitFor(() => {
      expect(screen.getByText('Write-Only AES-256-GCM Vault')).toBeInTheDocument();
    });

    // Switch to Needs You Inbox and verify editable approval card renders
    fireEvent.click(screen.getByText('Needs You'));
    await waitFor(() => {
      expect(screen.getByText('Needs You Inbox')).toBeInTheDocument();
      expect(screen.getByText('Approve & Run')).toBeInTheDocument();
    });

    // Switch to Analytics & System and verify cache hit rate, weekly audit scorecard, and MoDB Integrity render
    fireEvent.click(screen.getByText('Analytics & System'));
    await waitFor(() => {
      expect(screen.getByText('82%')).toBeInTheDocument();
      expect(screen.getByText('Weekly Self-Audit Anti-Job Scorecard')).toBeInTheDocument();
      expect(screen.getByText('MoDB Storage Engine & Integrity')).toBeInTheDocument();
      expect(screen.getByText('Verified')).toBeInTheDocument();
    });

    // Switch to Personal Vault & Pages and verify Git+qmd vault renders
    fireEvent.click(screen.getByText('Vault & Pages'));
    await waitFor(() => {
      expect(screen.getByText('notes/trip.md')).toBeInTheDocument();
      expect(screen.getByText('main · 0 pending')).toBeInTheDocument();
    });

    // Switch to Routines & Intents and verify Standing Intent renders
    fireEvent.click(screen.getByText('Routines & Intents'));
    await waitFor(() => {
      expect(screen.getByText('Standing Intents (Zero-LLM FTS Watchdogs)')).toBeInTheDocument();
      expect(screen.getByText('personal:watch-permit')).toBeInTheDocument();
    });

    // Switch to Memory & Dreaming and verify Dreaming Rollback + Preview in World render
    fireEvent.click(screen.getByText('Memory & Dreaming'));
    await waitFor(() => {
      expect(screen.getByText('Dreaming History & Rollback')).toBeInTheDocument();
      expect(screen.getByText('Rollback')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByText('Preview in World'));
    await waitFor(() => {
      expect(screen.getByText('Speculative World Preview: dream-preview-1')).toBeInTheDocument();
      expect(screen.getByText('memories: +1 / ~0 / -1')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByText('Land Atomically'));
    await waitFor(() => {
      expect(screen.queryByText('Speculative World Preview: dream-preview-1')).not.toBeInTheDocument();
    });
  });

  it('navigates to Audit & Replay Studio, inspects audit payload, runs offline replay simulation, accepts proposal, revokes grant, and runs sandboxed read query', async () => {
    render(<App />);

    await waitFor(() => {
      expect(screen.getByText('5 bots · 1 inbox')).toBeInTheDocument();
    });

    fireEvent.click(screen.getByText('Audit & Replay'));
    await waitFor(() => {
      expect(screen.getByText('Audit Ledger & Replay Studio')).toBeInTheDocument();
      expect(screen.getByText('save_memory')).toBeInTheDocument();
    });

    // Click audit entry to inspect payload and pivot into Replay Studio
    fireEvent.click(screen.getByText('save_memory'));
    await waitFor(() => {
      expect(screen.getByText('Audit Entry #41 · save_memory')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByText(/Exclude bot:researcher in Replay Studio/));

    // Verify Replay Studio call log + run offline simulation + confirm atomic acceptance
    await waitFor(() => {
      expect(screen.getByText('Persisted Replay Calls (1)')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByText('Simulate Offline Replay'));
    await waitFor(() => {
      expect(screen.getByText('Accept Atomically')).toBeInTheDocument();
      expect(screen.getByText('O(diff) delta')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByText('Accept Atomically'));
    await waitFor(() => {
      expect(screen.getByText('Adopt Replay Proposal: replay-1')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByText('Confirm Atomic Replace'));
    await waitFor(() => {
      expect(screen.getByText('accepted @tx#44')).toBeInTheDocument();
    });

    // Grants & Claims tab
    fireEvent.click(screen.getByRole('button', { name: 'Grants & Claims' }));
    await waitFor(() => {
      expect(screen.getByText('Attenuated Bot Grants (1)')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByText('Revoke'));
    await waitFor(() => {
      expect(screen.getByText('Confirm Revoke (Cascading)')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByText('Confirm Revoke (Cascading)'));
    await waitFor(() => {
      expect(screen.getByText('revoked')).toBeInTheDocument();
    });

    // Views & Read Explorer tab + k-anonymous Release + Read Provenance Log
    fireEvent.click(screen.getByText('Views & Read Explorer'));
    await waitFor(() => {
      expect(screen.getByText('Zero-Approval Sandboxed ReadProgram Explorer')).toBeInTheDocument();
      expect(screen.getByText(/Read Provenance Log/)).toBeInTheDocument();
      expect(screen.getByText('#1')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByText('Run Query'));
    await waitFor(() => {
      expect(screen.getByText('2 rows returned')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByText('Run Release'));
    await waitFor(() => {
      expect(screen.getByText('cohort=3 (min k=2)')).toBeInTheDocument();
    });

    // Speculative Worlds tab + Exclude World in Replay Studio
    fireEvent.click(screen.getByText('Speculative Worlds'));
    await waitFor(() => {
      expect(screen.getByText('O(1) CoW Reads Skipped')).toBeInTheDocument();
      expect(screen.getByText('dream-landed-0')).toBeInTheDocument();
    });
    fireEvent.click(screen.getAllByText('Exclude World in Replay →')[0]);
    await waitFor(() => {
      expect(screen.getByText('Exclude World ID')).toBeInTheDocument();
    });
  });
});
