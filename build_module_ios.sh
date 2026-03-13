#!/usr/bin/env bash
set -euo pipefail

: "${LOCAL_ENGINE_SRC_PATH:?LOCAL_ENGINE_SRC_PATH 환경변수가 필요합니다}"
: "${LOCAL_ENGINE:?LOCAL_ENGINE 환경변수가 필요합니다}"
: "${LOCAL_ENGINE_HOST:?LOCAL_ENGINE_HOST 환경변수가 필요합니다}"

LOCAL_ENGINE_FLAGS=(
  "--local-engine-src-path=${LOCAL_ENGINE_SRC_PATH}"
  "--local-engine=${LOCAL_ENGINE}"
  "--local-engine-host=${LOCAL_ENGINE_HOST}"
)

DIST_DIR="./dist/ios/FlutterModule"

flutter clean
flutter pub get

PODFILE_PATH=$(find ./.ios -name 'Podfile')
sed -i '' "1s/.*/platform :ios, '13.0'/" $PODFILE_PATH
sed -i '' '36,40d' $PODFILE_PATH
echo "post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
      config.build_settings['PODS_XCFRAMEWORKS_BUILD_DIR'] = '\$(PODS_CONFIGURATION_BUILD_DIR)'
      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [
        '\$(inherited)',
        'PERMISSION_PHOTOS=1',
        'PERMISSION_CAMERA=1',
        'PERMISSION_NOTIFICATIONS=1',
        'PERMISSION_CONTACTS=1',
      ]
    end
  end
end" >> $PODFILE_PATH

flutter build ios-framework \
  "${LOCAL_ENGINE_FLAGS[@]}" \
  --no-pub \
  --no-debug \
  --no-profile \
  --xcframework \
  --output="$DIST_DIR"
