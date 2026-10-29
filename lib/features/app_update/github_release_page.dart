import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'app_release.dart';

const githubReleaseBase =
    'https://github.com/Venera-Works/Venera-Plus/releases';

AppRelease? parseGitHubReleasePage(
  String source, {
  required bool includePrerelease,
}) {
  final document = html.parse(source);
  final sections = document.querySelectorAll('section[data-release-anchor]');
  final releases = <Map<String, Object?>>[];
  for (final section in sections.isEmpty ? [document.body!] : sections) {
    final fragment = section.querySelector(
      'include-fragment[src*="/releases/expanded_assets/"]',
    );
    if (fragment == null) continue;
    final assetsUrl = Uri.parse(fragment.attributes['src']!);
    final tag = assetsUrl.pathSegments.last;
    final pageUrl = '$githubReleaseBase/tag/${Uri.encodeComponent(tag)}';
    final labels = section
        .querySelectorAll('.Label')
        .map((label) => label.text.trim());
    final body = section.querySelector('.markdown-body');
    releases.add({
      'tag_name': tag,
      'html_url': pageUrl,
      'draft': labels.contains('Draft'),
      'prerelease': labels.contains('Pre-release'),
      'body': body == null ? '' : _markdown(body, Uri.parse(pageUrl)).trim(),
    });
  }
  if (releases.isEmpty) {
    throw const FormatException('No release information found on GitHub');
  }
  return selectAppRelease(releases, includePrerelease: includePrerelease);
}

List<AppReleaseAsset> parseGitHubReleaseAssets(
  String source,
  AppRelease release,
) {
  final document = html.parseFragment(source);
  final prefix =
      '/Venera-Works/Venera-Plus/releases/download/${Uri.encodeComponent(release.tag)}/';
  return [
    for (final row in document.querySelectorAll('li'))
      for (final link in row.querySelectorAll('a[href]'))
        if (link.attributes['href']!.startsWith(prefix))
          AppReleaseAsset(
            name: Uri.parse(link.attributes['href']!).pathSegments.last,
            url: Uri.parse(
              githubReleaseBase,
            ).resolve(link.attributes['href']!).toString(),
            size: null,
            sha256: row
                .querySelector('clipboard-copy[value^="sha256:"]')
                ?.attributes['value']
                ?.substring(7)
                .toLowerCase(),
          ),
  ];
}

String _markdown(Node node, Uri baseUrl) {
  if (node is Text) return node.data.replaceAll(RegExp(r'\s+'), ' ');
  if (node is! Element) return '';
  final text = node.nodes.map((child) => _markdown(child, baseUrl)).join();
  return switch (node.localName) {
    'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6' =>
      '\n\n${'#' * int.parse(node.localName!.substring(1))} ${text.trim()}\n\n',
    'p' || 'div' => '\n\n${text.trim()}\n\n',
    'ul' || 'ol' => '\n$text\n',
    'li' => '\n- ${text.trim().replaceAll('\n', '\n  ')}\n',
    'strong' || 'b' => '**${text.trim()}**',
    'em' || 'i' => '*${text.trim()}*',
    'del' || 's' => '~~${text.trim()}~~',
    'br' => '  \n',
    'pre' => '\n\n```\n${node.text.trim()}\n```\n\n',
    'code' => '`${node.text}`',
    'a' when node.attributes['href'] != null =>
      '[$text](${baseUrl.resolve(node.attributes['href']!)})',
    'img' when node.attributes['src'] != null =>
      '![${node.attributes['alt'] ?? ''}](${baseUrl.resolve(node.attributes['src']!)})',
    _ => text,
  };
}
