-- ---------------------------------------------------------------------
-- Push-Benachrichtigungen
-- ---------------------------------------------------------------------

-- Interne Einstellungen (z. B. VAPID-Schlüssel) – nur für den Service-Key lesbar
create table if not exists app_config (
  key   text primary key,
  value text not null
);

create table if not exists push_subscriptions (
  endpoint   text primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);

-- Warteschlange: wird alle 15 Minuten vom Workflow "Benachrichtigungen senden" verschickt
create table if not exists notifications (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  title      text not null,
  body       text,
  url        text,
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
alter table notifications add column if not exists expires_at timestamptz;   -- danach nicht mehr senden (z. B. „Du bist dran“)
create index if not exists notifications_unsent on notifications (created_at) where sent_at is null;

