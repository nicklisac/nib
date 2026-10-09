import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// A single search result from any web search provider.
class SearchResult {
  final String title;
  final String url;
  final String content;

  const SearchResult({
    required this.title,
    required this.url,
    required this.content,
  });

  String toMarkdown(int index) {
    final buf = StringBuffer();
    buf.writeln('## $index. $title');
    buf.writeln('**URL:** $url');
    if (content.isNotEmpty) {
      buf.writeln();
      buf.writeln(content.trim());
    }
    buf.writeln('---');
    return buf.toString();
  }
}

/// Abstract search provider interface.
abstract class SearchProvider {
  String get name;
  Future<List<SearchResult>> search(
    String query, {
    int numResults = 5,
    List<String>? includeDomains,
    List<String>? excludeDomains,
  });
}

/// Exa Search API provider (api.exa.ai).
class ExaSearchProvider implements SearchProvider {
  final String apiKey;
  final http.Client _client;

  ExaSearchProvider(this.apiKey, {http.Client? client})
    : _client = client ?? http.Client();

  @override
  String get name => 'Exa';

  @override
  Future<List<SearchResult>> search(
    String query, {
    int numResults = 5,
    List<String>? includeDomains,
    List<String>? excludeDomains,
  }) async {
    final body = <String, dynamic>{
      'query': query,
      'numResults': numResults,
      'type': 'auto',
      'contents': {
        'text': {'maxCharacters': 1200},
      },
      if (includeDomains != null && includeDomains.isNotEmpty)
        'includeDomains': includeDomains,
      if (excludeDomains != null && excludeDomains.isNotEmpty)
        'excludeDomains': excludeDomains,
    };

    final uri = Uri.parse('https://api.exa.ai/search');
    final response = await _client
        .post(
          uri,
          headers: {'Content-Type': 'application/json', 'x-api-key': apiKey},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 25));

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const FormatException(
        'EXA_API_KEY rejected: invalid or unauthorized API key.',
      );
    }
    if (response.statusCode == 429) {
      throw const FormatException(
        'Exa API rate limited (429). Please wait a moment and try again.',
      );
    }
    if (response.statusCode >= 400) {
      final msg = response.body.length > 300
          ? '${response.body.substring(0, 300)}...'
          : response.body;
      throw FormatException('Exa search failed (${response.statusCode}): $msg');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final rawResults = (data['results'] as List<dynamic>?) ?? [];

    return rawResults.map((r) {
      final map = r as Map<String, dynamic>;
      final title = (map['title'] as String?)?.trim() ?? 'Untitled';
      final url = (map['url'] as String?)?.trim() ?? '';
      final text = (map['text'] as String?)?.trim() ?? '';
      return SearchResult(title: title, url: url, content: text);
    }).toList();
  }
}

/// Tavily Search API provider (api.tavily.com).
class TavilySearchProvider implements SearchProvider {
  final String apiKey;
  final http.Client _client;

  TavilySearchProvider(this.apiKey, {http.Client? client})
    : _client = client ?? http.Client();

  @override
  String get name => 'Tavily';

  @override
  Future<List<SearchResult>> search(
    String query, {
    int numResults = 5,
    List<String>? includeDomains,
    List<String>? excludeDomains,
  }) async {
    final body = <String, dynamic>{
      'api_key': apiKey,
      'query': query,
      'max_results': numResults,
      'search_depth': 'basic',
      'include_answer': false,
      if (includeDomains != null && includeDomains.isNotEmpty)
        'include_domains': includeDomains,
      if (excludeDomains != null && excludeDomains.isNotEmpty)
        'exclude_domains': excludeDomains,
    };

    final uri = Uri.parse('https://api.tavily.com/search');
    final response = await _client
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 25));

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const FormatException(
        'TAVILY_API_KEY rejected: invalid or unauthorized API key.',
      );
    }
    if (response.statusCode == 429) {
      throw const FormatException(
        'Tavily API rate limited (429). Please wait a moment and try again.',
      );
    }
    if (response.statusCode >= 400) {
      final msg = response.body.length > 300
          ? '${response.body.substring(0, 300)}...'
          : response.body;
      throw FormatException(
        'Tavily search failed (${response.statusCode}): $msg',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final rawResults = (data['results'] as List<dynamic>?) ?? [];

    return rawResults.map((r) {
      final map = r as Map<String, dynamic>;
      final title = (map['title'] as String?)?.trim() ?? 'Untitled';
      final url = (map['url'] as String?)?.trim() ?? '';
      final content = (map['content'] as String?)?.trim() ?? '';
      return SearchResult(title: title, url: url, content: content);
    }).toList();
  }
}

/// Brave Search API provider (api.search.brave.com).
class BraveSearchProvider implements SearchProvider {
  final String apiKey;
  final http.Client _client;

  BraveSearchProvider(this.apiKey, {http.Client? client})
    : _client = client ?? http.Client();

  @override
  String get name => 'Brave';

  @override
  Future<List<SearchResult>> search(
    String query, {
    int numResults = 5,
    List<String>? includeDomains,
    List<String>? excludeDomains,
  }) async {
    final queryParams = <String, String>{
      'q': query,
      'count': numResults.toString(),
    };

    final uri = Uri.https(
      'api.search.brave.com',
      '/res/v1/web/search',
      queryParams,
    );
    final response = await _client
        .get(
          uri,
          headers: {
            'Accept': 'application/json',
            'X-Subscription-Token': apiKey,
          },
        )
        .timeout(const Duration(seconds: 25));

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const FormatException(
        'BRAVE_API_KEY rejected: invalid or unauthorized API key.',
      );
    }
    if (response.statusCode == 429) {
      throw const FormatException(
        'Brave Search rate limited (429). Please wait a moment and try again.',
      );
    }
    if (response.statusCode >= 400) {
      final msg = response.body.length > 300
          ? '${response.body.substring(0, 300)}...'
          : response.body;
      throw FormatException(
        'Brave search failed (${response.statusCode}): $msg',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final web = data['web'] as Map<String, dynamic>?;
    final rawResults = (web?['results'] as List<dynamic>?) ?? [];

    return rawResults.map((r) {
      final map = r as Map<String, dynamic>;
      final title = (map['title'] as String?)?.trim() ?? 'Untitled';
      final url = (map['url'] as String?)?.trim() ?? '';
      final desc = (map['description'] as String?)?.trim() ?? '';
      return SearchResult(title: title, url: url, content: desc);
    }).toList();
  }
}

/// Factory that resolves the active search provider from config or environment variables.
class SearchProviderResolver {
  static SearchProvider? resolve({
    String? configuredProvider,
    Map<String, String>? env,
    http.Client? client,
  }) {
    final environment = env ?? Platform.environment;
    final requested = configuredProvider?.trim().toLowerCase();

    if (requested == 'exa') {
      final key = environment['EXA_API_KEY'];
      return key != null && key.isNotEmpty
          ? ExaSearchProvider(key, client: client)
          : null;
    } else if (requested == 'tavily') {
      final key = environment['TAVILY_API_KEY'];
      return key != null && key.isNotEmpty
          ? TavilySearchProvider(key, client: client)
          : null;
    } else if (requested == 'brave') {
      final key = environment['BRAVE_API_KEY'];
      return key != null && key.isNotEmpty
          ? BraveSearchProvider(key, client: client)
          : null;
    }

    // Auto-detect based on available keys: Exa -> Tavily -> Brave
    final exaKey = environment['EXA_API_KEY'];
    if (exaKey != null && exaKey.isNotEmpty) {
      return ExaSearchProvider(exaKey, client: client);
    }

    final tavilyKey = environment['TAVILY_API_KEY'];
    if (tavilyKey != null && tavilyKey.isNotEmpty) {
      return TavilySearchProvider(tavilyKey, client: client);
    }

    final braveKey = environment['BRAVE_API_KEY'];
    if (braveKey != null && braveKey.isNotEmpty) {
      return BraveSearchProvider(braveKey, client: client);
    }

    return null;
  }
}
