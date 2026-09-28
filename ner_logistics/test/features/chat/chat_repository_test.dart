import 'dart:convert';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ner_logistics/features/chat/chat_controller.dart';

ChatRepository _repo(http.Client client, {String? token = 'jwt'}) => ChatRepository(
      baseUrl: 'https://x.supabase.co',
      apiKey: 'pk',
      accessToken: () async => token,
      client: client,
    );

void main() {
  test('streams chunks, sends auth + capped history', () async {
    late http.BaseRequest seen;
    late Map<String, dynamic> body;
    final client = MockClient.streaming((req, bodyStream) async {
      seen = req;
      body = jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
      return http.StreamedResponse(Stream.fromIterable([utf8.encode('Risk on '), utf8.encode('NH-10 is high.')]), 200);
    });

    final history = [for (var i = 0; i < 20; i++) ChatMessage(i.isEven ? 'user' : 'assistant', 'm$i')];
    final chunks = await _repo(client).send(history, 'hi').toList();

    expect(chunks.join(), 'Risk on NH-10 is high.');
    expect(seen.url.toString(), 'https://x.supabase.co/functions/v1/chat');
    expect(seen.headers['Authorization'], 'Bearer jwt');
    expect(seen.headers['apikey'], 'pk');
    expect(body['language'], 'hi');
    expect((body['messages'] as List).length, chatHistoryLimit);
    expect((body['messages'] as List).last['content'], 'm19');
  });

  test('429 maps to the friendly message; server message wins on 403', () async {
    final limited = MockClient((_) async => http.Response('{"error":"rate_limited"}', 429));
    await expectLater(
      _repo(limited).send([const ChatMessage('user', 'q')], 'en').toList(),
      throwsA(isA<ChatException>().having((e) => e.message, 'message', contains('this hour'))),
    );

    final noRole = MockClient((_) async => http.Response('{"error":"no_role","message":"Contact admin."}', 403));
    await expectLater(
      _repo(noRole).send([const ChatMessage('user', 'q')], 'en').toList(),
      throwsA(isA<ChatException>().having((e) => e.message, 'message', 'Contact admin.')),
    );
  });

  test('no session → sign-in error without a request', () async {
    var called = false;
    final client = MockClient((_) async {
      called = true;
      return http.Response('', 200);
    });
    await expectLater(
      _repo(client, token: null).send([const ChatMessage('user', 'q')], 'en').toList(),
      throwsA(isA<ChatException>().having((e) => e.status, 'status', 401)),
    );
    expect(called, isFalse);
  });

  test('unsupported locale falls back to English', () {
    expect(chatLanguage(const Locale('as')), 'as');
    expect(chatLanguage(const Locale('fr')), 'en');
  });
}
