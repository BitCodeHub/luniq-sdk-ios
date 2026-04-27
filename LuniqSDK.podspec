Pod::Spec.new do |s|
  s.name             = 'LuniqSDK'
  s.version          = '1.0.0'
  s.summary          = 'AI-native product analytics SDK for iOS.'
  s.description      = 'Auto-capture, offline queue, in-app guides/banners/surveys, session replay, and Design Mode pairing — dual Swift/Obj-C API.'
  s.homepage         = 'https://uselunaai.com'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'Luniq.AI' => 'sdk@uselunaai.com' }
  s.source           = { :path => '.' }
  s.ios.deployment_target = '13.0'
  s.swift_version = '5.9'

  s.default_subspecs = 'Swift', 'ObjC'

  s.subspec 'Swift' do |sw|
    sw.source_files = 'Sources/LuniqSDK/**/*.swift'
    sw.frameworks = 'Foundation', 'UIKit'
  end

  s.subspec 'ObjC' do |oc|
    oc.source_files         = 'Sources/LuniqObjC/**/*.{h,m}'
    oc.public_header_files  = 'Sources/LuniqObjC/include/*.h'
    oc.dependency 'LuniqSDK/Swift'
    oc.frameworks = 'Foundation'
  end
end
