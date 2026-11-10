-- ---- Feedback ---------------------------------------------------------------------------
-- Nutzer schicken Text und Bilder; der Ablauf "Feedback senden" (feedback.yml) mailt sie an den Betreiber.
-- Bilder liegen nur bis zum Versand in der Datenbank.
create table if not exists feedback (
  id         bigint generated always as identity primary key,
  user_id    uuid references auth.users (id) on delete set null,
  user_email text,
  league_id  uuid references leagues (id) on delete set null,
  league_name text,
  team_name  text,
  page       text,
  device     text,
  message    text not null,
  attempts   int  not null default 0,
  sent_at    timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists feedback_images (
  id          bigint generated always as identity primary key,
  feedback_id bigint not null references feedback (id) on delete cascade,
  mime        text not null,
  data        bytea not null
);
