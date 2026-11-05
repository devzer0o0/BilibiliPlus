import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/models/ai_recommend/video_features.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_provider.dart';
import 'package:PiliPlus/utils/security/secret_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class CapturedRequest {
  final List<int> body = [];
  late RequestOptions options;

  String get text => utf8.decode(body);
}

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final FutureOr<ResponseBody> Function(CapturedRequest request) handler;
  final List<CapturedRequest> captured = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = CapturedRequest()..options = options;
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        request.body.addAll(chunk);
      }
    }
    captured.add(request);
    return handler(request);
  }

  @override
  void close({bool force = false}) {}
}

AiBatchRequest request({bool jsonMode = true}) => AiBatchRequest(
  candidates: [
    AiCandidateEnvelope(
      requestId: 'c1',
      features: const VideoFeatures(
        bvid: 'BV1',
        title: 'NAS 搭建教程',
        description: '一步一步搭建 NAS',
        category: '视频',
        durationSeconds: 300,
      ),
    ),
  ],
  interests: const [
    AiInterestRef(id: 'interest_1', label: 'NAS'),
  ],
  interestDescription: '最近想看 NAS 实践',
);

String envelope(String content) => jsonEncode({
  'choices': [
    {
      'message': {'content': content},
    },
  ],
  'usage': {'prompt_tokens': 11, 'completion_tokens': 7},
});

String scoreBody() => jsonEncode({
  'schemaVersion': 1,
  'items': [
    {
      'candidateId': 'c1',
      'relevance': 0.9,
      'confidence': 0.8,
      'matchedInterestIds': ['interest_1'],
      'topics': ['NAS'],
    },
  ],
});

OpenAiCompatibleProvider provider(
  FakeAdapter adapter, {
  String baseUrl = 'http://127.0.0.1:9/v1',
  bool jsonMode = true,
}) => OpenAiCompatibleProvider(
  config: AiProviderConfig(
    baseUrl: baseUrl,
    model: 'test-model',
    jsonMode: jsonMode,
  ),
  secrets: MemorySecretStore({SecretKeys.aiApiKey: 'sk-test'}),
  dio: Dio(
    BaseOptions(
      responseType: ResponseType.plain,
      followRedirects: false,
      validateStatus: (_) => true,
    ),
  )..httpClientAdapter = adapter,
);

void main() {
  test(
    'builds the endpoint, sends only its own credentials and parses JSON',
    () async {
      final adapter = FakeAdapter(
        (_) => ResponseBody.fromString(
          envelope(scoreBody()),
          200,
          headers: {
            'content-type': ['application/json'],
          },
        ),
      );
      final result = await provider(adapter).score(request());
      expect(result.scores.scoresByBvid['BV1']!.relevance, 0.9);
      expect(result.promptTokens, 11);
      expect(result.completionTokens, 7);

      final sent = adapter.captured.single;
      expect(
        sent.options.uri.toString(),
        'http://127.0.0.1:9/v1/chat/completions',
      );
      expect(sent.options.headers['Authorization'], 'Bearer sk-test');
      expect(sent.options.headers['Cookie'], isNull);
      expect(
        sent.options.headers.keys
            .map((k) => k.toLowerCase())
            .where((k) => k.startsWith('x-bili-')),
        isEmpty,
      );
      expect(sent.text, contains('"model":"test-model"'));
      expect(sent.text, contains('NAS 搭建教程'));
      expect(sent.text, isNot(contains('BV1')));
      expect(sent.text, contains('"response_format":{"type":"json_object"}'));
    },
  );

  test('jsonMode off omits the response_format parameter', () async {
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromString(
        envelope(scoreBody()),
        200,
      ),
    );
    await provider(adapter, jsonMode: false).score(request());
    expect(adapter.captured.single.text, isNot(contains('response_format')));
  });

  test('401 is an auth failure and is not retried', () async {
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromString('{"error":"bad key"}', 401),
    );
    await expectLater(
      provider(adapter).score(request()),
      throwsA(
        isA<AiProviderException>().having(
          (e) => e.kind,
          'kind',
          AiProviderFailure.auth,
        ),
      ),
    );
    expect(adapter.captured.length, 1);
  });

  test('429 keeps Retry-After for the caller', () async {
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromString(
        '{"error":"slow down"}',
        429,
        headers: {
          'retry-after': ['7'],
        },
      ),
    );
    await expectLater(
      provider(adapter).score(request()),
      throwsA(
        isA<AiProviderException>()
            .having((e) => e.kind, 'kind', AiProviderFailure.rateLimit)
            .having(
              (e) => e.retryAfter,
              'retryAfter',
              const Duration(seconds: 7),
            ),
      ),
    );
  });

  test('5xx is retryable, 4xx is not treated as success', () async {
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromString('{}', 503),
    );
    await expectLater(
      provider(adapter).score(request()),
      throwsA(
        isA<AiProviderException>()
            .having((e) => e.kind, 'kind', AiProviderFailure.server)
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );
  });

  test(
    'redirects are refused instead of following credentials elsewhere',
    () async {
      final adapter = FakeAdapter(
        (_) => ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['https://evil.example/collect'],
          },
        ),
      );
      await expectLater(
        provider(adapter).score(request()),
        throwsA(
          isA<AiProviderException>().having(
            (e) => e.kind,
            'kind',
            AiProviderFailure.redirect,
          ),
        ),
      );
    },
  );

  test('fenced JSON is accepted, malformed content is rejected', () async {
    final fence = String.fromCharCodes(const [96, 96, 96]);
    final fenced = FakeAdapter(
      (_) => ResponseBody.fromString(
        envelope(fence + 'json\n' + scoreBody() + '\n' + fence),
        200,
      ),
    );
    final result = await provider(fenced).score(request());
    expect(result.scores.scoresByBvid, isNotEmpty);

    final broken = FakeAdapter(
      (_) => ResponseBody.fromString(
        envelope('{"schemaVersion":1,"items":[{"candidateId":"c1"}'),
        200,
      ),
    );
    await expectLater(
      provider(broken).score(request()),
      throwsA(
        isA<AiProviderException>().having(
          (e) => e.kind,
          'kind',
          AiProviderFailure.invalidResponse,
        ),
      ),
    );
  });

  test('missing content is an invalid response, not an empty score', () async {
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromString('{"choices":[{"message":{}}]}', 200),
    );
    await expectLater(
      provider(adapter).score(request()),
      throwsA(
        isA<AiProviderException>().having(
          (e) => e.kind,
          'kind',
          AiProviderFailure.invalidResponse,
        ),
      ),
    );
  });

  test('endpoint rules reject plaintext remote servers and query strings', () {
    const remote = AiProviderConfig(
      baseUrl: 'http://example.com/v1',
      model: 'm',
    );
    expect(() => remote.endpoint, throwsA(isA<AiProviderException>()));

    const withQuery = AiProviderConfig(
      baseUrl: 'https://example.com/v1?key=1',
      model: 'm',
    );
    expect(() => withQuery.endpoint, throwsA(isA<AiProviderException>()));

    const loopback = AiProviderConfig(
      baseUrl: 'http://127.0.0.1:9000/v1/',
      model: 'm',
    );
    expect(
      loopback.endpoint.toString(),
      'http://127.0.0.1:9000/v1/chat/completions',
    );
  });

  test('private HTTP needs an explicit opt-in; public HTTP never passes', () {
    const privateHttp = AiProviderConfig(
      baseUrl: 'http://10.0.10.102:3001/v1',
      model: 'm',
    );
    expect(
      () => privateHttp.endpoint,
      throwsA(isA<AiProviderException>()),
    );

    const allowed = AiProviderConfig(
      baseUrl: 'http://10.0.10.102:3001/v1',
      model: 'm',
      allowInsecureHttp: true,
    );
    expect(
      allowed.endpoint.toString(),
      'http://10.0.10.102:3001/v1/chat/completions',
    );

    const publicHttp = AiProviderConfig(
      baseUrl: 'http://example.com/v1',
      model: 'm',
      allowInsecureHttp: true,
    );
    expect(
      () => publicHttp.endpoint,
      throwsA(isA<AiProviderException>()),
    );

    expect(AiProviderConfig.isPrivateHost('192.168.1.2'), isTrue);
    expect(AiProviderConfig.isPrivateHost('172.20.0.1'), isTrue);
    expect(AiProviderConfig.isPrivateHost('8.8.8.8'), isFalse);
    expect(AiProviderConfig.isPrivateHost('fd00::1'), isTrue);
  });

  test('missing API key fails before any request', () async {
    final adapter = FakeAdapter((_) => ResponseBody.fromString('{}', 200));
    final p = OpenAiCompatibleProvider(
      config: const AiProviderConfig(
        baseUrl: 'https://example.com/v1',
        model: 'm',
      ),
      secrets: MemorySecretStore(),
      dio: Dio()..httpClientAdapter = adapter,
    );
    await expectLater(
      p.score(request()),
      throwsA(
        isA<AiProviderException>().having(
          (e) => e.kind,
          'kind',
          AiProviderFailure.notConfigured,
        ),
      ),
    );
    expect(adapter.captured, isEmpty);
  });
}
