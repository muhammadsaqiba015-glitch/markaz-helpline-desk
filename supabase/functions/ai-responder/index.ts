import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function slugify(name: string): string {
  return (name || '')
    .toLowerCase()
    .replace(/[^a-z0-9_.-]+/g, '_')
    .replace(/^[^a-z0-9]+/, '')
    .replace(/_+/g, '_')
    .replace(/^_|_$/g, '')
    .slice(0, 64) || 'tool';
}

function fillTemplate(template: string, params: Record<string, any>): string {
  return template.replace(/\{\{(\w+)\}\}/g, (_, key) =>
    params[key] !== undefined ? String(params[key]) : ''
  );
}

async function executeProtocol(protocol: any, collectedParams: Record<string, any>): Promise<string> {
  try {
    const url = fillTemplate(protocol.endpoint_url, collectedParams);
    const method = (protocol.method || 'POST').toUpperCase();
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      ...(protocol.headers || {}),
    };
    let body: string | undefined;
    if (method !== 'GET') {
      const filled = fillTemplate(protocol.body_template || '{}', collectedParams);
      try { JSON.parse(filled); body = filled; }
      catch { body = JSON.stringify({ params: collectedParams }); }
    }
    const res = await fetch(url, { method, headers, body: method !== 'GET' ? body : undefined });
    const text = await res.text();
    try { return JSON.stringify(JSON.parse(text)); } catch { return text; }
  } catch (err: any) {
    return `Error: ${err.message}`;
  }
}

const ESCALATION_PHRASES = [
  // English
  'handing over', 'hand over', 'handover', 'escalating', 'human agent',
  'live agent', 'agent will', 'team will assist', 'support team will',
  'transferring to agent', 'transfer to agent', 'transferring you to',
  'connecting you to', 'routing to an agent', 'passing to an agent',
  'forwarding to', 'transfer this ticket',
  // Urdu / Roman Urdu
  'agent se baat', 'agent ko forward', 'insani agent', 'hamara agent',
  'agent ko transfer', 'transfer kar raha', 'agent tak',
  'forward kar raha', 'escalate kar', 'agent ke paas',
  'agent par transfer', 'agent bhejna', 'agent ko bhej',
  'agent se rabta', 'agent sambhale', 'agent handle',
];

function containsEscalation(text: string): boolean {
  const lower = text.toLowerCase();
  return ESCALATION_PHRASES.some(p => lower.includes(p));
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );

    const payload = await req.json();
    const message = payload.record;

    if (message.sender_type !== 'reseller') {
      return new Response(JSON.stringify({ skipped: 'not reseller' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // ── 1. Config ─────────────────────────────────────────────────────────────
    const { data: config } = await supabase
      .from('ai_config')
      .select('claude_api_key, test_mode_only, test_mode_phone')
      .eq('id', 1)
      .single();

    if (!config?.claude_api_key) {
      return new Response(JSON.stringify({ skipped: 'no API key' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // ── 2. Ticket ─────────────────────────────────────────────────────────────
    const { data: ticket } = await supabase
      .from('tickets')
      .select('id, ticket_number, issue_type, order_id, reseller_name, reseller_phone, status, ai_escalated, assigned_agent_id, ai_handled')
      .eq('id', message.ticket_id)
      .single();

    if (!ticket) {
      return new Response(JSON.stringify({ skipped: 'no ticket' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // ── 3. Test mode ──────────────────────────────────────────────────────────
    if (config.test_mode_only) {
      const phone = ticket.reseller_phone?.replace(/\s/g, '');
      const test = config.test_mode_phone?.replace(/\s/g, '');
      if (phone !== test) {
        return new Response(JSON.stringify({ skipped: 'test mode' }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
    }

    // ── 4. AI enabled ─────────────────────────────────────────────────────────
    const { data: aiSetting } = await supabase
      .from('ai_settings')
      .select('ai_enabled, system_prompt')
      .eq('issue_type', ticket.issue_type)
      .eq('ai_enabled', true)
      .single();

    if (!aiSetting) {
      return new Response(JSON.stringify({ skipped: 'AI not enabled' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // ── 5. Already escalated ──────────────────────────────────────────────────
    if (ticket.ai_escalated) {
      return new Response(JSON.stringify({ skipped: 'AI escalated' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // ── 6. Assigned to human agent ────────────────────────────────────────────
    if (ticket.assigned_agent_id) {
      return new Response(JSON.stringify({ skipped: 'assigned to human' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // ── 7. Human agent already replied ───────────────────────────────────────
    const { data: humanMsgs } = await supabase
      .from('messages')
      .select('id')
      .eq('ticket_id', ticket.id)
      .eq('sender_type', 'agent')
      .neq('sender_name', 'Markaz AI')
      .limit(1);

    if (humanMsgs && humanMsgs.length > 0) {
      return new Response(JSON.stringify({ skipped: 'human replied' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // ── 8. Fetch full conversation ────────────────────────────────────────────
    const { data: history } = await supabase
      .from('messages')
      .select('sender_type, sender_name, message')
      .eq('ticket_id', ticket.id)
      .order('created_at', { ascending: true })
      .limit(20);

    // ── 9. Count AI replies ───────────────────────────────────────────────────
    const aiReplyCount = (history || []).filter(
      (m: any) => m.sender_type === 'agent' && m.sender_name === 'Markaz AI'
    ).length;

    // ── 10. AI reply limit reached → move to unassigned ───────────────────────
    if (aiReplyCount >= 3) {
      // Mark ai_handled false so it leaves AI tab and goes to unassigned
      await supabase
        .from('tickets')
        .update({
          ai_handled: false,
          assigned_agent_id: null,
        })
        .eq('id', ticket.id);

      return new Response(JSON.stringify({ skipped: 'AI reply limit reached — moved to unassigned' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // ── 11. Mark ticket as AI handled on first reply ──────────────────────────
    if (!ticket.ai_handled) {
      await supabase
        .from('tickets')
        .update({ ai_handled: true })
        .eq('id', ticket.id);
    }

    // ── 12. Last 10 messages for Claude ──────────────────────────────────────
    const historyForClaude = (history || []).slice(-10);

    // ── 13. Knowledge base ────────────────────────────────────────────────────
    const { data: knowledgeDocs } = await supabase
      .from('ai_knowledge_base')
      .select('title, content')
      .or(`issue_type.eq.${ticket.issue_type},issue_type.is.null`);

    const knowledgeContext = knowledgeDocs?.length
      ? knowledgeDocs.map((d: any) => `${d.title}: ${d.content}`).join('\n').slice(0, 1500)
      : '';

    // ── 14. Protocols ─────────────────────────────────────────────────────────
    const { data: protocols } = await supabase
      .from('ai_protocols')
      .select('*, ai_protocol_params(*)')
      .eq('is_active', true)
      .or(`issue_type.eq.${ticket.issue_type},issue_type.is.null`);

    // ── 15. Build tools (OpenAI-compatible format for OpenRouter) ────────────
    const aiTools = (protocols || []).map((p: any) => {
      const properties: Record<string, any> = {};
      const required: string[] = [];
      for (const param of (p.ai_protocol_params || [])) {
        const safeKey = slugify(param.param_name);
        properties[safeKey] = { type: 'string', description: param.description };
        if (param.required) required.push(safeKey);
      }
      return {
        type: 'function',
        function: {
          name: slugify(p.name),
          description: p.trigger_description,
          parameters: {
            type: 'object',
            properties: Object.keys(properties).length
              ? properties
              : { details: { type: 'string', description: 'Details' } },
            required,
          },
        },
        _protocol: p,
      };
    });

    const aiToolsForAPI = aiTools.map(({ _protocol, ...tool }) => tool);

    // ── 16. System prompt ─────────────────────────────────────────────────────
    const systemPrompt = `${aiSetting.system_prompt || 'You are a helpful Markaz support agent. Be brief and reply in the same language as the reseller.'}

TICKET: ${ticket.ticket_number} | ${ticket.issue_type} | Order: ${ticket.order_id || 'N/A'} | Reseller: ${ticket.reseller_name} | Phone: ${ticket.reseller_phone}
AI replies remaining: ${3 - aiReplyCount} of 3.
${knowledgeContext ? `\nKNOWLEDGE:\n${knowledgeContext}` : ''}

ESCALATION RULES — follow exactly, no exceptions:
1. DISPATCH DELAY: If you check order status and find the order has NOT been dispatched and it has been more than 2 days since the order was placed — do NOT mention SLA or give delivery timelines. Your response must: (a) open with a genuine, warm apology acknowledging the delay and that it is unacceptable, (b) briefly explain what action is being taken (transferring to a human agent who will handle it on priority), (c) end by confirming the transfer so the reseller feels reassured. Match the reseller's language (Urdu, Roman Urdu, or English). Keep it concise — 2-3 sentences. Always include the transfer phrase so routing works.
2. UNRESOLVED ISSUE: If you cannot resolve the issue fully, say you are transferring to agent and stop.
3. TRANSFER MUST BE EXPLICIT: When transferring, you MUST include the words "transfer kar raha hoon" or "transferring to agent" in your reply. The system uses this phrase to route the ticket — if you do not say it, the ticket will NOT be routed and the reseller will be left waiting. Never say you are transferring without including this phrase.`;

    const conversationMessages = historyForClaude.map((m: any) => ({
      role: m.sender_type === 'agent' ? 'assistant' : 'user',
      content: m.message,
    }));

    // ── 17. Agentic loop (via OpenRouter) ────────────────────────────────────
    // System prompt goes as the first message in OpenAI-compatible format
    let loopMessages: any[] = [
      { role: 'system', content: systemPrompt },
      ...conversationMessages,
    ];
    let finalReply = '';
    let toolsUsed: string[] = [];
    let totalInputTokens = 0;
    let totalOutputTokens = 0;
    const MAX_ITERATIONS = 3;

    for (let i = 0; i < MAX_ITERATIONS; i++) {
      const requestBody: any = {
        model: 'anthropic/claude-haiku-5-5',
        max_tokens: 400,
        messages: loopMessages,
      };

      if (aiToolsForAPI.length > 0) requestBody.tools = aiToolsForAPI;

      const aiRes = await fetch('https://openrouter.ai/api/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${config.claude_api_key}`,
          'HTTP-Referer': 'https://markaz-helpline-desk.vercel.app',
          'X-Title': 'Markaz Helpline AI',
        },
        body: JSON.stringify(requestBody),
      });

      const aiData = await aiRes.json();
      if (!aiRes.ok) throw new Error(`OpenRouter error: ${JSON.stringify(aiData)}`);

      totalInputTokens += aiData.usage?.prompt_tokens || 0;
      totalOutputTokens += aiData.usage?.completion_tokens || 0;

      const choice = aiData.choices?.[0];
      if (!choice) break;

      if (choice.finish_reason === 'tool_calls') {
        loopMessages.push(choice.message); // assistant message with tool_calls array

        for (const tc of (choice.message.tool_calls || [])) {
          const toolName = tc.function.name;
          const toolInput = JSON.parse(tc.function.arguments || '{}');
          const matchedTool = aiTools.find(t => t.function.name === toolName);
          let resultText = 'Tool not found';

          if (matchedTool) {
            toolsUsed.push(toolName);
            resultText = await executeProtocol(matchedTool._protocol, toolInput);

            await supabase.from('internal_notes').insert({
              ticket_id: ticket.id,
              agent_id: null,
              agent_name: 'Markaz AI',
              note_text: `🤖 ${toolName}\nParams: ${JSON.stringify(toolInput)}\nResult: ${resultText.slice(0, 200)}`,
            });
          }

          // Each tool result is a separate message in OpenAI format
          loopMessages.push({ role: 'tool', tool_call_id: tc.id, content: resultText });
        }

        continue;
      }

      finalReply = choice.message?.content || '';
      break;
    }

    if (!finalReply) {
      finalReply = 'Unable to process. A human agent will assist shortly.';
    }

    // ── 18. Post reply ────────────────────────────────────────────────────────
    const { data: newMessage, error: msgError } = await supabase
      .from('messages')
      .insert({
        ticket_id: ticket.id,
        sender_type: 'agent',
        sender_name: 'Markaz AI',
        message: finalReply,
      })
      .select('id')
      .single();

    if (msgError) throw msgError;

    // ── 19. Check escalation — move to unassigned if escalated ────────────────
    const escalated = containsEscalation(finalReply);

    // Single ticket update (avoids race condition from two concurrent updates on same row)
    const ticketUpdate: Record<string, any> = {
      latest_message: finalReply.slice(0, 200),
      latest_message_at: new Date().toISOString(),
      latest_message_sender: 'agent',
      status: ticket.status === 'Pending' ? 'In Progress' : ticket.status,
    };
    if (escalated) {
      ticketUpdate.ai_escalated = true;
      ticketUpdate.ai_handled = false;
    }

    await Promise.all([
      supabase.from('tickets').update(ticketUpdate).eq('id', ticket.id),

      supabase.from('ai_logs').insert({
        ticket_id: ticket.id,
        message_id: newMessage.id,
        issue_type: ticket.issue_type,
        action_taken: toolsUsed.length ? `tools:${toolsUsed.join(',')}` : (escalated ? 'escalated' : 'replied'),
        response_received: finalReply.slice(0, 200),
        input_tokens: totalInputTokens,
        output_tokens: totalOutputTokens,
      }),
    ]);

    return new Response(
      JSON.stringify({ success: true, tokens: { in: totalInputTokens, out: totalOutputTokens } }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('Error:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});