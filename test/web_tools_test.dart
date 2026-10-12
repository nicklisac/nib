import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nib/tools/html_to_markdown.dart';
import 'package:nib/tools/search_provider.dart';
import 'package:nib/tools/web_fetch_tool.dart';
import 'package:nib/tools/web_search_tool.dart';
import 'package:test/test.dart';

void main() {
  group('HtmlToMarkdown Converter', () {
    test('strips ignored elements like script, style, nav, and footer', () {
      const html = '''
        <html>
          <head><title>Test Page</title><style>.hidden { display: none; }</style></head>
          <body>
            <nav><a href="/home">Home</a></nav>
            <script>alert("hello");</script>
            <h1>Main Title</h1>
            <p>Welcome to our article.</p>
            <footer>Copyright 2026</footer>
          </body>
        </html>
      ''';
      final md = HtmlToMarkdown.convert(html);
      expect(md, contains('# Main Title'));
      expect(md, contains('Welcome to our article.'));
      expect(md, isNot(contains('alert("hello")')));
      expect(md, isNot(contains('.hidden')));
      expect(md, isNot(contains('Copyright 2026')));
      expect(md, isNot(contains('Home')));
    });

    test('converts headings, links, and code blocks correctly', () {
      const html = '''
        <div>
          <h2>Section Title</h2>
          <p>Read the <a href="https://dart.dev">Dart Docs</a> for details.</p>
          <pre><code>void main() {\n  print("Hello");\n}</code></pre>
          <p>Inline <code>int x = 42;</code> code.</p>
          <ul>
            <li>First bullet</li>
            <li>Second bullet</li>
          </ul>
        </div>
      ''';
      final md = HtmlToMarkdown.convert(html);
      expect(md, contains('## Section Title'));
      expect(md, contains('[Dart Docs](https://dart.dev)'));
      expect(md, contains('```\nvoid main() {\n  print("Hello");\n}\n```'));
      expect(md, contains('`int x = 42;`'));
      expect(md, contains('• First bullet'));
      expect(md, contains('• Second bullet'));
    });
  });

  group('WebFetchTool SSRF & Fetch Guardrails', () {
    test('blocks localhost, loopback, and private LAN IP addresses', () async {
      final tool = WebFetchTool();

      final localhostRes = await tool.execute({'url': 'http://localhost:5000'});
      expect(localhostRes.content, contains('blocked'));

      final loopbackRes = await tool.execute({'url': 'http://127.0.0.1:8080'});
      expect(loopbackRes.content, contains('blocked'));

      final privateIpRes = await tool.execute({
        'url': 'http://192.168.1.100/status',
      });
      expect(privateIpRes.content, contains('blocked'));

      final internalRes = await tool.execute({'url': 'http://app.internal'});
      expect(internalRes.content, contains('blocked'));
    });

    test('rejects non-http and invalid schemes', () async {
      final tool = WebFetchTool();
      final ftpRes = await tool.execute({'url': 'ftp://ftp.example.com'});
      expect(ftpRes.content, contains('Unsupported URL scheme'));

      final fileRes = await tool.execute({'url': 'file:///etc/passwd'});
      expect(fileRes.content, contains('Unsupported URL scheme'));
    });

    test('fetches public page and converts to markdown', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          '<html><body><h1>Hello World</h1><p>Test paragraph</p></body></html>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      });

      final tool = WebFetchTool(client: mockClient);
      final result = await tool.execute({'url': 'https://example.com'});
      expect(result.content, contains('# Hello World'));
      expect(result.content, contains('Test paragraph'));
    });
  });

  group('SearchProviderResolver & Providers', () {
    test('resolves Exa provider when EXA_API_KEY is in env', () {
      final provider = SearchProviderResolver.resolve(
        env: {'EXA_API_KEY': 'test-exa-key'},
      );
      expect(provider, isNotNull);
      expect(provider, isA<ExaSearchProvider>());
      expect(provider!.name, equals('Exa'));
    });

    test('resolves Tavily provider when TAVILY_API_KEY is in env', () {
      final provider = SearchProviderResolver.resolve(
        env: {'TAVILY_API_KEY': 'test-tavily-key'},
      );
      expect(provider, isNotNull);
      expect(provider, isA<TavilySearchProvider>());
      expect(provider!.name, equals('Tavily'));
    });

    test('resolves Brave provider when BRAVE_API_KEY is in env', () {
      final provider = SearchProviderResolver.resolve(
        env: {'BRAVE_API_KEY': 'test-brave-key'},
      );
      expect(provider, isNotNull);
      expect(provider, isA<BraveSearchProvider>());
      expect(provider!.name, equals('Brave'));
    });

    test('prefers configured provider if specified and key is present', () {
      final provider = SearchProviderResolver.resolve(
        configuredProvider: 'brave',
        env: {'EXA_API_KEY': 'exa-key', 'BRAVE_API_KEY': 'brave-key'},
      );
      expect(provider, isNotNull);
      expect(provider, isA<BraveSearchProvider>());
    });

    test('returns null if no keys are present', () {
      final provider = SearchProviderResolver.resolve(env: {});
      expect(provider, isNull);
    });
  });

  group('WebSearchTool execution', () {
    test('returns helpful error when no API key is configured', () async {
      final tool = WebSearchTool(env: {});
      final result = await tool.execute({'query': 'test'});
      expect(result.content, contains('Error: No web search API key found'));
    });

    test('formats search results as markdown', () async {
      final mockClient = MockClient((request) async {
        final resp = {
          'results': [
            {
              'title': 'Dart Programming Language',
              'url': 'https://dart.dev',
              'text': 'Dart is an approachable, portable language.',
            },
            {
              'title': 'Pub Package Manager',
              'url': 'https://pub.dev',
              'text': 'The official package repository for Dart and Flutter.',
            },
          ],
        };
        return http.Response(jsonEncode(resp), 200);
      });

      final exa = ExaSearchProvider('mock-key', client: mockClient);
      final tool = WebSearchTool(providerOverride: exa);

      final result = await tool.execute({'query': 'dart programming'});
      expect(
        result.content,
        contains('# Web Search Results: "dart programming" (Exa)'),
      );
      expect(result.content, contains('## 1. Dart Programming Language'));
      expect(result.content, contains('**URL:** https://dart.dev'));
      expect(
        result.content,
        contains('Dart is an approachable, portable language.'),
      );
      expect(result.content, contains('## 2. Pub Package Manager'));
    });
  });
}
