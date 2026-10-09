import '../agent/tool.dart';
import 'search_provider.dart';

/// Tool allowing the model to perform web searches via configurable providers (Exa, Tavily, Brave).
class WebSearchTool extends AgentTool {
  final String? configuredProvider;
  final SearchProvider? providerOverride;
  final Map<String, String>? env;

  WebSearchTool({this.configuredProvider, this.providerOverride, this.env});

  @override
  String get name => 'web_search';

  @override
  String get description =>
      'Performs a web search to find current information, documentation, news, or code examples. Returns titles, URLs, and text summaries.';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': 'The search query string.'},
      'num_results': {
        'type': 'integer',
        'description': 'Number of results to return (default: 5, max: 10).',
        'default': 5,
      },
      'include_domains': {
        'type': 'array',
        'items': {'type': 'string'},
        'description':
            'Optional list of domains to restrict results to (e.g. ["github.com", "dart.dev"]).',
      },
      'exclude_domains': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Optional list of domains to exclude from results.',
      },
    },
    'required': ['query'],
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final query = (arguments['query'] as String?)?.trim() ?? '';
    if (query.isEmpty) {
      return 'Error: "query" parameter is required and cannot be empty.';
    }

    final numResults = (arguments['num_results'] as num?)?.toInt() ?? 5;
    final clampedResults = numResults.clamp(1, 10);

    final includeDomains = (arguments['include_domains'] as List<dynamic>?)
        ?.map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final excludeDomains = (arguments['exclude_domains'] as List<dynamic>?)
        ?.map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final provider =
        providerOverride ??
        SearchProviderResolver.resolve(
          configuredProvider: configuredProvider,
          env: env,
        );

    if (provider == null) {
      return 'Error: No web search API key found.\n'
          'To use web search, set EXA_API_KEY (recommended), TAVILY_API_KEY, or BRAVE_API_KEY in your environment, '
          'or configure search_provider in ~/.nib/config.json.';
    }

    try {
      final results = await provider.search(
        query,
        numResults: clampedResults,
        includeDomains: includeDomains,
        excludeDomains: excludeDomains,
      );

      if (results.isEmpty) {
        return 'No results found for query: "$query"';
      }

      final buf = StringBuffer();
      buf.writeln('# Web Search Results: "$query" (${provider.name})\n');
      for (var i = 0; i < results.length; i++) {
        buf.write(results[i].toMarkdown(i + 1));
      }
      return buf.toString().trim();
    } catch (e) {
      return 'Error during web search: $e';
    }
  }
}
