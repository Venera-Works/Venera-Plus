Pod::Spec.new do |spec|
  spec.name = 'OpenListCore'
  spec.version = '0.1.0'
  spec.summary = 'VeneraPlus embedded OpenList core'
  spec.homepage = 'https://github.com/Venera-Works/Venera-Plus'
  spec.source = { :git => 'https://github.com/OpenListTeam/OpenList.git', :commit => '482464c2affc5eeba5d4a25bb272aeb352ec5918' }
  spec.license = { :type => 'AGPL-3.0-or-later', :file => 'Frameworks/LICENSE.OpenList.txt' }
  spec.author = { 'VeneraPlus' => 'noreply@example.invalid' }
  spec.platform = :ios, '13.0'
  spec.vendored_frameworks = 'Frameworks/Openlistcore.xcframework'
  spec.resources = 'Frameworks/LICENSE.OpenList.txt'
end
