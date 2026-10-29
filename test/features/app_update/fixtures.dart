Map<String, Object?> releaseJson(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  List<Map<String, Object>> assets = const [],
}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/Venera-Works/Venera-Plus/releases/tag/$tag',
  'body': '## $tag\n\n- **New feature**',
  'draft': draft,
  'prerelease': prerelease,
  'assets': assets,
};

Map<String, Object> assetJson(String suffix, {String state = 'uploaded'}) => {
  'name': 'VeneraPlus-3.3.0-$suffix',
  'browser_download_url': 'https://example.com/$suffix',
  'size': 100,
  'state': state,
  'digest': 'sha256:ABCDEF',
};
