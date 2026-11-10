import { useEffect, useRef, useState, useCallback } from 'react';
import { supabase, type ChatMessage, type Profile } from '@/lib/supabase';
import { useAuth } from '@/lib/auth';
import { useToast } from '@/lib/toast';
import { EmptyState } from '@/components/ui';
import {
  Send, MessageCircle, Search, ArrowLeft, CheckCheck, Circle, Shield, User as UserIcon,
} from 'lucide-react';

const MAX_LEN = 2000;

/**
 * Messenger-style chat.
 * - Regular users see a single conversation with admin.
 * - Admins see a conversation list (inbox) and can reply to any user.
 */
export function ChatPage() {
  const { profile, isAdmin } = useAuth();
  if (!profile) return null;
  return isAdmin ? <AdminInbox adminProfile={profile} /> : <UserChat profile={profile} />;
}

/* ───────────────────────────── User view ───────────────────────────── */

function UserChat({ profile }: { profile: Profile }) {
  const { notify } = useToast();
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [loading, setLoading] = useState(true);
  const [text, setText] = useState('');
  const [sending, setSending] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);
  const bottomRef = useRef<HTMLDivElement>(null);

  const load = useCallback(async () => {
    const { data, error } = await supabase
      .from('chat_messages')
      .select('*')
      .eq('user_id', profile.id)
      .order('created_at', { ascending: true });
    if (error) { console.error(error); return; }
    setMessages((data as ChatMessage[]) ?? []);
  }, [profile.id]);

  useEffect(() => {
    setLoading(true);
    load().finally(() => setLoading(false));
  }, [load]);

  // Realtime: new messages in this conversation
  useEffect(() => {
    const channel = supabase
      .channel(`chat-user-${profile.id}`)
      .on('postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'chat_messages', filter: `user_id=eq.${profile.id}` },
        (payload) => {
          const msg = payload.new as ChatMessage;
          setMessages((prev) => prev.some((m) => m.id === msg.id) ? prev : [...prev, msg]);
        },
      )
      .on('postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'chat_messages', filter: `user_id=eq.${profile.id}` },
        (payload) => {
          const updated = payload.new as ChatMessage;
          setMessages((prev) => prev.map((m) => (m.id === updated.id ? updated : m)));
        },
      )
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [profile.id]);

  // Polling fallback — reload every 5s in case realtime drops.
  useEffect(() => {
    const id = window.setInterval(() => { load(); }, 5000);
    return () => window.clearInterval(id);
  }, [load]);

  // Mark admin messages as read when they arrive / on open
  useEffect(() => {
    const unread = messages.filter((m) => m.sender_role === 'admin' && !m.read_at);
    if (unread.length === 0) return;
    unread.forEach((m) => {
      supabase.from('chat_messages').update({ read_at: new Date().toISOString() }).eq('id', m.id).then();
    });
  }, [messages]);

  // Auto-scroll to bottom on new messages
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  async function send() {
    const body = text.trim();
    if (!body || sending) return;
    if (body.length > MAX_LEN) { notify(`Message too long (max ${MAX_LEN} characters).`, 'error'); return; }
    setSending(true);
    const { error } = await supabase.rpc('send_chat_message', {
      p_user_id: profile.id,
      p_body: body,
    });
    setSending(false);
    if (error) {
      console.error('chat send error:', error);
      notify('Could not send your message. Please try again.', 'error');
      return;
    }
    setText('');
    await load();
  }

  const unreadCount = messages.filter((m) => m.sender_role === 'admin' && !m.read_at).length;

  return (
    <div className="p-4 sm:p-6 max-w-3xl mx-auto animate-fade-in">
      <div className="flex items-center gap-3 mb-4">
        <div className="w-11 h-11 rounded-2xl bg-gradient-to-br from-[var(--brand-500)] to-[var(--accent-500)] flex items-center justify-center shadow-lg shrink-0">
          <Shield className="w-6 h-6 text-white" />
        </div>
        <div className="min-w-0">
          <h1 className="text-lg sm:text-xl font-extrabold text-[var(--text-primary)]">Support Chat</h1>
          <p className="text-xs text-[var(--text-muted)] truncate">
            Message the admin team — questions, concerns, or requests.
          </p>
        </div>
        {unreadCount > 0 && (
          <span className="ml-auto chip bg-[var(--brand-500)] text-white animate-pop">{unreadCount} new</span>
        )}
      </div>

      <div className="card overflow-hidden flex flex-col" style={{ height: 'calc(100vh - 220px)', minHeight: '380px' }}>
        {/* Messages */}
        <div ref={scrollRef} className="flex-1 overflow-y-auto p-4 space-y-3">
          {loading ? (
            <div className="flex items-center justify-center h-full">
              <div className="w-6 h-6 border-2 border-[var(--brand-500)] border-t-transparent rounded-full animate-spin" />
            </div>
          ) : messages.length === 0 ? (
            <EmptyState
              icon={MessageCircle}
              title="No messages yet"
              hint="Send a message below to start a conversation with the admin team."
            />
          ) : (
            messages.map((m) => <Bubble key={m.id} msg={m} mine={m.sender_id === profile.id} />)
          )}
          <div ref={bottomRef} />
        </div>

        {/* Composer */}
        <div className="border-t border-[var(--border-subtle)] p-3 flex items-end gap-2 bg-[var(--bg-surface)]">
          <textarea
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } }}
            rows={1}
            placeholder="Type a message…"
            maxLength={MAX_LEN}
            className="flex-1 resize-none rounded-xl bg-[var(--bg-elevated)] border border-[var(--border-subtle)] px-3.5 py-2.5 text-sm text-[var(--text-primary)] placeholder:text-[var(--text-muted)] focus:outline-none focus:ring-2 focus:ring-[var(--brand-500)]/40 max-h-28"
          />
          <button
            onClick={send}
            disabled={sending || !text.trim()}
            className="btn-primary shrink-0 w-10 h-10 rounded-xl flex items-center justify-center p-0"
            aria-label="Send message"
          >
            <Send className="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
  );
}

/* ─────────────────────────── Admin view ──────────────────────────── */

interface ConversationSummary {
  user_id: string;
  full_name: string;
  avatar_url: string;
  last_body: string;
  last_at: string;
  unread: number;
}

function AdminInbox({ adminProfile }: { adminProfile: Profile }) {
  const { notify } = useToast();
  const [conversations, setConversations] = useState<ConversationSummary[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');

  // Load all messages, then group into conversation summaries.
  const loadSummaries = useCallback(async () => {
    const { data, error } = await supabase
      .from('chat_messages')
      .select('user_id, sender_role, body, read_at, created_at')
      .order('created_at', { ascending: true });
    if (error) { console.error(error); return; }
    const rows = (data ?? []) as Pick<ChatMessage, 'user_id' | 'sender_role' | 'body' | 'read_at' | 'created_at'>[];

    // Fetch profile names for all user_ids involved
    const userIds = [...new Set(rows.map((r) => r.user_id))];
    const { data: profs } = await supabase
      .from('profiles')
      .select('id, full_name, avatar_url')
      .in('id', userIds);
    const profMap = new Map<string, { full_name: string; avatar_url: string }>(
      ((profs ?? []) as Pick<Profile, 'id' | 'full_name' | 'avatar_url'>[])
        .map((p) => [p.id, { full_name: p.full_name, avatar_url: p.avatar_url }]),
    );

    const groups = new Map<string, ConversationSummary>();
    for (const r of rows) {
      const g = groups.get(r.user_id);
      if (!g) {
        const p = profMap.get(r.user_id);
        groups.set(r.user_id, {
          user_id: r.user_id,
          full_name: p?.full_name || 'Unknown user',
          avatar_url: p?.avatar_url || '',
          last_body: r.body,
          last_at: r.created_at,
          unread: r.sender_role === 'user' && !r.read_at ? 1 : 0,
        });
      } else {
        // keep latest message
        if (r.created_at >= g.last_at) {
          g.last_body = r.body;
          g.last_at = r.created_at;
        }
        if (r.sender_role === 'user' && !r.read_at) g.unread += 1;
      }
    }
    const list = Array.from(groups.values()).sort((a, b) => b.last_at.localeCompare(a.last_at));
    setConversations(list);
  }, []);

  useEffect(() => {
    setLoading(true);
    loadSummaries().finally(() => setLoading(false));
  }, [loadSummaries]);

  // Realtime: refresh summaries when any chat message changes
  useEffect(() => {
    const channel = supabase
      .channel('chat-admin-inbox')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'chat_messages' }, () => { loadSummaries(); })
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [loadSummaries]);

  // Polling fallback for inbox — refresh every 8s.
  useEffect(() => {
    const id = window.setInterval(() => { loadSummaries(); }, 8000);
    return () => window.clearInterval(id);
  }, [loadSummaries]);

  const filtered = conversations.filter((c) =>
    c.full_name.toLowerCase().includes(search.toLowerCase()),
  );

  if (loading) {
    return (
      <div className="p-6 flex items-center justify-center min-h-[50vh]">
        <div className="w-6 h-6 border-2 border-[var(--accent-500)] border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  // Mobile: show list OR conversation, not both.
  // Desktop: show both side by side.
  if (selectedId) {
    return (
      <AdminConversation
        adminId={adminProfile.id}
        userId={selectedId}
        onBack={() => setSelectedId(null)}
      />
    );
  }

  return (
    <div className="p-4 sm:p-6 max-w-3xl mx-auto animate-fade-in">
      <div className="flex items-center gap-3 mb-4">
        <div className="w-11 h-11 rounded-2xl bg-gradient-to-br from-[var(--accent-500)] to-[var(--brand-500)] flex items-center justify-center shadow-lg shrink-0">
          <MessageCircle className="w-6 h-6 text-white" />
        </div>
        <div className="min-w-0">
          <h1 className="text-lg sm:text-xl font-extrabold text-[var(--text-primary)]">Inbox</h1>
          <p className="text-xs text-[var(--text-muted)] truncate">
            Reply to user questions and concerns.
          </p>
        </div>
        <span className="ml-auto chip bg-[var(--bg-elevated)] text-[var(--text-muted)]">
          {conversations.length} {conversations.length === 1 ? 'chat' : 'chats'}
        </span>
      </div>

      {conversations.length === 0 ? (
        <div className="card p-6">
          <EmptyState icon={MessageCircle} title="No conversations yet" hint="When users send a message, it will appear here." />
        </div>
      ) : (
        <>
          <div className="relative mb-3">
            <Search className="absolute left-3.5 top-1/2 -translate-y-1/2 w-4 h-4 text-[var(--text-muted)]" />
            <input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Search conversations…"
              className="w-full rounded-xl bg-[var(--bg-elevated)] border border-[var(--border-subtle)] pl-10 pr-3.5 py-2.5 text-sm text-[var(--text-primary)] placeholder:text-[var(--text-muted)] focus:outline-none focus:ring-2 focus:ring-[var(--brand-500)]/40"
            />
          </div>
          <div className="card divide-y divide-[var(--border-subtle)]">
            {filtered.map((c) => (
              <button
                key={c.user_id}
                onClick={() => setSelectedId(c.user_id)}
                className="w-full flex items-center gap-3 p-3.5 text-left hover:bg-[var(--brand-500)]/5 transition-colors first:rounded-t-xl last:rounded-b-xl"
              >
                <Avatar avatarUrl={c.avatar_url} name={c.full_name} />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <p className="text-sm font-bold text-[var(--text-primary)] truncate">{c.full_name}</p>
                    <span className="ml-auto text-[10px] text-[var(--text-muted)] shrink-0">{timeAgo(c.last_at)}</span>
                  </div>
                  <p className="text-xs text-[var(--text-muted)] truncate mt-0.5">{c.last_body}</p>
                </div>
                {c.unread > 0 && (
                  <span className="chip bg-[var(--brand-500)] text-white text-[10px] animate-pop shrink-0">{c.unread}</span>
                )}
              </button>
            ))}
            {filtered.length === 0 && (
              <p className="text-center text-sm text-[var(--text-muted)] py-6">No conversations match "{search}".</p>
            )}
          </div>
        </>
      )}
    </div>
  );
}

function AdminConversation({ adminId, userId, onBack }: { adminId: string; userId: string; onBack: () => void }) {
  const { notify } = useToast();
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [loading, setLoading] = useState(true);
  const [text, setText] = useState('');
  const [sending, setSending] = useState(false);
  const bottomRef = useRef<HTMLDivElement>(null);

  const load = useCallback(async () => {
    const [msgRes, profRes] = await Promise.all([
      supabase.from('chat_messages').select('*').eq('user_id', userId).order('created_at', { ascending: true }),
      supabase.from('profiles').select('*').eq('id', userId).maybeSingle(),
    ]);
    if (msgRes.error) console.error(msgRes.error);
    if (profRes.error) console.error(profRes.error);
    setMessages((msgRes.data as ChatMessage[]) ?? []);
    setProfile(profRes.data as Profile | null);
  }, [userId]);

  useEffect(() => {
    setLoading(true);
    load().finally(() => setLoading(false));
  }, [load]);

  useEffect(() => {
    const channel = supabase
      .channel(`chat-admin-${userId}`)
      .on('postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'chat_messages', filter: `user_id=eq.${userId}` },
        (payload) => {
          const msg = payload.new as ChatMessage;
          setMessages((prev) => prev.some((m) => m.id === msg.id) ? prev : [...prev, msg]);
        },
      )
      .on('postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'chat_messages', filter: `user_id=eq.${userId}` },
        (payload) => {
          const updated = payload.new as ChatMessage;
          setMessages((prev) => prev.map((m) => (m.id === updated.id ? updated : m)));
        },
      )
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [userId]);

  // Polling fallback — reload every 5s in case realtime drops.
  useEffect(() => {
    const id = window.setInterval(() => { load(); }, 5000);
    return () => window.clearInterval(id);
  }, [load]);

  // Mark user messages as read
  useEffect(() => {
    const unread = messages.filter((m) => m.sender_role === 'user' && !m.read_at);
    if (unread.length === 0) return;
    unread.forEach((m) => {
      supabase.from('chat_messages').update({ read_at: new Date().toISOString() }).eq('id', m.id).then();
    });
  }, [messages]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  async function send() {
    const body = text.trim();
    if (!body || sending) return;
    if (body.length > MAX_LEN) { notify(`Message too long (max ${MAX_LEN} characters).`, 'error'); return; }
    setSending(true);
    const { error } = await supabase.rpc('send_chat_message', {
      p_user_id: userId,
      p_body: body,
    });
    setSending(false);
    if (error) {
      console.error('chat send error:', error);
      notify('Could not send your reply.', 'error');
      return;
    }
    setText('');
    await load();
  }

  return (
    <div className="p-4 sm:p-6 max-w-3xl mx-auto animate-fade-in">
      {/* Header with back button */}
      <div className="flex items-center gap-3 mb-4">
        <button onClick={onBack} className="btn-ghost w-9 h-9 rounded-xl p-0 flex items-center justify-center shrink-0" aria-label="Back to inbox">
          <ArrowLeft className="w-5 h-5" />
        </button>
        <Avatar avatarUrl={profile?.avatar_url ?? ''} name={profile?.full_name ?? 'User'} />
        <div className="min-w-0">
          <h1 className="text-base sm:text-lg font-extrabold text-[var(--text-primary)] truncate">
            {profile?.full_name ?? 'Loading…'}
          </h1>
          {profile?.mobile && <p className="text-xs text-[var(--text-muted)]">{profile.mobile}</p>}
        </div>
      </div>

      <div className="card overflow-hidden flex flex-col" style={{ height: 'calc(100vh - 220px)', minHeight: '380px' }}>
        <div className="flex-1 overflow-y-auto p-4 space-y-3">
          {loading ? (
            <div className="flex items-center justify-center h-full">
              <div className="w-6 h-6 border-2 border-[var(--brand-500)] border-t-transparent rounded-full animate-spin" />
            </div>
          ) : messages.length === 0 ? (
            <EmptyState icon={MessageCircle} title="No messages" hint="This conversation is empty." />
          ) : (
            messages.map((m) => <Bubble key={m.id} msg={m} mine={m.sender_id === adminId} />)
          )}
          <div ref={bottomRef} />
        </div>

        <div className="border-t border-[var(--border-subtle)] p-3 flex items-end gap-2 bg-[var(--bg-surface)]">
          <textarea
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } }}
            rows={1}
            placeholder="Reply as admin…"
            maxLength={MAX_LEN}
            className="flex-1 resize-none rounded-xl bg-[var(--bg-elevated)] border border-[var(--border-subtle)] px-3.5 py-2.5 text-sm text-[var(--text-primary)] placeholder:text-[var(--text-muted)] focus:outline-none focus:ring-2 focus:ring-[var(--brand-500)]/40 max-h-28"
          />
          <button
            onClick={send}
            disabled={sending || !text.trim()}
            className="btn-primary shrink-0 w-10 h-10 rounded-xl flex items-center justify-center p-0"
            aria-label="Send reply"
          >
            <Send className="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
  );
}

/* ─────────────────────────── Shared bits ──────────────────────────── */

function Bubble({ msg, mine }: { msg: ChatMessage; mine: boolean }) {
  return (
    <div className={`flex ${mine ? 'justify-end' : 'justify-start'}`}>
      <div className={`max-w-[80%] sm:max-w-[70%] ${mine ? 'items-end' : 'items-start'} flex flex-col gap-1`}>
        <div
          className={`rounded-2xl px-3.5 py-2.5 text-sm whitespace-pre-wrap break-words ${
            mine
              ? 'bg-[var(--brand-500)] text-white rounded-br-md'
              : 'bg-[var(--bg-elevated)] text-[var(--text-primary)] border border-[var(--border-subtle)] rounded-bl-md'
          }`}
        >
          {msg.body}
        </div>
        <div className={`flex items-center gap-1 text-[10px] text-[var(--text-muted)] px-1 ${mine ? 'flex-row-reverse' : ''}`}>
          <span>{timeAgo(msg.created_at)}</span>
          {mine && (msg.read_at ? <CheckCheck className="w-3 h-3 text-[var(--brand-400)]" /> : <Circle className="w-2.5 h-2.5 fill-current" />)}
        </div>
      </div>
    </div>
  );
}

function Avatar({ avatarUrl, name }: { avatarUrl: string; name: string }) {
  const isIcon = avatarUrl.startsWith('icon-');
  if (avatarUrl && !isIcon) {
    return (
      <img src={avatarUrl} alt={name} className="w-10 h-10 rounded-xl object-cover shrink-0" />
    );
  }
  const initials = name.split(' ').map((w) => w[0]).slice(0, 2).join('').toUpperCase() || '?';
  return (
    <div className="w-10 h-10 rounded-xl bg-[var(--bg-elevated)] border border-[var(--border-subtle)] flex items-center justify-center shrink-0">
      {isIcon ? <UserIcon className="w-5 h-5 text-[var(--text-muted)]" /> : (
        <span className="text-xs font-bold text-[var(--text-muted)]">{initials}</span>
      )}
    </div>
  );
}

function timeAgo(iso: string): string {
  const date = new Date(iso);
  const diff = Date.now() - date.getTime();
  const sec = Math.floor(diff / 1000);
  if (sec < 60) return 'just now';
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h`;
  const day = Math.floor(hr / 24);
  if (day < 7) return `${day}d`;
  return date.toLocaleDateString('en-PH', { month: 'short', day: 'numeric' });
}
