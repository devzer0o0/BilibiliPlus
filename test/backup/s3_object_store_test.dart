import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/models/backup/backup_config.dart';
import 'package:PiliPlus/utils/backup/s3_object_store.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class Captured {
  final List<int> body = [];
  late RequestOptions options;
}

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final FutureOr<ResponseBody> Function(Captured request) handler;
  final List<Captured> captured = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = Captured()..options = options;
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

S3BackupConfig config({
  S3AddressingMode addressing = S3AddressingMode.pathStyle,
  String prefix = 'PiliPlusBackups',
}) => S3BackupConfig(
  endpoint: 'http://127.0.0.1:9000',
  bucket: 'test-bucket',
  region: 'us-east-1',
  prefix: prefix,
  addressing: addressing,
);

Dio dioWith(FakeAdapter adapter) => Dio(
  BaseOptions(
    responseType: ResponseType.bytes,
    followRedirects: false,
    validateStatus: (_) => true,
  ),
)..httpClientAdapter = adapter;

S3ObjectStore store(FakeAdapter adapter, {String prefix = 'PiliPlusBackups'}) =>
    S3ObjectStore(
      config: config(prefix: prefix),
      credentials: const S3Credentials(
        accessKeyId: 'AKIDEXAMPLE',
        secretAccessKey: 'secret',
        sessionToken: 'session',
      ),
      dio: dioWith(adapter),
    );

String listXml({bool truncated = false, String? token}) {
  final key = Uri.encodeComponent('备份 space+plus/中文/2026.ppbackup');
  return '<ListBucketResult>'
          '<IsTruncated>' +
      truncated.toString() +
      '</IsTruncated>' +
      (token == null
          ? ''
          : '<NextContinuationToken>' + token + '</NextContinuationToken>') +
      '<Contents>'
          '<Key>' +
      key +
      '</Key>'
          '<Size>123</Size>'
          '<LastModified>2026-11-05T01:02:03.000Z</LastModified>'
          '<ETag>"abc"</ETag>'
          '</Contents>'
          '</ListBucketResult>';
}

void main() {
  test('lists with URL-encoded keys and pagination token', () async {
    final adapter = FakeAdapter(
      (_) =>
          ResponseBody.fromString(listXml(truncated: true, token: 'next'), 200),
    );
    final page = await store(adapter).listObjects(prefix: 'p');
    expect(page.objects.single.key, '备份 space+plus/中文/2026.ppbackup');
    expect(page.objects.single.size, 123);
    expect(page.nextContinuationToken, 'next');
    expect(page.isTruncated, isTrue);
    final uri = adapter.captured.single.options.uri;
    expect(uri.path, startsWith('/test-bucket'));
    expect(uri.queryParameters['list-type'], '2');
    final auth = adapter.captured.single.options.headers['authorization'];
    expect(auth, contains('AWS4-HMAC-SHA256'));
    expect(auth, contains('us-east-1/s3/aws4_request'));
    expect(
      adapter.captured.single.options.headers['x-amz-security-token'],
      'session',
    );
  });

  test('virtual-hosted addressing puts the bucket in the host', () async {
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromString(listXml(), 200),
    );
    final s = S3ObjectStore(
      config: config(addressing: S3AddressingMode.virtualHosted),
      credentials: const S3Credentials(
        accessKeyId: 'AK',
        secretAccessKey: 'SK',
      ),
      dio: dioWith(adapter),
    );
    await s.listObjects();
    expect(
      adapter.captured.single.options.uri.host,
      'test-bucket.127.0.0.1',
    );
  });

  test('put uses conditional request and signed body hash', () async {
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromBytes(const [], 200),
    );
    final bytes = Uint8List.fromList(List<int>.generate(50, (i) => i));
    await store(adapter).putObject(
      key: 'a/b.ppbackup',
      bytes: bytes,
      ifNoneMatch: '*',
      metadata: const {'sha256': 'abc'},
    );
    final captured = adapter.captured.single;
    expect(captured.options.method, 'PUT');
    expect(captured.options.headers['if-none-match'], '*');
    expect(captured.body, bytes);
    expect(captured.options.headers['x-amz-content-sha256'], isNotEmpty);
    expect(captured.options.headers['x-amz-meta-sha256'], 'abc');
    expect(captured.options.uri.path, '/test-bucket/a/b.ppbackup');
  });

  test('403 SignatureDoesNotMatch maps to signature failure', () async {
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromString(
        '<Error><Code>SignatureDoesNotMatch</Code></Error>',
        403,
      ),
    );
    await expectLater(
      store(adapter).listObjects(),
      throwsA(
        isA<S3Exception>().having(
          (e) => e.failure,
          'failure',
          S3Failure.signature,
        ),
      ),
    );
  });

  test('412 maps to a precondition failure and never overwrites', () async {
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromString('', 412),
    );
    await expectLater(
      store(adapter).putObject(
        key: 'a.ppbackup',
        bytes: Uint8List(3),
        ifNoneMatch: '*',
      ),
      throwsA(
        isA<S3Exception>().having(
          (e) => e.failure,
          'failure',
          S3Failure.preconditionFailed,
        ),
      ),
    );
  });

  test('clock skew and region errors are distinct', () async {
    final skew = FakeAdapter(
      (_) => ResponseBody.fromString(
        '<Error><Code>RequestTimeTooSkewed</Code></Error>',
        400,
      ),
    );
    await expectLater(
      store(skew).listObjects(),
      throwsA(
        isA<S3Exception>().having(
          (e) => e.failure,
          'failure',
          S3Failure.clockSkew,
        ),
      ),
    );
    final region = FakeAdapter(
      (_) => ResponseBody.fromString(
        '<Error><Code>AuthorizationHeaderMalformed</Code></Error>',
        400,
      ),
    );
    await expectLater(
      store(region).listObjects(),
      throwsA(
        isA<S3Exception>().having(
          (e) => e.failure,
          'failure',
          S3Failure.region,
        ),
      ),
    );
  });

  test('uploadVerified accepts an identical existing object', () async {
    final body = Uint8List.fromList([1, 2, 3]);
    final adapter = FakeAdapter((request) {
      if (request.options.method == 'PUT') {
        return ResponseBody.fromString('', 412);
      }
      return ResponseBody.fromBytes(body, 200);
    });
    expect(
      await store(adapter).uploadVerified(
        key: 'a.ppbackup',
        bytes: body,
        sha256Hex: sha256.convert(body).toString(),
      ),
      isTrue,
    );
  });

  test(
    'uploadVerified refuses a different object under the same key',
    () async {
      final body = Uint8List.fromList([1, 2, 3]);
      final adapter = FakeAdapter((request) {
        if (request.options.method == 'PUT') {
          return ResponseBody.fromString('', 412);
        }
        return ResponseBody.fromBytes(Uint8List.fromList([9]), 200);
      });
      await expectLater(
        store(adapter).uploadVerified(
          key: 'a.ppbackup',
          bytes: body,
          sha256Hex: sha256.convert(body).toString(),
        ),
        throwsA(
          isA<S3Exception>().having(
            (e) => e.failure,
            'failure',
            S3Failure.conflict,
          ),
        ),
      );
    },
  );

  test('connection test works without delete permission', () async {
    final objects = <String, Uint8List>{};
    final adapter = FakeAdapter((request) {
      final uri = request.options.uri;
      if (request.options.method == 'GET' &&
          uri.queryParameters.containsKey('list-type')) {
        return ResponseBody.fromString(listXml(), 200);
      }
      if (request.options.method == 'PUT') {
        objects[uri.path] = Uint8List.fromList(request.body);
        return ResponseBody.fromString('', 200);
      }
      if (request.options.method == 'GET') {
        return ResponseBody.fromBytes(objects[uri.path] ?? Uint8List(0), 200);
      }
      return ResponseBody.fromString(
        '<Error><Code>AccessDenied</Code></Error>',
        403,
      );
    });
    final report = await store(adapter).connectionTest();
    expect(report.canRead, isTrue);
    expect(report.canWrite, isTrue);
    expect(report.canDelete, isFalse);
    expect(report.usable, isTrue);
    expect(report.message, contains('删除'));
    expect(objects.keys.single, contains('_probe'));
  });
}
