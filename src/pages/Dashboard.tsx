import { useMemo, useState, type ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery, type UseQueryResult } from '@tanstack/react-query';
import { ArrowLeft, CalendarIcon, Download, Loader2, Star } from 'lucide-react';
import { addDays, format, startOfDay, subDays } from 'date-fns';
import type { DateRange } from 'react-day-picker';
import {
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { supabase } from '@/lib/supabase';
import { Button } from '@/components/ui/button';
import { Calendar } from '@/components/ui/calendar';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';

// ---------------------------------------------------------------------------
// Support Analytics dashboard. All numbers come from the database functions
// dashboard_overview / dashboard_agents / dashboard_csat (totals only).
// ---------------------------------------------------------------------------

type TabKey = 'overview' | 'agents' | 'csat';
type RangeKey = 'today' | '7d' | '30d' | '90d' | 'custom';
type Cell = string | number | null | undefined;

const RANGE_OPTIONS: { value: RangeKey; label: string }[] = [
  { value: 'today', label: 'Today' },
  { value: '7d', label: 'Last 7 days' },
  { value: '30d', label: 'Last 30 days' },
  { value: '90d', label: 'Last 90 days' },
  { value: 'custom', label: 'Custom range' },
];

const TAB_LABELS: Record<TabKey, string> = { overview: 'Overview', agents: 'Agents', csat: 'CSAT' };

const COLORS = {
  aiOnly: '#2a78d6',
  aiThenAgent: '#eb6834',
  agentOnly: '#17917f',
  noReply: '#9ca3af',
  star: '#f5a623',
};

const BOTH_COUNTS_NOTE =
  'A ticket that AI started and an agent resolved counts in both Handled by AI and Assigned and Resolved by Agent.';

// --- Date range -------------------------------------------------------------

function getRange(key: RangeKey, custom?: DateRange): { from: Date; to: Date } {
  const tomorrow = startOfDay(addDays(new Date(), 1));
  switch (key) {
    case 'today':
      return { from: startOfDay(new Date()), to: tomorrow };
    case '30d':
      return { from: subDays(tomorrow, 30), to: tomorrow };
    case '90d':
      return { from: subDays(tomorrow, 90), to: tomorrow };
    case 'custom':
      if (custom?.from) {
        return { from: startOfDay(custom.from), to: startOfDay(addDays(custom.to ?? custom.from, 1)) };
      }
      return { from: subDays(tomorrow, 7), to: tomorrow };
    case '7d':
    default:
      return { from: subDays(tomorrow, 7), to: tomorrow };
  }
}

// --- Formatting -------------------------------------------------------------

const fmtInt = (n: number | null | undefined) => (n == null ? '0' : Number(n).toLocaleString());

const fmtCsat = (n: number | null | undefined) => (n == null ? '—' : Number(n).toFixed(1));

function fmtDuration(sec: number | null | undefined): string {
  if (sec == null) return '—';
  const totalMin = Math.round(Number(sec) / 60);
  if (totalMin < 60) return `${totalMin}m`;
  return `${Math.floor(totalMin / 60)}h ${totalMin % 60}m`;
}

const fmtRate = (r: number | null | undefined) => (r == null ? '—' : `${Math.round(Number(r) * 100)}%`);

function changeText(
  cur: number | null | undefined,
  prev: number | null | undefined,
  kind: 'pct' | 'abs' | 'pts' = 'pct',
): string | undefined {
  if (cur == null || prev == null) return undefined;
  const c = Number(cur);
  const p = Number(prev);
  if (kind === 'pct') {
    if (p === 0) return undefined;
    const pct = ((c - p) / p) * 100;
    return `${pct >= 0 ? '↑' : '↓'} ${Math.abs(Math.round(pct))}% vs prev`;
  }
  if (kind === 'pts') {
    const d = (c - p) * 100;
    return `${d >= 0 ? '↑' : '↓'} ${Math.abs(Math.round(d))} pts vs prev`;
  }
  const d = c - p;
  return `${d >= 0 ? '↑' : '↓'} ${Math.abs(d).toFixed(1)} vs prev`;
}

function bucketLabel(bucket: string, unit: string): string {
  const [y, m, d] = bucket.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  if (unit === 'month') return format(date, 'MMM yyyy');
  if (unit === 'week') return `Wk ${format(date, 'MMM d')}`;
  return format(date, 'MMM d');
}

// --- Data -------------------------------------------------------------------

async function callRpc(fn: string, args: Record<string, unknown> = {}) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as any;
}

// --- CSV export -------------------------------------------------------------

function downloadCsv(filename: string, rows: Cell[][]) {
  const escape = (v: Cell) => {
    const s = v == null ? '' : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const csv = rows.map((r) => r.map(escape).join(',')).join('\n');
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

function overviewCsv(d: any): Cell[][] {
  const c = d.current ?? {};
  const p = d.previous ?? {};
  return [
    ['Metric', 'This period', 'Previous period'],
    ['Total tickets', c.total, p.total],
    ['Handled by AI', c.handled_by_ai ?? '—', p.handled_by_ai ?? '—'],
    ['Assigned and Resolved by Agent', c.assigned_resolved_by_agent, p.assigned_resolved_by_agent],
    ['First reply (average)', fmtDuration(c.first_reply_median_sec), fmtDuration(p.first_reply_median_sec)],
    ['Resolution (average)', fmtDuration(c.resolution_median_sec), fmtDuration(p.resolution_median_sec)],
    ['CSAT average', fmtCsat(c.csat_avg), fmtCsat(p.csat_avg)],
    ['CSAT ratings', c.csat_count, p.csat_count],
    [],
    ['Ticket volume'],
    ['Period starting', 'AI only', 'AI then agent', 'Agent only', 'No reply yet'],
    ...(d.volume ?? []).map((v: any) => [v.bucket, v.ai_only, v.ai_then_agent, v.agent_only, v.no_reply]),
    [],
    ['Tickets by issue (resolved by agents)'],
    ['Issue', 'Tickets'],
    ...(d.by_issue ?? []).map((i: any) => [i.issue, i.count]),
  ];
}

function agentsCsv(d: any): Cell[][] {
  const c = d.current ?? {};
  const p = d.previous ?? {};
  return [
    ['Metric', 'This period', 'Previous period'],
    ['Active agents', c.active_agents, p.active_agents],
    ['Tickets assigned', c.assigned, p.assigned],
    ['Resolved tickets', c.resolved, p.resolved],
    ['Open tickets (now)', c.open_tickets, ''],
    [],
    ['Agent comparison'],
    ['Agent', 'Assigned', 'Open', 'Resolved', '1st reply (average)', 'Resolution (average)', 'CSAT', 'Ratings'],
    ...(d.rows ?? []).map((r: any) => [
      r.agent,
      r.assigned,
      r.open,
      r.resolved,
      fmtDuration(r.first_reply_median_sec),
      fmtDuration(r.resolution_median_sec),
      fmtCsat(r.csat_avg),
      r.csat_count,
    ]),
  ];
}

function csatCsv(d: any): Cell[][] {
  const c = d.current ?? {};
  const p = d.previous ?? {};
  return [
    ['Metric', 'This period', 'Previous period'],
    ['CSAT average', fmtCsat(c.csat_avg), fmtCsat(p.csat_avg)],
    ['Ratings', c.csat_count, p.csat_count],
    ['Rating rate (of resolved tickets)', fmtRate(c.rating_rate), fmtRate(p.rating_rate)],
    [],
    ['CSAT trend'],
    ['Period starting', 'CSAT average', 'Ratings'],
    ...(d.trend ?? []).map((t: any) => [t.bucket, fmtCsat(t.csat_avg), t.csat_count]),
    [],
    ['Rating distribution'],
    ['Stars', 'Ratings'],
    ...(d.distribution ?? []).map((x: any) => [x.stars, x.count]),
    [],
    ['CSAT by issue'],
    ['Issue', 'CSAT average', 'Ratings'],
    ...(d.by_issue ?? []).map((i: any) => [i.issue, fmtCsat(i.csat_avg), i.csat_count]),
  ];
}

// --- Small building blocks ----------------------------------------------------

function Tile({ label, value, sub, change }: { label: string; value: string; sub?: string; change?: string }) {
  return (
    <div className="bg-white border border-gray-200 rounded-lg p-5">
      <p className="text-sm text-muted-foreground">{label}</p>
      <p className="text-3xl font-bold text-foreground mt-1 tabular-nums">{value}</p>
      {sub && <p className="text-xs text-gray-600 mt-1">{sub}</p>}
      {change && <p className="text-xs text-muted-foreground mt-1">{change}</p>}
    </div>
  );
}

function Panel({ title, className = '', children }: { title: string; className?: string; children: ReactNode }) {
  return (
    <section className={`bg-white border border-gray-200 rounded-lg p-5 ${className}`}>
      <h2 className="text-base font-semibold text-foreground mb-4">{title}</h2>
      {children}
    </section>
  );
}

const Empty = ({ text }: { text: string }) => (
  <p className="text-sm text-muted-foreground py-10 text-center">{text}</p>
);

function QueryState({ query, children }: { query: UseQueryResult<any>; children: (data: any) => ReactNode }) {
  if (query.isPending) {
    return (
      <div className="flex justify-center py-16">
        <Loader2 className="h-6 w-6 animate-spin text-primary" />
      </div>
    );
  }
  if (query.isError) {
    const denied = String((query.error as any)?.message ?? '').includes('not_authorized');
    return (
      <div className="bg-white border border-gray-200 rounded-lg p-8 text-center space-y-3">
        <p className="text-sm text-gray-700">
          {denied
            ? 'This account does not have access to the dashboard.'
            : 'Dashboard data could not be loaded. Check your connection and try again.'}
        </p>
        {!denied && (
          <Button variant="outline" size="sm" onClick={() => query.refetch()}>
            Try again
          </Button>
        )}
      </div>
    );
  }
  return <>{children(query.data)}</>;
}

// --- Tabs -------------------------------------------------------------------------

function OverviewTab({ data }: { data: any }) {
  const c = data.current ?? {};
  const p = data.previous ?? {};
  const total = Number(c.total ?? 0);
  const share = (n: number | null | undefined) =>
    n == null || total === 0 ? undefined : `${Math.round((Number(n) / total) * 100)}% of tickets`;

  const volume = (data.volume ?? []).map((v: any) => ({ ...v, label: bucketLabel(v.bucket, data.bucket) }));
  const issues = data.by_issue ?? [];
  const issueTotal = issues.reduce((s: number, i: any) => s + Number(i.count), 0);

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 lg:grid-cols-3 xl:grid-cols-6 gap-4">
        <Tile label="Total tickets" value={fmtInt(total)} change={changeText(c.total, p.total)} />
        <Tile
          label="Handled by AI"
          value={c.handled_by_ai == null ? '—' : fmtInt(c.handled_by_ai)}
          sub={share(c.handled_by_ai)}
          change={changeText(c.handled_by_ai, p.handled_by_ai)}
        />
        <Tile
          label="Assigned and Resolved by Agent"
          value={fmtInt(c.assigned_resolved_by_agent)}
          sub={share(c.assigned_resolved_by_agent)}
          change={changeText(c.assigned_resolved_by_agent, p.assigned_resolved_by_agent)}
        />
        <Tile
          label="First reply"
          value={fmtDuration(c.first_reply_median_sec)}
          change={changeText(c.first_reply_median_sec, p.first_reply_median_sec)}
        />
        <Tile
          label="Resolution"
          value={fmtDuration(c.resolution_median_sec)}
          change={changeText(c.resolution_median_sec, p.resolution_median_sec)}
        />
        <Tile
          label="CSAT average"
          value={fmtCsat(c.csat_avg)}
          sub={c.csat_count ? `from ${fmtInt(c.csat_count)} ${Number(c.csat_count) === 1 ? 'rating' : 'ratings'}` : 'No ratings yet'}
          change={changeText(c.csat_avg, p.csat_avg, 'abs')}
        />
      </div>

      <p className="text-xs text-muted-foreground">{BOTH_COUNTS_NOTE}</p>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <Panel title="Ticket volume" className="lg:col-span-2">
          {total === 0 ? (
            <Empty text="No tickets in this period." />
          ) : (
            <div className="h-72">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={volume} margin={{ top: 8, right: 8, left: -16, bottom: 0 }}>
                  <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#e5e7eb" />
                  <XAxis dataKey="label" tick={{ fontSize: 12 }} tickLine={false} axisLine={false} />
                  <YAxis allowDecimals={false} tick={{ fontSize: 12 }} tickLine={false} axisLine={false} />
                  <Tooltip cursor={{ fill: '#f3f4f6' }} />
                  <Legend wrapperStyle={{ fontSize: 12 }} />
                  <Bar dataKey="ai_only" name="AI only" stackId="v" fill={COLORS.aiOnly} />
                  <Bar dataKey="ai_then_agent" name="AI then agent" stackId="v" fill={COLORS.aiThenAgent} />
                  <Bar dataKey="agent_only" name="Agent only" stackId="v" fill={COLORS.agentOnly} />
                  <Bar dataKey="no_reply" name="No reply yet" stackId="v" fill={COLORS.noReply} radius={[3, 3, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            </div>
          )}
        </Panel>

        <Panel title="Tickets by issue">
          {issues.length === 0 ? (
            <Empty text="No tickets resolved by agents in this period." />
          ) : (
            <ul className="space-y-3">
              {issues.map((i: any) => {
                const pct = issueTotal ? Math.round((Number(i.count) / issueTotal) * 100) : 0;
                return (
                  <li key={i.issue}>
                    <div className="flex justify-between gap-2 text-sm">
                      <span className="text-gray-900">{i.issue}</span>
                      <span className="tabular-nums text-gray-700">
                        {fmtInt(i.count)} <span className="text-muted-foreground">({pct}%)</span>
                      </span>
                    </div>
                    <div className="mt-1 h-1.5 rounded bg-gray-100">
                      <div className="h-1.5 rounded" style={{ width: `${pct}%`, backgroundColor: COLORS.agentOnly }} />
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </Panel>
      </div>
    </div>
  );
}

function AgentsTab({ data }: { data: any }) {
  const c = data.current ?? {};
  const p = data.previous ?? {};
  const rows = data.rows ?? [];

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <Tile label="Active agents" value={fmtInt(c.active_agents)} change={changeText(c.active_agents, p.active_agents)} />
        <Tile label="Tickets assigned" value={fmtInt(c.assigned)} change={changeText(c.assigned, p.assigned)} />
        <Tile label="Resolved tickets" value={fmtInt(c.resolved)} change={changeText(c.resolved, p.resolved)} />
        <Tile label="Open tickets" value={fmtInt(c.open_tickets)} sub="Right now" />
      </div>

      <Panel title="Agent comparison">
        {rows.length === 0 ? (
          <Empty text="No tickets were assigned to agents in this period." />
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b text-gray-600">
                  <th className="py-2.5 px-3 text-left font-medium">Agent</th>
                  <th className="py-2.5 px-3 text-right font-medium">Assigned</th>
                  <th className="py-2.5 px-3 text-right font-medium">Open</th>
                  <th className="py-2.5 px-3 text-right font-medium">Resolved</th>
                  <th className="py-2.5 px-3 text-right font-medium">1st reply</th>
                  <th className="py-2.5 px-3 text-right font-medium">Resolution</th>
                  <th className="py-2.5 px-3 text-right font-medium">CSAT</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r: any) => (
                  <tr key={r.agent_id} className="border-b last:border-b-0">
                    <td className="py-2.5 px-3 text-gray-900">{r.agent}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums">{fmtInt(r.assigned)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums">{fmtInt(r.open)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums">{fmtInt(r.resolved)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums">{fmtDuration(r.first_reply_median_sec)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums">{fmtDuration(r.resolution_median_sec)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums">
                      {r.csat_count ? `${fmtCsat(r.csat_avg)} (${r.csat_count})` : '—'}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Panel>
    </div>
  );
}

function CsatTab({ data }: { data: any }) {
  const c = data.current ?? {};
  const p = data.previous ?? {};
  const trend = (data.trend ?? []).map((t: any) => ({
    ...t,
    label: bucketLabel(t.bucket, data.bucket),
    csat_avg: t.csat_count ? Number(t.csat_avg) : null,
  }));
  const dist = data.distribution ?? [];
  const totalRatings = dist.reduce((s: number, x: any) => s + Number(x.count), 0);
  const byIssue = data.by_issue ?? [];

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-4 lg:max-w-xl">
        <Tile
          label="CSAT average"
          value={fmtCsat(c.csat_avg)}
          sub={c.csat_count ? `from ${fmtInt(c.csat_count)} ${Number(c.csat_count) === 1 ? 'rating' : 'ratings'}` : 'No ratings yet'}
          change={changeText(c.csat_avg, p.csat_avg, 'abs')}
        />
        <Tile
          label="Rating rate"
          value={fmtRate(c.rating_rate)}
          sub="of resolved tickets"
          change={changeText(c.rating_rate, p.rating_rate, 'pts')}
        />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <Panel title="CSAT trend" className="lg:col-span-2">
          {!c.csat_count ? (
            <Empty text="No ratings in this period." />
          ) : (
            <div className="h-64">
              <ResponsiveContainer width="100%" height="100%">
                <LineChart data={trend} margin={{ top: 8, right: 8, left: -16, bottom: 0 }}>
                  <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#e5e7eb" />
                  <XAxis dataKey="label" tick={{ fontSize: 12 }} tickLine={false} axisLine={false} />
                  <YAxis domain={[1, 5]} ticks={[1, 2, 3, 4, 5]} tick={{ fontSize: 12 }} tickLine={false} axisLine={false} />
                  <Tooltip formatter={(v: any) => [fmtCsat(v), 'CSAT']} />
                  <Line type="monotone" dataKey="csat_avg" stroke={COLORS.aiOnly} strokeWidth={2} connectNulls dot={{ r: 3 }} />
                </LineChart>
              </ResponsiveContainer>
            </div>
          )}
        </Panel>

        <Panel title="Rating distribution">
          {totalRatings === 0 ? (
            <Empty text="No ratings in this period." />
          ) : (
            <ul className="space-y-3">
              {dist.map((x: any) => {
                const pct = Math.round((Number(x.count) / totalRatings) * 100);
                return (
                  <li key={x.stars} className="flex items-center gap-3 text-sm">
                    <span className="flex items-center gap-1 w-8 tabular-nums text-gray-900">
                      {x.stars}
                      <Star className="h-3.5 w-3.5" style={{ color: COLORS.star, fill: COLORS.star }} />
                    </span>
                    <div className="flex-1 h-2 rounded bg-gray-100">
                      <div className="h-2 rounded" style={{ width: `${pct}%`, backgroundColor: COLORS.star }} />
                    </div>
                    <span className="w-20 text-right tabular-nums text-gray-700">
                      {fmtInt(x.count)} <span className="text-muted-foreground">({pct}%)</span>
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
        </Panel>
      </div>

      <Panel title="CSAT by issue">
        {byIssue.length === 0 ? (
          <Empty text="No ratings in this period." />
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b text-gray-600">
                  <th className="py-2.5 px-3 text-left font-medium">Issue</th>
                  <th className="py-2.5 px-3 text-right font-medium">CSAT</th>
                  <th className="py-2.5 px-3 text-right font-medium">Ratings</th>
                </tr>
              </thead>
              <tbody>
                {byIssue.map((i: any) => (
                  <tr key={i.issue} className="border-b last:border-b-0">
                    <td className="py-2.5 px-3 text-gray-900">{i.issue}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums">{fmtCsat(i.csat_avg)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums">{fmtInt(i.csat_count)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Panel>
    </div>
  );
}

// --- Page -------------------------------------------------------------------------

const Dashboard = () => {
  const navigate = useNavigate();
  const [tab, setTab] = useState<TabKey>('overview');
  const [rangeKey, setRangeKey] = useState<RangeKey>('7d');
  const [custom, setCustom] = useState<DateRange | undefined>();
  const [agent, setAgent] = useState('all');
  const [issue, setIssue] = useState('all');

  const range = useMemo(() => getRange(rangeKey, custom), [rangeKey, custom]);
  const p_from = range.from.toISOString();
  const p_to = range.to.toISOString();
  const p_agent = agent === 'all' ? null : agent;
  const p_issue = issue === 'all' ? null : issue;

  const options = useQuery({
    queryKey: ['dash-options'],
    queryFn: () => callRpc('dashboard_filter_options'),
    staleTime: 5 * 60_000,
  });

  const overview = useQuery({
    queryKey: ['dash-overview', p_from, p_to, p_agent, p_issue],
    queryFn: () => callRpc('dashboard_overview', { p_from, p_to, p_agent, p_issue }),
    enabled: tab === 'overview',
    staleTime: 60_000,
  });

  const agents = useQuery({
    queryKey: ['dash-agents', p_from, p_to, p_issue],
    queryFn: () => callRpc('dashboard_agents', { p_from, p_to, p_issue }),
    enabled: tab === 'agents',
    staleTime: 60_000,
  });

  const csat = useQuery({
    queryKey: ['dash-csat', p_from, p_to, p_agent, p_issue],
    queryFn: () => callRpc('dashboard_csat', { p_from, p_to, p_agent, p_issue }),
    enabled: tab === 'csat',
    staleTime: 60_000,
  });

  const agentOptions: { id: string; name: string }[] = options.data?.agents ?? [];
  const issueOptions: string[] = options.data?.issues ?? [];

  const rangeLabel =
    rangeKey === 'custom'
      ? `${format(range.from, 'MMM d, yyyy')} – ${format(subDays(range.to, 1), 'MMM d, yyyy')}`
      : RANGE_OPTIONS.find((o) => o.value === rangeKey)?.label ?? '';
  const agentLabel = agent === 'all' ? 'All agents' : agentOptions.find((a) => a.id === agent)?.name ?? 'Selected agent';
  const issueLabel = issue === 'all' ? 'All issues' : issue;

  const activeQuery = tab === 'overview' ? overview : tab === 'agents' ? agents : csat;

  const handleExport = () => {
    const data = activeQuery.data;
    if (!data) return;
    const meta: Cell[][] = [
      ['Support Analytics', TAB_LABELS[tab]],
      ['Date range', rangeLabel],
      ...(tab === 'agents' ? [] : [['Agent', agentLabel] as Cell[]]),
      ['Issue', issueLabel],
      [],
    ];
    const body = tab === 'overview' ? overviewCsv(data) : tab === 'agents' ? agentsCsv(data) : csatCsv(data);
    downloadCsv(`support-analytics-${tab}-${format(new Date(), 'yyyy-MM-dd')}.csv`, [...meta, ...body]);
  };

  return (
    <div className="flex flex-col min-h-screen bg-background">
      <div className="sticky top-0 bg-white border-b p-4 z-10">
        <div className="flex items-center gap-4">
          <Button variant="ghost" size="icon" onClick={() => navigate('/tickets')} aria-label="Back to tickets">
            <ArrowLeft className="h-5 w-5" />
          </Button>
          <div>
            <h1 className="text-2xl font-bold text-foreground">Dashboard</h1>
            <p className="text-sm text-muted-foreground">Support analytics</p>
          </div>
        </div>
      </div>

      <div className="flex-1 p-6 overflow-y-auto">
        <div className="max-w-7xl mx-auto space-y-4">
          <Tabs value={tab} onValueChange={(v) => setTab(v as TabKey)}>
            {/* Filters (kept when switching tabs) */}
            <div className="flex flex-wrap items-center gap-2 mb-4">
              <Select value={rangeKey} onValueChange={(v) => { if (v === 'custom' && !custom?.from) setCustom({ from: range.from, to: subDays(range.to, 1) }); setRangeKey(v as RangeKey); }}>
                <SelectTrigger className="w-40 h-9 bg-white">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {RANGE_OPTIONS.map((o) => (
                    <SelectItem key={o.value} value={o.value}>
                      {o.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>

              {rangeKey === 'custom' && (
                <Popover>
                  <PopoverTrigger asChild>
                    <Button variant="outline" className="h-9 gap-2 font-normal bg-white">
                      <CalendarIcon className="h-4 w-4" />
                      {custom?.from
                        ? `${format(custom.from, 'MMM d')} – ${format(custom.to ?? custom.from, 'MMM d, yyyy')}`
                        : 'Pick dates'}
                    </Button>
                  </PopoverTrigger>
                  <PopoverContent className="w-auto p-0" align="start">
                    <Calendar
                      mode="range"
                      selected={custom}
                      onSelect={setCustom}
                      numberOfMonths={2}
                      disabled={{ after: new Date() }}
                      initialFocus
                    />
                  </PopoverContent>
                </Popover>
              )}

              {tab !== 'agents' && (
                <Select value={agent} onValueChange={setAgent}>
                  <SelectTrigger className="w-44 h-9 bg-white">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="all">All agents</SelectItem>
                    {agentOptions.map((a) => (
                      <SelectItem key={a.id} value={a.id}>
                        {a.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}

              <Select value={issue} onValueChange={setIssue}>
                <SelectTrigger className="w-44 h-9 bg-white">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="all">All issues</SelectItem>
                  {issueOptions.map((i) => (
                    <SelectItem key={i} value={i}>
                      {i}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>

              <Button
                variant="outline"
                className="h-9 gap-2 bg-white ml-auto"
                onClick={handleExport}
                disabled={!activeQuery.data}
              >
                <Download className="h-4 w-4" />
                Export
              </Button>
            </div>

            <TabsList>
              <TabsTrigger value="overview">Overview</TabsTrigger>
              <TabsTrigger value="agents">Agents</TabsTrigger>
              <TabsTrigger value="csat">CSAT</TabsTrigger>
            </TabsList>

            <TabsContent value="overview" className="mt-4">
              <QueryState query={overview}>{(d) => <OverviewTab data={d} />}</QueryState>
            </TabsContent>
            <TabsContent value="agents" className="mt-4">
              <QueryState query={agents}>{(d) => <AgentsTab data={d} />}</QueryState>
            </TabsContent>
            <TabsContent value="csat" className="mt-4">
              <QueryState query={csat}>{(d) => <CsatTab data={d} />}</QueryState>
            </TabsContent>
          </Tabs>
        </div>
      </div>
    </div>
  );
};

export default Dashboard;