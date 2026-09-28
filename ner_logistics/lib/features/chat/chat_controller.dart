import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/supabase/supabase_providers.dart';
import '../auth/application/auth_controller.dart';

/// Read-only operations assistant (supabase/functions/chat) — the same endpoint
/// the website's ChatPanel uses. The function runs every tool as the signed-in
/// user, so the database decides what the assistant may see.
///
/// It streams text/plain. `supabase.functions.invoke` buffers that, so this goes
/// through package:http's StreamedResponse to show text as it arrives.

class ChatMessage {
  final String role; // 'user' | 'assistant'
  final String content;
  const ChatMessage(this.role, this.content);
  Map<String, String> toJson() => {'role': role, 'content': content};
}

class ChatException implements Exception {
  final String message;
  final int? status;
  const ChatException(this.message, [this.status]);
  @override
  String toString() => message;
}

/// Same wording as web/NER-Website/src/lib/chat.ts.
const _friendly = {
  401: 'Your session has expired. Please sign in again.',
  413: 'That conversation is too long. Start a new one.',
  429: "You've asked a lot of questions this hour. Try again shortly.",
  502: 'The assistant is unavailable right now. Route risk and alerts still work.',
};

/// Max turns sent; the server slices to the same bound.
const chatHistoryLimit = 12;

/// Codes the function's prompt knows (LANGUAGES in supabase/functions/chat/prompt.ts).
const _languages = {'en', 'hi', 'as', 'bn', 'nsm', 'lus'};
String chatLanguage(Locale locale) =>
    _languages.contains(locale.languageCode) ? locale.languageCode : 'en';

class ChatRepository {
  ChatRepository({
    required this.baseUrl,
    required this.apiKey,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String apiKey;

  /// Read at send time, not at construction: the session refreshes in the background.
  final Future<String?> Function() accessToken;
  final http.Client _client;

  Stream<String> send(List<ChatMessage> history, String language) async* {
    final token = await accessToken();
    if (token == null) throw const ChatException('The assistant needs a live sign-in.', 401);

    final req = http.Request('POST', Uri.parse('$baseUrl/functions/v1/chat'))
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'apikey': apiKey,
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode({
        'language': language,
        'messages': [
          for (final m in history.skip(history.length > chatHistoryLimit ? history.length - chatHistoryLimit : 0))
            m.toJson(),
        ],
      });

    final res = await _client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      var message = _friendly[res.statusCode] ?? 'The assistant failed (HTTP ${res.statusCode}).';
      try {
        // 403 no_role carries its own wording.
        final body = jsonDecode(await res.stream.bytesToString());
        if (body is Map && body['message'] is String) message = body['message'] as String;
      } catch (_) {/* not JSON; keep the friendly default */}
      throw ChatException(message, res.statusCode);
    }
    yield* res.stream.transform(utf8.decoder);
  }
}

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final config = ref.watch(supabaseConfigProvider);
  final auth = ref.watch(supabaseClientProvider).auth;
  return ChatRepository(
    baseUrl: config.url,
    apiKey: config.publishableKey,
    accessToken: () async {
      var session = auth.currentSession;
      if (session != null && session.isExpired) session = (await auth.refreshSession()).session;
      return session?.accessToken;
    },
  );
});

class ChatState {
  final List<ChatMessage> messages;

  /// True from send() until the stream ends.
  final bool streaming;

  /// Streaming and no text yet (a tool call is running).
  final bool thinking;
  final String? error;

  const ChatState({this.messages = const [], this.streaming = false, this.thinking = false, this.error});
}

class ChatController extends Notifier<ChatState> {
  StreamSubscription<String>? _sub;

  /// Settles the in-flight answer; stop() calls it after cancelling, keeping the partial text.
  void Function()? _finish;

  /// Guards a stale stream from writing into a conversation that has since been reset.
  int _seq = 0;

  @override
  ChatState build() {
    // A new sign-in starts a fresh conversation; one user's chat never shows to the next.
    ref.watch(authRoleProvider);
    ref.onDispose(() => _sub?.cancel());
    _seq++;
    return const ChatState();
  }

  void send(String text, String language) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.streaming) return;

    final id = ++_seq;
    final history = [...state.messages, ChatMessage('user', trimmed)];
    var acc = '';
    state = ChatState(messages: [...history, const ChatMessage('assistant', '')], streaming: true, thinking: true);

    void finish([String? error]) {
      if (id != _seq) return;
      _sub = null;
      // An empty assistant bubble is noise; drop it if nothing arrived.
      state = ChatState(
        messages: acc.isEmpty ? history : [...history, ChatMessage('assistant', acc)],
        error: error,
      );
    }

    _finish = finish;
    _sub = ref.read(chatRepositoryProvider).send(history, language).listen(
      (chunk) {
        if (id != _seq) return;
        acc += chunk;
        state = ChatState(messages: [...history, ChatMessage('assistant', acc)], streaming: true);
      },
      onError: (Object e) => finish(
        acc.isNotEmpty
            ? 'The answer was cut off. Try again.' // keep the partial text visible
            : e is ChatException
                ? e.message
                : e is TimeoutException
                    ? _friendly[502]
                    : 'The assistant could not be reached. Check your connection.',
      ),
      onDone: () => finish(acc.isEmpty ? 'The assistant returned no answer. Try rephrasing.' : null),
      cancelOnError: true,
    );
  }

  void stop() {
    _sub?.cancel();
    _finish?.call();
  }

  void reset() {
    _seq++;
    _sub?.cancel();
    _sub = null;
    state = const ChatState();
  }
}

final chatControllerProvider = NotifierProvider<ChatController, ChatState>(ChatController.new);
