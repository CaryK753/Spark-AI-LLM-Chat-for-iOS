# Spark-AI-LLM-Chat-for-iOS

Spark AI Chat是一个基于SwiftUI编写的AI（LLM）聊天app，它支持：

1. ✅用户自定义API端点，兼容标准的OpenAI API格式即可
2. ✅支持使用Vision API上传图片（需要模型支持多模态输入）
3. ✅聊天记录搜索
4. ✅流畅的动画效果和手势操作
5. ✅长按删除、重命名或导出对话
6. ✅支持接入Supabase后端，进行用户鉴权、用户资料管理和消息同步等功能
7. ✅使用Quicklook预览图片或其他附件
8. ✅支持启用“本地模式”，所有数据存储在本地
9. ✅流畅的打字机动画和振动反馈

## 关于“默认API端点”

你需要在ContentView.swift的第917～919行自行配置:

```swift
// 创建默认配置（从旧的设置迁移）
            let defaultApiKey = UserDefaults.standard.string(forKey: "api.key") ?? "put_your_api_key_here"
            let defaultEndpoint = UserDefaults.standard.string(forKey: "api.endpoint") ?? "https://example.com/api/v1/chat/completions"
            let defaultModelId = UserDefaults.standard.string(forKey: "api.model") ?? "put_your_model_id_here"
```

当然，你也可以稍后在app的设置页面填入这些信息。

## 关于Supabase服务

你需要在ContentView.swift的第34～37行自行配置:

```swift
// MARK: - Supabase Configuration
struct SupabaseConfig {
    // 请填写您的 Supabase 配置
    static let url = "https://example.supabase.co"
    static let anonKey = "put_your_anonKey_here"
    static let avatarsBucket = "avatars" // SQL 中建议的 bucket 名称
    static let sessionDefaultsKey = "supabase.session"
}
```

接着进入Supabase控制台，使用SQL Editor创建database：

```sql
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


```

为了保证同步服务正常进行，你需要为conversations和message这两个表格启用realtime功能。还需要在storage中创建一个名为avatars的存储桶，并将权限设置为public。

## 关于依赖包

- API请求使用[LLMChatOpenAI](https://github.com/kevinhermawan/swift-llm-chat-openai)
- Markdown以及latex渲染使用[WKMarkdownView](https://github.com/weihas/WKMarkdownView)
- [Supabase SDK for Swift](https://github.com/supabase/supabase-swift)

## 不足之处

1. ❌受限于LLMChatOpenAI依赖包，目前无法实现附件上传功能
2. ❌暂不支持Mermaid图表渲染
3. ❌思考类模型支持不足
