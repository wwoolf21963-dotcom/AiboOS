-- D1 schema for AiboOS Internet Relay v1
CREATE TABLE IF NOT EXISTS accounts (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  photo TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_id TEXT NOT NULL,
  from_id TEXT NOT NULL,
  to_id TEXT NOT NULL,
  text TEXT NOT NULL,
  ts INTEGER NOT NULL,
  delivered_at INTEGER,
  UNIQUE(from_id,client_id)
);
CREATE INDEX IF NOT EXISTS messages_inbox ON messages(to_id,id);
CREATE INDEX IF NOT EXISTS messages_receipts ON messages(from_id,delivered_at);
CREATE TABLE IF NOT EXISTS rate_limits(
  key TEXT PRIMARY KEY,
  window_start INTEGER NOT NULL,
  hits INTEGER NOT NULL
);
