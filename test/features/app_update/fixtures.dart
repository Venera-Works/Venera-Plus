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

String releasePageHtml(
  String tag, {
  bool prerelease = false,
  bool section = true,
}) =>
    '''
${section ? '<section data-release-anchor="release-$tag">' : '<main>'}
  ${prerelease ? '<span class="Label">Pre-release</span>' : '<span class="Label">Latest</span>'}
  <div class="markdown-body">
    <h2>Important changes</h2>
    <p><strong>Read before updating</strong></p>
    <ul><li>First change</li><li><a href="/Venera-Works/Venera-Plus/issues/1">Details</a></li></ul>
    <pre><code>first line
  second line &lt;code&gt;</code></pre>
  </div>
  <include-fragment src="https://github.com/Venera-Works/Venera-Plus/releases/expanded_assets/$tag"></include-fragment>
${section ? '</section>' : '</main>'}
''';

String releaseAssetsHtml(String tag, String digest) =>
    '''
<ul>
  <li class="Box-row">
    <a href="/Venera-Works/Venera-Plus/releases/download/$tag/VeneraPlus-${tag.substring(1)}-android-arm64-v8a.apk">APK</a>
    <clipboard-copy value="sha256:$digest"></clipboard-copy>
    <span>87.4 MB</span>
  </li>
  <li><a href="/Venera-Works/Venera-Plus/archive/refs/tags/$tag.zip">Source code</a></li>
</ul>
''';
