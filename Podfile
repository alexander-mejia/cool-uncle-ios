# Podfile for Cool Uncle
# Phase 3: Wake Word Integration - ONNX Runtime with CoreML EP

platform :ios, '26.0'
use_frameworks!

target 'Cool Uncle' do
  # ONNX Runtime with CoreML execution provider
  # Built with --use_coreml flag by default
  # This enables Apple Neural Engine acceleration
  pod 'onnxruntime-objc'
end

# Post-install hook for compatibility
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
    end
  end
end
