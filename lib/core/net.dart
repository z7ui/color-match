import 'dart:convert';
import 'dart:io';

/// 极简 HTTP GET：更新/公告这种非关键请求，失败一律返回 null。
Future<Map<String, dynamic>?> fetchJson(String url,
    {Duration timeout = const Duration(seconds: 8)}) async {
  final HttpClient client = HttpClient()..connectionTimeout = timeout;
  try {
    final HttpClientRequest request = await client.getUrl(Uri.parse(url));
    final HttpClientResponse response =
        await request.close().timeout(timeout);
    if (response.statusCode != 200) return null;
    final String body = await response.transform(utf8.decoder).join();
    final Object? decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
