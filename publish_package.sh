#!/bin/bash

# 첫 번째 인수 값으로 버전 설정
VERSION=$1

# pubspec.lock 파일 삭제
rm -f pubspec.lock
# Flutter 프로젝트 초기화
flutter clean
# 필요한 패키지 가져오기
flutter pub get

# Flutter 모듈을 AAR 라이브러리로 빌드
# --no-debug --no-profile: 릴리즈 모드만 활성화
# --build-number=$VERSION: 빌드 번호를 제공된 버전으로 설정
# --obfuscate: 코드 난독화 활성화
# --split-debug-info=build/app/outputs/symbols: 디버그 정보를 분할하여 저장
flutter build aar \
	--no-debug --no-profile \
	--build-number=$VERSION \
	--obfuscate \
	--split-debug-info=build/app/outputs/symbols

# 릴리즈 파일의 경로를 찾아서 반복적으로 처리하는 반복문
find ./build/host/outputs/repo -name '*release*.pom' | while read -r POM_PATH; do
	# .aar 파일의 경로를 .pom 파일의 경로를 통해 찾음
	FILE="${POM_PATH%.pom}.aar"
	# POM 파일에서 groupId 값을 추출
	GROUP_ID=$(xmllint --xpath "//*[local-name()='project']/*[local-name()='groupId']/text()" "$POM_PATH")
	# POM 파일에서 artifactId 값을 추출
	ARTIFACT_ID=$(xmllint --xpath "//*[local-name()='project']/*[local-name()='artifactId']/text()" "$POM_PATH")
	# GitHub 패키지 관련 정보 설정
	OWNER="flutter-jihoon"
	REPOSITORY="flutter-module-app"

	# Maven을 사용하여 파일을 배포하는 명령 실행
	mvn --batch-mode deploy:deploy-file \
		-Dfile=${FILE} \
		-DgroupId=${GROUP_ID} \
		-DartifactId=${ARTIFACT_ID} \
		-Dversion=${VERSION} \
		-Dpackaging=aar \
		-DpomFile=${POM_PATH} \
		-DrepositoryId=github \
		-Durl=https://maven.pkg.github.com/${OWNER}/${REPOSITORY}
done