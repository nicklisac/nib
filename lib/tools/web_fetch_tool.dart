import 'dart:io';
import 'package:http/http.dart' as http;
import '../agent/tool.dart';
import 'html_to_markdown.dart';

/// Tool allowing the model to fetch and read content from a public web URL.
class WebFetchTool extends AgentTool {
  final http.Client _client;

  WebFetchTool({http.Client? client}) : _client = client ?? http.Client();

  @override
  String get name => 'web_fetch';

  @override
  bool get readOnly => true;

  @override
  String get description =>
      'Fetches the text content of a public web page at a given URL, converting HTML into clean Markdown. Blocks access to private and local network addresses.';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'url': {
        'type': 'string',
        'description': 'The HTTP or HTTPS URL to fetch.',
      },
    },
    'required': ['url'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final rawUrl = (arguments['url'] as String?)?.trim() ?? '';
    if (rawUrl.isEmpty) {
      return const ToolResult.text('Error: "url" parameter is required.');
    }

    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return ToolResult.text(
        'Error: Invalid URL "$rawUrl". Must be a valid absolute HTTP or HTTPS URL.',
      );
    }

    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return ToolResult.text(
        'Error: Unsupported URL scheme "${uri.scheme}". Only "http" and "https" are allowed.',
      );
    }

    // SSRF / Local address protection
    final host = uri.host.toLowerCase();
    if (_isBlockedHost(host)) {
      return ToolResult.text(
        'Error: Access to private or local network address "$host" is blocked.',
      );
    }

    try {
      final addresses = await InternetAddress.lookup(host);
      for (final addr in addresses) {
        if (_isBlockedAddress(addr)) {
          return ToolResult.text(
            'Error: Resolved address "${addr.address}" for host "$host" is in a blocked private or local range.',
          );
        }
      }
    } catch (e) {
      return ToolResult.text('Error: Unable to resolve hostname "$host": $e');
    }

    try {
      final response = await _client
          .get(
            uri,
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (compatible; NibAgent/1.0; +https://github.com/nicklisac/nib)',
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5',
            },
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode >= 400) {
        return ToolResult.text(
          'Error: HTTP ${response.statusCode} (${response.reasonPhrase}) fetching $rawUrl',
        );
      }

      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      final body = response.body;

      // If content is HTML or starts with <, convert to markdown
      String content;
      if (contentType.contains('html') || body.trimLeft().startsWith('<')) {
        content = HtmlToMarkdown.convert(body);
      } else {
        content = body.trim();
      }

      if (content.isEmpty) {
        return ToolResult.text(
          'Web page at $rawUrl returned no readable content.',
        );
      }

      const maxOutputChars = 20000;
      if (content.length > maxOutputChars) {
        final total = content.length;
        final truncated = content.substring(0, maxOutputChars);
        return ToolResult.text(
          '$truncated\n\n[Content truncated: showing $maxOutputChars of $total characters]',
        );
      }

      return ToolResult.text(content);
    } catch (e) {
      return ToolResult.text('Error fetching $rawUrl: $e');
    }
  }

  static bool _isBlockedHost(String host) {
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal')) {
      return true;
    }
    final parsed = InternetAddress.tryParse(host);
    if (parsed != null && _isBlockedAddress(parsed)) {
      return true;
    }
    return false;
  }

  static bool _isBlockedAddress(InternetAddress addr) {
    if (addr.isLoopback || addr.isLinkLocal) {
      return true;
    }

    // Check IPv4 private ranges (RFC 1918)
    if (addr.type == InternetAddressType.IPv4) {
      final raw = addr.rawAddress;
      // 10.0.0.0/8
      if (raw[0] == 10) return true;
      // 172.16.0.0/12
      if (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) return true;
      // 192.168.0.0/16
      if (raw[0] == 192 && raw[1] == 168) return true;
      // 127.0.0.0/8
      if (raw[0] == 127) return true;
      // 169.254.0.0/16 (Link Local)
      if (raw[0] == 169 && raw[1] == 254) return true;
      // 0.0.0.0
      if (raw[0] == 0) return true;
    }

    // Check IPv6 unique local addresses (fc00::/7) or site local
    if (addr.type == InternetAddressType.IPv6) {
      final raw = addr.rawAddress;
      // fc00::/7 (0xfc or 0xfd)
      if ((raw[0] & 0xfe) == 0xfc) return true;
    }

    return false;
  }
}
