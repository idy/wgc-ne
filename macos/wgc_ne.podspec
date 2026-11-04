Pod::Spec.new do |s|
  s.name = 'wgc_ne'
  s.version = '0.1.0'
  s.summary = 'WGC Apple Network Extension control for Flutter.'
  s.description = 'Shared Keychain configuration and owned VPN profile lifecycle for WGC tunnels.'
  s.homepage = 'https://github.com/idy/wgc-ne'
  s.license = { :type => 'GPL-3.0-or-later' }
  s.author = { 'WGC NE contributors' => 'https://github.com/idy/wgc-ne' }
  s.source = { :git => 'https://github.com/idy/wgc-ne.git', :tag => 'v' + s.version.to_s }
  s.source_files = 'Classes/WGCNE/*.swift'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.0'
  s.swift_version = '5.9'
  s.frameworks = 'NetworkExtension', 'Security'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
