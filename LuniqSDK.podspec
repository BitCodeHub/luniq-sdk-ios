Pod::Spec.new do |s|
  s.name             = 'LuniqSDK'
  s.version          = '1.0.3'
  s.summary          = 'AI-native product analytics SDK for iOS.'
  s.description      = 'Auto-capture, offline queue, in-app guides/banners/surveys, session replay, and Design Mode pairing. Swift-first with an Obj-C facade (LuniqObjC) for legacy callers.'
  s.homepage         = 'https://uselunaai.com'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Luniq.AI' => 'sdk@uselunaai.com' }
  s.source           = { :git => 'https://github.com/BitCodeHub/luniq-sdk-ios.git', :tag => '1.0.3' }
  s.ios.deployment_target = '13.0'
  s.swift_version = '5.9'

  s.source_files = 'Sources/LuniqSDK/**/*.swift'
  s.frameworks   = 'Foundation', 'UIKit'
end
