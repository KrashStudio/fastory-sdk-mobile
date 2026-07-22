Pod::Spec.new do |s|
  s.name             = 'fastory_sdk'
  s.version          = '0.1.0'
  s.summary          = 'Fastory games hub SDK for Flutter.'
  s.description      = 'Opens a Fastory fanzone games hub and its games in native web views, from any Flutter app.'
  s.homepage         = 'https://fastory.io'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Fastory. All rights reserved.' }
  s.author           = { 'Fastory' => 'dev@fastory.io' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
