// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/models/backup/backup_config.dart';
import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

class S3Credentials {
  const S3Credentials({
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken,
  });

  final String accessKeyId;
  final String secretAccessKey;
  final String? sessionToken;
}

enum S3Failure {
  auth,
  accessDenied,
  notFound,
  signature,
  region,
  clockSkew,
  preconditionFailed,
  conflict,
  network,
  tls,
  timeout,
  server,
  rateLimited,
  invalidResponse,
  cancelled,
}

class S3Exception implements Exception {
  const S3Exception(
    this.failure,
    this.message, {
    this.statusCode,
    this.code,
    this.retryAfter,
    this.retryable = false,
  });

  final S3Failure failure;
  final String message;
  final int? statusCode;
  final String? code;
  final Duration? retryAfter;
  final bool retryable;

  @override
  String toString() => 'S3Exception(' + failure.name + ': ' + message + ')';
}

class S3ObjectInfo {
  const S3ObjectInfo({
    required this.key,
    required this.size,
    required this.lastModified,
    this.etag,
  });

  final String key;
  final int size;
  final DateTime? lastModified;
  final String? etag;
}

class S3ListPage {
  const S3ListPage({
    required this.objects,
    this.nextContinuationToken,
    this.isTruncated = false,
  });

  final List<S3ObjectInfo> objects;
  final String? nextContinuationToken;
  final bool isTruncated;
}

class S3ConnectionReport {
  const S3ConnectionReport({
    required this.canRead,
    required this.canWrite,
    required this.canDelete,
    this.message = '',
  });

  final bool canRead;
  final bool canWrite;
  final bool canDelete;
  final String message;

  bool get usable => canRead && canWrite;
}

/// Minimal S3 client: ListObjectsV2, PutObject, HeadObject, GetObject and
/// DeleteObject. Signing is delegated to aws_signature_v4; the signed URI,
/// query, headers and body bytes are sent unchanged.
class S3ObjectStore {
  S3ObjectStore({
    required this.config,
    required this.credentials,
    Dio? dio,
    AWSSigV4Signer? signer,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: Duration(seconds: config.timeoutSeconds),
               sendTimeout: Duration(seconds: config.timeoutSeconds),
               responseType: ResponseType.bytes,
               followRedirects: false,
               validateStatus: (_) => true,
             ),
           ),
       _signer =
           signer ??
           AWSSigV4Signer(
             credentialsProvider: AWSCredentialsProvider(
               AWSCredentials(
                 credentials.accessKeyId,
                 credentials.secretAccessKey,
                 credentials.sessionToken,
               ),
             ),
           );

  final S3BackupConfig config;
  final S3Credentials credentials;
  final Dio _dio;
  final AWSSigV4Signer _signer;

  static const int maxListBytes = 2 * 1024 * 1024;
  static const int maxObjectBytes = 64 * 1024 * 1024;

  String get _prefix => config.normalizedPrefix;

  String keyForSnapshot({
    required String backupSetId,
    required String deviceId,
    required String snapshotId,
    required DateTime createdAt,
  }) {
    final stamp = createdAt.toUtc().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '',
    );
    return _prefix +
        '/v1/' +
        backupSetId +
        '/' +
        deviceId +
        '/' +
        stamp +
        '-' +
        snapshotId +
        '.ppbackup';
  }

  Uri _uri(String key, {Map<String, String>? query}) {
    final endpoint = Uri.parse(config.endpoint.trim());
    final pathStyle = config.addressing == S3AddressingMode.pathStyle;
    final host = pathStyle
        ? endpoint.host
        : config.bucket + '.' + endpoint.host;
    final segments = <String>[
      if (pathStyle) config.bucket,
      ...key.split('/').where((s) => s.isNotEmpty),
    ];
    return Uri(
      scheme: endpoint.scheme,
      host: host,
      port: endpoint.hasPort ? endpoint.port : null,
      pathSegments: segments,
      queryParameters: query,
    );
  }

  Future<S3ListPage> listObjects({
    String? prefix,
    String? continuationToken,
    int maxKeys = 1000,
  }) async {
    final query = <String, String>{
      'list-type': '2',
      'max-keys': maxKeys.clamp(1, 1000).toString(),
      'encoding-type': 'url',
      'prefix': prefix ?? (_prefix + '/'),
      if (continuationToken != null) 'continuation-token': continuationToken,
    };
    final bytes = await _send(
      method: 'GET',
      key: '',
      query: query,
      maxResponseBytes: maxListBytes,
    );
    return _parseList(bytes);
  }

  Future<List<S3ObjectInfo>> listAll({
    String? prefix,
    int maxObjects = 10000,
  }) async {
    final result = <S3ObjectInfo>[];
    String? token;
    for (var page = 0; page < 20; page++) {
      final current = await listObjects(
        prefix: prefix,
        continuationToken: token,
      );
      result.addAll(current.objects);
      if (result.length >= maxObjects) break;
      token = current.nextContinuationToken;
      if (!current.isTruncated || token == null) break;
    }
    return result;
  }

  Future<HeadResult?> headObject(String key) async {
    try {
      final response = await _sendRaw(
        method: 'HEAD',
        key: key,
        maxResponseBytes: 0,
      );
      if (response.statusCode == 404) return null;
      return HeadResult(
        size:
            int.tryParse(
              response.headers.value('content-length') ?? '',
            ) ??
            0,
        etag: response.headers.value('etag'),
        metadata: {
          for (final name in const ['x-amz-meta-sha256', 'x-amz-meta-snapshot'])
            if (response.headers.value(name) case final value?) name: value,
        },
      );
    } on S3Exception catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> putObject({
    required String key,
    required Uint8List bytes,
    String? contentType,
    String? ifNoneMatch,
    Map<String, String> metadata = const {},
  }) async {
    final response = await _sendRaw(
      method: 'PUT',
      key: key,
      body: bytes,
      headers: {
        'content-type': contentType ?? 'application/octet-stream',
        if (ifNoneMatch != null) 'if-none-match': ifNoneMatch,
        for (final entry in metadata.entries)
          'x-amz-meta-' + entry.key: entry.value,
      },
      maxResponseBytes: 64 * 1024,
    );
    if (response.statusCode == 412 || response.statusCode == 409) {
      throw S3Exception(
        S3Failure.preconditionFailed,
        '对象已存在，未覆盖',
        statusCode: response.statusCode,
      );
    }
  }

  Future<Uint8List> getObject(
    String key, {
    int maxBytes = maxObjectBytes,
  }) async {
    final response = await _sendRaw(
      method: 'GET',
      key: key,
      maxResponseBytes: maxBytes,
    );
    return response.data ?? Uint8List(0);
  }

  Future<void> deleteObject(String key) async {
    await _sendRaw(method: 'DELETE', key: key, maxResponseBytes: 16 * 1024);
  }

  /// Uploads a snapshot without overwriting an existing key. A lost response is
  /// resolved by reading the object back and comparing the ciphertext hash.
  Future<bool> uploadVerified({
    required String key,
    required Uint8List bytes,
    required String sha256Hex,
    Map<String, String> metadata = const {},
  }) async {
    try {
      await putObject(
        key: key,
        bytes: bytes,
        ifNoneMatch: '*',
        metadata: {...metadata, 'sha256': sha256Hex},
      );
    } on S3Exception catch (e) {
      if (e.failure != S3Failure.preconditionFailed &&
          e.failure != S3Failure.conflict) {
        rethrow;
      }
      final existing = await getObject(key);
      if (sha256.convert(existing).toString() == sha256Hex) return true;
      throw const S3Exception(
        S3Failure.conflict,
        '同名列已存在且内容不同，未覆盖',
      );
    }
    final readBack = await getObject(key);
    if (sha256.convert(readBack).toString() != sha256Hex) {
      throw const S3Exception(
        S3Failure.invalidResponse,
        '回读校验失败',
      );
    }
    return true;
  }

  Future<S3ConnectionReport> connectionTest() async {
    var canRead = false;
    var canWrite = false;
    var canDelete = false;
    try {
      await listObjects(prefix: _prefix + '/', maxKeys: 1);
      canRead = true;
    } on S3Exception catch (e) {
      if (e.failure != S3Failure.accessDenied && e.failure != S3Failure.auth) {
        rethrow;
      }
    }
    final random = math.Random.secure();
    final probeKey =
        _prefix +
        '/_probe/' +
        DateTime.now().toUtc().millisecondsSinceEpoch.toString() +
        '-' +
        random.nextInt(1 << 32).toRadixString(16) +
        '.bin';
    final payload = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    try {
      await putObject(key: probeKey, bytes: payload);
      canWrite = true;
      final read = await getObject(probeKey, maxBytes: 1024);
      if (sha256.convert(read).toString() !=
          sha256.convert(payload).toString()) {
        throw const S3Exception(
          S3Failure.invalidResponse,
          '探测对象回读内容不一致',
        );
      }
    } finally {
      try {
        await deleteObject(probeKey);
        canDelete = true;
      } on S3Exception catch (e) {
        if (e.failure != S3Failure.accessDenied) rethrow;
      }
    }
    return S3ConnectionReport(
      canRead: canRead,
      canWrite: canWrite,
      canDelete: canDelete,
      message: canDelete ? '' : '当前凭据没有删除权限；自动清理已禁用',
    );
  }

  Future<Uint8List> _send({
    required String method,
    required String key,
    Map<String, String>? query,
    List<int>? body,
    Map<String, String> headers = const {},
    required int maxResponseBytes,
  }) async {
    final response = await _sendRaw(
      method: method,
      key: key,
      query: query,
      body: body,
      headers: headers,
      maxResponseBytes: maxResponseBytes,
    );
    return response.data ?? Uint8List(0);
  }

  Future<_S3Response> _sendRaw({
    required String method,
    required String key,
    Map<String, String>? query,
    List<int>? body,
    Map<String, String> headers = const {},
    required int maxResponseBytes,
  }) async {
    final uri = _uri(key, query: query);
    final request = AWSHttpRequest(
      method: _method(method),
      uri: uri,
      headers: headers,
      body: body,
    );
    final AWSSignedRequest signed;
    try {
      signed = await _signer.sign(
        request,
        credentialScope: AWSCredentialScope(
          region: config.region,
          service: AWSService.s3,
        ),
        serviceConfiguration: S3ServiceConfiguration(),
      );
    } on Object catch (_) {
      throw const S3Exception(S3Failure.signature, '请求签名失败');
    }

    final Response<List<int>> response;
    try {
      response = await _dio.requestUri<List<int>>(
        signed.uri,
        data: body,
        options: Options(
          method: method,
          headers: signed.headers,
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw _mapDio(e);
    }
    final status = response.statusCode ?? 0;
    final data = response.data;
    if (status >= 200 && status < 300) {
      if (maxResponseBytes > 0 &&
          data != null &&
          data.length > maxResponseBytes) {
        throw const S3Exception(
          S3Failure.invalidResponse,
          '服务响应超过上限',
        );
      }
      return _S3Response(
        statusCode: status,
        headers: response.headers,
        data: data == null ? null : Uint8List.fromList(data),
      );
    }
    throw _mapStatus(status, data, response.headers);
  }

  static AWSHttpMethod _method(String method) {
    switch (method) {
      case 'GET':
        return AWSHttpMethod.get;
      case 'PUT':
        return AWSHttpMethod.put;
      case 'HEAD':
        return AWSHttpMethod.head;
      case 'DELETE':
        return AWSHttpMethod.delete;
      default:
        throw const S3Exception(S3Failure.invalidResponse, '不支持的方法');
    }
  }

  S3ListPage _parseList(Uint8List bytes) {
    XmlDocument document;
    try {
      document = XmlDocument.parse(utf8.decode(bytes));
    } on Object catch (_) {
      throw const S3Exception(
        S3Failure.invalidResponse,
        '列举结果不是有效 XML',
      );
    }
    bool boolValue(String name) => document.descendants
        .whereType<XmlElement>()
        .where((e) => e.localName == name)
        .any((e) => e.innerText.toLowerCase() == 'true');
    String? textValue(String name) {
      for (final element in document.descendants.whereType<XmlElement>()) {
        if (element.localName == name) return element.innerText;
      }
      return null;
    }

    final objects = <S3ObjectInfo>[];
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (element.localName != 'Contents') continue;
      String? key;
      var size = 0;
      DateTime? modified;
      String? etag;
      for (final child in element.children.whereType<XmlElement>()) {
        switch (child.localName) {
          case 'Key':
            key = Uri.decodeComponent(child.innerText);
          case 'Size':
            size = int.tryParse(child.innerText) ?? 0;
          case 'LastModified':
            modified = DateTime.tryParse(child.innerText);
          case 'ETag':
            etag = child.innerText;
        }
      }
      if (key != null && key.isNotEmpty) {
        objects.add(
          S3ObjectInfo(
            key: key,
            size: size,
            lastModified: modified,
            etag: etag,
          ),
        );
      }
    }
    return S3ListPage(
      objects: objects,
      nextContinuationToken: textValue('NextContinuationToken'),
      isTruncated: boolValue('IsTruncated'),
    );
  }

  S3Exception _mapStatus(
    int status,
    List<int>? body,
    Headers headers,
  ) {
    String? code;
    String? message;
    try {
      final raw = utf8.decode(body ?? const []);
      if (raw.isNotEmpty && raw.length < 65536) {
        final doc = XmlDocument.parse(raw);
        for (final element in doc.descendants.whereType<XmlElement>()) {
          if (element.localName == 'Code') code = element.innerText;
          if (element.localName == 'Message') message = element.innerText;
        }
      }
    } on Object catch (_) {
      // Not XML; fall through to the status mapping.
    }
    final retryAfterRaw = headers.value('retry-after');
    final retryAfter = retryAfterRaw == null
        ? null
        : Duration(seconds: int.tryParse(retryAfterRaw) ?? 0);
    if (status == 401 || status == 403) {
      final failure =
          code == 'SignatureDoesNotMatch' ||
              code == 'AuthorizationHeaderMalformed'
          ? S3Failure.signature
          : S3Failure.accessDenied;
      return S3Exception(
        failure,
        'S3 鉴权失败',
        statusCode: status,
        code: code,
      );
    }
    if (status == 400 && code == 'RequestTimeTooSkewed') {
      return S3Exception(
        S3Failure.clockSkew,
        '设备时钟偏差过大，请校准时间',
        statusCode: status,
        code: code,
      );
    }
    if (status == 301 ||
        status == 400 &&
            (code == 'PermanentRedirect' ||
                code == 'AuthorizationHeaderMalformed')) {
      return S3Exception(
        S3Failure.region,
        'Region 或 Endpoint 不匹配',
        statusCode: status,
        code: code,
      );
    }
    if (status == 404) {
      return S3Exception(
        S3Failure.notFound,
        '对象或 Bucket 不存在',
        statusCode: status,
        code: code,
      );
    }
    if (status == 412) {
      return S3Exception(
        S3Failure.preconditionFailed,
        '条件请求失败：对象已存在',
        statusCode: status,
        code: code,
      );
    }
    if (status == 409) {
      return S3Exception(
        S3Failure.conflict,
        '对象已存在且内容不同',
        statusCode: status,
        code: code,
      );
    }
    if (status == 429) {
      return S3Exception(
        S3Failure.rateLimited,
        '服务限流',
        statusCode: status,
        code: code,
        retryAfter: retryAfter,
        retryable: true,
      );
    }
    if (status >= 500) {
      return S3Exception(
        S3Failure.server,
        'S3 服务暂时不可用',
        statusCode: status,
        code: code,
        retryAfter: retryAfter,
        retryable: true,
      );
    }
    return S3Exception(
      S3Failure.invalidResponse,
      'S3 请求失败（HTTP ' + status.toString() + '）',
      statusCode: status,
      code: code ?? message,
    );
  }

  S3Exception _mapDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const S3Exception(
          S3Failure.timeout,
          '连接 S3 超时',
          retryable: true,
        );
      case DioExceptionType.badCertificate:
        return const S3Exception(S3Failure.tls, 'TLS 证书校验失败');
      case DioExceptionType.cancel:
        return const S3Exception(S3Failure.cancelled, '请求已取消');
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return const S3Exception(
          S3Failure.network,
          '无法连接 S3 服务',
          retryable: true,
        );
      case DioExceptionType.badResponse:
        return const S3Exception(
          S3Failure.invalidResponse,
          'S3 响应异常',
        );
      case DioExceptionType.transformTimeout:
        return const S3Exception(
          S3Failure.invalidResponse,
          'S3 响应处理超时',
        );
    }
  }
}

class HeadResult {
  const HeadResult({
    required this.size,
    this.etag,
    this.metadata = const {},
  });

  final int size;
  final String? etag;
  final Map<String, String> metadata;
}

class _S3Response {
  const _S3Response({
    required this.statusCode,
    required this.headers,
    this.data,
  });

  final int statusCode;
  final Headers headers;
  final Uint8List? data;
}
