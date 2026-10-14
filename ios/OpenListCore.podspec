Pod::Spec.new do |spec|
  spec.name = 'OpenListCore'
  spec.version = '0.1.0'
  spec.summary = 'VeneraPlus embedded OpenList core'
  spec.homepage = 'https://github.com/Venera-Works/Venera-Plus'
  spec.source = { :path => '.' }
  spec.license = { :type => 'AGPL-3.0-or-later', :file => 'Frameworks/LICENSE.OpenList' }
  spec.author = { 'VeneraPlus' => 'noreply@example.invalid' }
  spec.platform = :ios, '13.0'
  spec.vendored_frameworks = 'Frameworks/Openlistcore.xcframework'
  spec.resources = 'Frameworks/LICENSE.OpenList'
end
