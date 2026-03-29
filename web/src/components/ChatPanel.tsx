import { useState, useRef, useEffect, useCallback } from 'react';
import {
  Box, Fab, Paper, Typography, IconButton, TextField, CircularProgress, Chip,
} from '@mui/material';
import ChatBubbleOutlineIcon from '@mui/icons-material/ChatBubbleOutline';
import CloseIcon from '@mui/icons-material/Close';
import SendIcon from '@mui/icons-material/Send';

// ── Types ───────────────────────────────────────────────────────────────────

interface ActionTaken {
  type: string;
  description: string;
}

interface Message {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  actions?: ActionTaken[];
  timestamp: number;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

const SESSION_KEY = 'lutron-chat-messages';

function loadMessages(): Message[] {
  try {
    const raw = sessionStorage.getItem(SESSION_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

function saveMessages(messages: Message[]) {
  sessionStorage.setItem(SESSION_KEY, JSON.stringify(messages));
}

// ── Component ───────────────────────────────────────────────────────────────

export function ChatPanel() {
  const [open, setOpen] = useState(false);
  const [messages, setMessages] = useState<Message[]>(loadMessages);
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(false);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  // Persist messages to sessionStorage
  useEffect(() => {
    saveMessages(messages);
  }, [messages]);

  // Auto-scroll to bottom on new messages
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages, loading]);

  // Focus input when panel opens
  useEffect(() => {
    if (open) {
      setTimeout(() => inputRef.current?.focus(), 100);
    }
  }, [open]);

  const sendMessage = useCallback(async () => {
    const text = input.trim();
    if (!text || loading) return;

    const userMsg: Message = {
      id: `${Date.now()}-user`,
      role: 'user',
      content: text,
      timestamp: Date.now(),
    };

    setMessages((prev) => [...prev, userMsg]);
    setInput('');
    setLoading(true);

    try {
      // Build history from previous messages (limit to last 20)
      const history = messages.slice(-20).map((m) => ({
        role: m.role,
        content: m.content,
      }));

      const res = await fetch('/api/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: text, history }),
      });

      if (!res.ok) {
        const errData = await res.json().catch(() => ({ error: `HTTP ${res.status}` }));
        throw new Error(errData.error || `HTTP ${res.status}`);
      }

      const data = await res.json();

      const assistantMsg: Message = {
        id: `${Date.now()}-assistant`,
        role: 'assistant',
        content: data.reply,
        actions: data.actions?.length > 0 ? data.actions : undefined,
        timestamp: Date.now(),
      };
      setMessages((prev) => [...prev, assistantMsg]);
    } catch (err) {
      const errorMsg: Message = {
        id: `${Date.now()}-error`,
        role: 'assistant',
        content: `Sorry, something went wrong: ${err instanceof Error ? err.message : String(err)}`,
        timestamp: Date.now(),
      };
      setMessages((prev) => [...prev, errorMsg]);
    } finally {
      setLoading(false);
    }
  }, [input, loading, messages]);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  };

  if (!open) {
    return (
      <Fab
        color="primary"
        onClick={() => setOpen(true)}
        sx={{
          position: 'fixed',
          bottom: 24,
          right: 24,
          zIndex: 1300,
        }}
      >
        <ChatBubbleOutlineIcon />
      </Fab>
    );
  }

  return (
    <Paper
      elevation={16}
      sx={{
        position: 'fixed',
        bottom: 24,
        right: 24,
        width: { xs: 'calc(100vw - 32px)', sm: 380 },
        height: { xs: 'calc(100vh - 120px)', sm: 520 },
        zIndex: 1300,
        display: 'flex',
        flexDirection: 'column',
        borderRadius: 3,
        border: '1px solid rgba(255,255,255,0.1)',
        bgcolor: 'background.default',
        overflow: 'hidden',
      }}
    >
      {/* Header */}
      <Box
        sx={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          px: 2,
          py: 1.5,
          borderBottom: '1px solid rgba(255,255,255,0.08)',
          bgcolor: 'background.paper',
        }}
      >
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
          <ChatBubbleOutlineIcon sx={{ fontSize: 18, color: 'primary.main' }} />
          <Typography variant="subtitle2" fontWeight={700}>
            Home Assistant
          </Typography>
        </Box>
        <IconButton size="small" onClick={() => setOpen(false)} sx={{ color: 'text.secondary' }}>
          <CloseIcon fontSize="small" />
        </IconButton>
      </Box>

      {/* Messages */}
      <Box
        sx={{
          flex: 1,
          overflowY: 'auto',
          px: 2,
          py: 1.5,
          display: 'flex',
          flexDirection: 'column',
          gap: 1.5,
        }}
      >
        {messages.length === 0 && !loading && (
          <Box sx={{ textAlign: 'center', mt: 4, px: 2 }}>
            <Typography variant="body2" color="text.disabled" sx={{ mb: 1 }}>
              Ask me to control your home
            </Typography>
            <Typography variant="caption" color="text.disabled">
              Try "Turn off all the lights" or "What's on right now?"
            </Typography>
          </Box>
        )}

        {messages.map((msg) => (
          <Box
            key={msg.id}
            sx={{
              display: 'flex',
              justifyContent: msg.role === 'user' ? 'flex-end' : 'flex-start',
            }}
          >
            <Box
              sx={{
                maxWidth: '85%',
                px: 1.5,
                py: 1,
                borderRadius: 2,
                bgcolor:
                  msg.role === 'user'
                    ? 'rgba(245,166,35,0.15)'
                    : 'rgba(255,255,255,0.04)',
                border:
                  msg.role === 'user'
                    ? '1px solid rgba(245,166,35,0.3)'
                    : '1px solid rgba(255,255,255,0.06)',
              }}
            >
              <Typography
                variant="body2"
                sx={{
                  whiteSpace: 'pre-wrap',
                  wordBreak: 'break-word',
                  fontSize: 13,
                  lineHeight: 1.5,
                }}
              >
                {msg.content}
              </Typography>

              {msg.actions && msg.actions.length > 0 && (
                <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 0.5, mt: 0.75 }}>
                  {msg.actions.map((a, i) => (
                    <Chip
                      key={i}
                      label={a.description}
                      size="small"
                      variant="outlined"
                      sx={{
                        fontSize: 10,
                        height: 22,
                        borderColor: 'rgba(245,166,35,0.3)',
                        color: 'primary.main',
                      }}
                    />
                  ))}
                </Box>
              )}
            </Box>
          </Box>
        ))}

        {loading && (
          <Box sx={{ display: 'flex', justifyContent: 'flex-start' }}>
            <Box
              sx={{
                px: 2,
                py: 1.25,
                borderRadius: 2,
                bgcolor: 'rgba(255,255,255,0.04)',
                border: '1px solid rgba(255,255,255,0.06)',
                display: 'flex',
                alignItems: 'center',
                gap: 1,
              }}
            >
              <CircularProgress size={14} sx={{ color: 'text.secondary' }} />
              <Typography variant="caption" color="text.secondary">
                Thinking...
              </Typography>
            </Box>
          </Box>
        )}

        <div ref={messagesEndRef} />
      </Box>

      {/* Input */}
      <Box
        sx={{
          px: 1.5,
          py: 1.5,
          borderTop: '1px solid rgba(255,255,255,0.08)',
          bgcolor: 'background.paper',
          display: 'flex',
          alignItems: 'flex-end',
          gap: 1,
        }}
      >
        <TextField
          inputRef={inputRef}
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Describe what you'd like to do..."
          variant="outlined"
          size="small"
          fullWidth
          multiline
          maxRows={3}
          disabled={loading}
          sx={{
            '& .MuiOutlinedInput-root': {
              fontSize: 13,
              borderRadius: 2,
            },
          }}
        />
        <IconButton
          onClick={sendMessage}
          disabled={!input.trim() || loading}
          color="primary"
          sx={{
            bgcolor: input.trim() ? 'primary.main' : 'transparent',
            color: input.trim() ? 'background.default' : 'text.disabled',
            '&:hover': { bgcolor: input.trim() ? 'primary.dark' : 'transparent' },
            width: 36,
            height: 36,
          }}
        >
          <SendIcon sx={{ fontSize: 18 }} />
        </IconButton>
      </Box>
    </Paper>
  );
}
