import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// Converts raw HTML documents or fragments into clean, high-signal Markdown.
///
/// Strips noise tags (scripts, styles, headers, footers, navs, ads, iframes)
/// while preserving headings, links, code blocks, bullet points, and paragraphs.
class HtmlToMarkdown {
  static const Set<String> _ignoredTags = {
    'script',
    'style',
    'noscript',
    'svg',
    'head',
    'nav',
    'footer',
    'header',
    'aside',
    'form',
    'iframe',
    'template',
    'button',
    'select',
    'input',
    'textarea',
  };

  /// Parses [html] and produces readable Markdown text.
  static String convert(String html) {
    if (html.trim().isEmpty) return '';

    final document = html_parser.parse(html);

    // Remove ignored elements from the DOM tree before extracting text
    for (final tag in _ignoredTags) {
      final elements = document.getElementsByTagName(tag);
      for (final el in elements) {
        el.remove();
      }
    }

    final body = document.body ?? document.documentElement;
    if (body == null) return '';

    final buffer = StringBuffer();
    _walk(body, buffer);

    final raw = buffer.toString();

    // Normalize spacing: collapse 3+ consecutive newlines to 2, trim lines
    return raw
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .split('\n')
        .map((l) => l.trimRight())
        .join('\n')
        .trim();
  }

  static void _walk(dom.Node node, StringBuffer out) {
    if (node is dom.Text) {
      final text = node.text.replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ');
      out.write(text);
      return;
    }

    if (node is! dom.Element) return;

    final tag = node.localName?.toLowerCase() ?? '';

    switch (tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final level = int.tryParse(tag.substring(1)) ?? 1;
        out.write('\n\n${'#' * level} ');
        _walkChildren(node, out);
        out.write('\n\n');
        break;

      case 'p':
        out.write('\n\n');
        _walkChildren(node, out);
        out.write('\n\n');
        break;

      case 'br':
        out.write('\n');
        break;

      case 'hr':
        out.write('\n\n---\n\n');
        break;

      case 'blockquote':
        out.write('\n\n> ');
        _walkChildren(node, out);
        out.write('\n\n');
        break;

      case 'pre':
        out.write('\n\n```\n');
        out.write(node.text.trim());
        out.write('\n```\n\n');
        break;

      case 'code':
        if (node.parent?.localName?.toLowerCase() == 'pre') {
          _walkChildren(node, out);
        } else {
          out.write('`');
          _walkChildren(node, out);
          out.write('`');
        }
        break;

      case 'a':
        final href = node.attributes['href']?.trim() ?? '';
        final textBuffer = StringBuffer();
        _walkChildren(node, textBuffer);
        final linkText = textBuffer.toString().trim();
        if (href.isNotEmpty &&
            !href.startsWith('javascript:') &&
            linkText.isNotEmpty) {
          out.write('[$linkText]($href)');
        } else if (linkText.isNotEmpty) {
          out.write(linkText);
        }
        break;

      case 'ul':
      case 'ol':
        out.write('\n');
        _walkChildren(node, out);
        out.write('\n');
        break;

      case 'li':
        out.write('\n• ');
        _walkChildren(node, out);
        break;

      case 'strong':
      case 'b':
        out.write('**');
        _walkChildren(node, out);
        out.write('**');
        break;

      case 'em':
      case 'i':
        out.write('*');
        _walkChildren(node, out);
        out.write('*');
        break;

      case 'table':
        out.write('\n\n');
        _walkChildren(node, out);
        out.write('\n\n');
        break;

      case 'tr':
        out.write('\n');
        _walkChildren(node, out);
        break;

      case 'th':
      case 'td':
        out.write(' | ');
        _walkChildren(node, out);
        break;

      default:
        _walkChildren(node, out);
        break;
    }
  }

  static void _walkChildren(dom.Element element, StringBuffer out) {
    for (final child in element.nodes) {
      _walk(child, out);
    }
  }
}
