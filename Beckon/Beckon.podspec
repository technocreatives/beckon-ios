Pod::Spec.new do |s|
  s.platform = :ios
  s.ios.deployment_target = '12.1'
  s.name = "Beckon"
  s.summary = "Bluetooth library"
  s.requires_arc = true

  s.version = "0.1.0"

  s.license = { :type => "MIT", :file => "LICENSE" }

  s.author = { "Me" => "my@email.address.com" }

  s.homepage = "http://nowebsiteyet.lol"

  s.source = { :git => "https://github.com/technocreatives/beckon-ios.git", :tag => "#{s.version}"}

  s.framework = "UIKit"
  s.dependency 'RxSwift'
  s.dependency 'RxFeedback'

  s.source_files = "Beckon/*.{swift,h}"

  #s.resources = "commons/**/*.{png,jpeg,jpg,xib,storyboard}"
end
