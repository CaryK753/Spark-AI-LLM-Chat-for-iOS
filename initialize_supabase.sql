-- Supabase initialization SQL for Spark App
-- This script creates tables, indexes, and RLS policies for conversations, messages, and avatar storage

-- ========== AUTH PREREQUISITES ==========
-- Assumes Supabase default auth schema with table auth.users exists

-- ========== TABLES ==========
create schema if not exists public;

create table if not exists public.conversations (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.messages (
  id text primary key,
  conversation_id text not null references public.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('user','assistant')),
  content text not null default '',
  attachments jsonb,
  created_at timestamptz not null default now()
);

-- ========== INDEXES ==========
create index if not exists idx_conversations_user on public.conversations(user_id, created_at desc);
create index if not exists idx_messages_conversation on public.messages(conversation_id, created_at);
create index if not exists idx_messages_user on public.messages(user_id, created_at);

-- ========== RLS ==========
alter table public.conversations enable row level security;
alter table public.messages enable row level security;

drop policy if exists "select own conversations" on public.conversations;
drop policy if exists "upsert own conversations" on public.conversations;
create policy "select own conversations" on public.conversations
for select to authenticated using (user_id = auth.uid());
create policy "upsert own conversations" on public.conversations
for all to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "select own messages" on public.messages;
drop policy if exists "upsert own messages" on public.messages;
create policy "select own messages" on public.messages
for select to authenticated using (user_id = auth.uid());
create policy "upsert own messages" on public.messages
for all to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

-- ========== STORAGE: AVATARS BUCKET ==========
-- Create bucket via UI or SQL; below is policy setup for storage.objects
-- Ensure a bucket with id 'avatars' exists in Storage

-- RLS for storage.objects is always on; add policies
-- Note: storage.objects has columns: bucket_id, name, owner, metadata, ...

-- Public read (optional if bucket is public)
drop policy if exists "Public read avatars" on storage.objects;
create policy "Public read avatars"
on storage.objects for select
to public
using ( bucket_id = 'avatars' );

-- Allow authenticated users to upload to their own folder: <uid>/<filename>
drop policy if exists "Users can upload avatars to own folder" on storage.objects;
create policy "Users can upload avatars to own folder"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- Allow authenticated users to manage their own files (update/delete) (optional)
drop policy if exists "Users manage their own avatars" on storage.objects;
create policy "Users manage their own avatars"
on storage.objects for all
to authenticated
using (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- ========== RE realtime ==========
-- Supabase Realtime for Postgres Changes needs Broadcast enabled in project settings.
-- In the dashboard, enable Realtime for schema 'public' and tables 'conversations', 'messages'.

-- ========== DONE ==========

