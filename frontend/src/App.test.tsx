import { describe, expect, it, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import App from './App';

function mockFetch() {
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

    // Switch to Analytics & System and verify cache hit rate renders
    fireEvent.click(screen.getByText('Analytics & System'));
    await waitFor(() => {
      expect(screen.getByText('82%')).toBeInTheDocument();
    });
  });
});
