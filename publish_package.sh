#!/bin/bash

# 첫 번째 인수 값으로 버전 설정
VERSION=$1

# 버전 인수가 제공되지 않았을 경우 오류 메시지 출력 및 종료
if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  exit 1
fi

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

# 루트 pom.xml 파일 생성 및 초기화
ROOT_POM="./build/host/outputs/repo/pom.xml"
cat <<EOF > $ROOT_POM
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <groupId>io.cashwalk</groupId>
    <artifactId>Module-Flutter</artifactId>
    <version>$VERSION</version>
    <packaging>pom</packaging>
    <dependencies>
EOF

# GitHub 패키지 관련 정보 설정
OWNER="flutter-jihoon"
REPOSITORY="flutter-module-app"

find ./build/host/outputs/repo -name '*release*.pom' | while read -r POM_PATH; do
	# POM 파일에서 값을 추출
	DEPENDENCY_FILE="${POM_PATH%.pom}.aar"
	DEPENDENCY_GROUP_ID=$(xmllint --xpath "//*[local-name()='project']/*[local-name()='groupId']/text()" "$POM_PATH")
	DEPENDENCY_ARTIFACT_ID=$(xmllint --xpath "//*[local-name()='project']/*[local-name()='artifactId']/text()" "$POM_PATH")
	DEPENDENCY_VERSION=$(xmllint --xpath "//*[local-name()='project']/*[local-name()='version']/text()" "$POM_PATH")

	cat <<EOF >> $ROOT_POM
        <dependency>
            <groupId>$DEPENDENCY_GROUP_ID</groupId>
            <artifactId>$DEPENDENCY_ARTIFACT_ID</artifactId>
            <version>$DEPENDENCY_VERSION</version>
        </dependency>
EOF
	# Maven을 사용하여 파일을 배포하는 명령 실행
	mvn --batch-mode deploy:deploy-file \
		-Dfile=${DEPENDENCY_FILE} \
		-DgroupId=${DEPENDENCY_GROUP_ID} \
		-DartifactId=${DEPENDENCY_ARTIFACT_ID} \
		-Dversion=${DEPENDENCY_VERSION} \
		-Dpackaging=aar \
		-DpomFile=${POM_PATH} \
		-DrepositoryId=github \
		-Durl=https://maven.pkg.github.com/${OWNER}/${REPOSITORY}
done

# 루트 pom.xml에 닫는 태그 추가
cat <<EOF >> $ROOT_POM
    </dependencies>
	<distributionManagement>
		<repository>
		<id>github</id>
		<name>GitHub Packages</name>
		<url>https://maven.pkg.github.com/${OWNER}/${REPOSITORY}</url>
		</repository>
	</distributionManagement>
</project>
EOF

# 루트 프로젝트에서 배포
cd ./build/host/outputs/repo/
mvn --batch-mode deploy
