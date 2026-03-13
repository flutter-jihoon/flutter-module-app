#!/usr/bin/env bash
set -euo pipefail

: "${LOCAL_ENGINE_SRC_PATH:?}"
: "${LOCAL_ENGINE:?}"
: "${LOCAL_ENGINE_HOST:?}"

LOCAL_ENGINE_FLAGS=(
  "--local-engine-src-path=${LOCAL_ENGINE_SRC_PATH}"
  "--local-engine=${LOCAL_ENGINE}"
  "--local-engine-host=${LOCAL_ENGINE_HOST}"
)

VERSION=$1
if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  exit 1
fi

FLUTTER_PROJECT_DIR="$(pwd)"

clean_project() {
  flutter clean
  flutter pub get
}

update_android_manifest() {
  MANIFEST_FILE='.android/Flutter/src/main/AndroidManifest.xml'
  sed '/<\/application>/i\
        <meta-data \
            android:name="io.flutter.embedding.android.DisableMergedPlatformUIThread" \
            android:value="true" />\
' "$MANIFEST_FILE" >temp_manifest.xml && mv temp_manifest.xml "$MANIFEST_FILE"
  echo "Meta-data 'io.flutter.embedding.android.DisableMergedPlatformUIThread' added successfully."
}

update_gradle_jvm_args() {
  GRADLE_PROPERTIES_FILE=".android/gradle.properties"
  JVM_ARGS="-Xmx16G -XX:MaxMetaspaceSize=16G -XX:+HeapDumpOnOutOfMemoryError"
  if [ -f "$GRADLE_PROPERTIES_FILE" ]; then
    if grep -q "^org.gradle.jvmargs=" "$GRADLE_PROPERTIES_FILE"; then
      sed -i.bak -E "s|^(org.gradle.jvmargs=).*|\1$JVM_ARGS|" "$GRADLE_PROPERTIES_FILE"
    else
      echo "org.gradle.jvmargs=$JVM_ARGS" >>"$GRADLE_PROPERTIES_FILE"
    fi
  else
    echo "org.gradle.jvmargs=$JVM_ARGS" >"$GRADLE_PROPERTIES_FILE"
  fi
  echo "Updated org.gradle.jvmargs in $GRADLE_PROPERTIES_FILE"
}

build_flutter_aar() {
  flutter build aar \
    "${LOCAL_ENGINE_FLAGS[@]}" \
    --no-debug \
    --no-profile \
    --build-number=$VERSION \
    --obfuscate \
    --split-debug-info=build/app/outputs/symbols
}

create_root_pom() {
  ROOT_POM="./build/host/outputs/repo/pom.xml"
  cat <<EOF >$ROOT_POM
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <groupId>io.cashwalk</groupId>
    <artifactId>module-flutter</artifactId>
    <version>$VERSION</version>
    <packaging>pom</packaging>
    <dependencies>
EOF
}

OWNER="cashwalk"
REPOSITORY="Add-To-App-Flutter"

collect_dependencies() {
  find ./build/host/outputs/repo -name '*release*.pom' | while read -r POM_PATH; do
    DEPENDENCY_GROUP_ID=$(awk -F'[<>]' '/<groupId>/{print $3; exit}' "$POM_PATH")
    DEPENDENCY_ARTIFACT_ID=$(awk -F'[<>]' '/<artifactId>/{print $3; exit}' "$POM_PATH")
    DEPENDENCY_VERSION=$(awk -F'[<>]' '/<version>/{print $3; exit}' "$POM_PATH")

    local PACKAGING
    PACKAGING=$(awk -F'[<>]' '/<packaging>/{print $3; exit}' "$POM_PATH")
    if [ -z "$PACKAGING" ]; then
      if [ -f "${POM_PATH%.pom}.aar" ]; then
        PACKAGING="aar"
      elif [ -f "${POM_PATH%.pom}.jar" ]; then
        PACKAGING="jar"
      else
        PACKAGING="aar"  # fallback
      fi
    fi

    cat <<EOF >>$ROOT_POM
        <dependency>
            <groupId>$DEPENDENCY_GROUP_ID</groupId>
            <artifactId>$DEPENDENCY_ARTIFACT_ID</artifactId>
            <version>$DEPENDENCY_VERSION</version>
            <type>$PACKAGING</type>
        </dependency>
EOF
  done
}

deploy_single() {
  local POM_PATH="$1"
  local DEPENDENCY_GROUP_ID
  local DEPENDENCY_ARTIFACT_ID
  local DEPENDENCY_VERSION
  local DEPENDENCY_FILE
  local PACKAGING

  DEPENDENCY_GROUP_ID=$(awk -F'[<>]' '/<groupId>/{print $3; exit}' "$POM_PATH")
  DEPENDENCY_ARTIFACT_ID=$(awk -F'[<>]' '/<artifactId>/{print $3; exit}' "$POM_PATH")
  DEPENDENCY_VERSION=$(awk -F'[<>]' '/<version>/{print $3; exit}' "$POM_PATH")

  PACKAGING=$(awk -F'[<>]' '/<packaging>/{print $3; exit}' "$POM_PATH")
  if [ -z "$PACKAGING" ] || [ "$PACKAGING" = "pom" ]; then
    if [ -f "${POM_PATH%.pom}.aar" ]; then
      PACKAGING="aar"
      DEPENDENCY_FILE="${POM_PATH%.pom}.aar"
    elif [ -f "${POM_PATH%.pom}.jar" ]; then
      PACKAGING="jar"
      DEPENDENCY_FILE="${POM_PATH%.pom}.jar"
    else
      echo "WARNING: No artifact file found for $POM_PATH, skipping."
      return 0
    fi
  else
    DEPENDENCY_FILE="${POM_PATH%.pom}.${PACKAGING}"
    if [ ! -f "$DEPENDENCY_FILE" ]; then
      echo "WARNING: Expected $PACKAGING artifact not found at $DEPENDENCY_FILE, skipping."
      return 0
    fi
  fi

  echo "Deploying [$PACKAGING] ${DEPENDENCY_GROUP_ID}:${DEPENDENCY_ARTIFACT_ID}:${DEPENDENCY_VERSION}"

  mvn --batch-mode deploy:deploy-file \
    -Dfile="${DEPENDENCY_FILE}" \
    -DgroupId="${DEPENDENCY_GROUP_ID}" \
    -DartifactId="${DEPENDENCY_ARTIFACT_ID}" \
    -Dversion="${DEPENDENCY_VERSION}" \
    -Dpackaging="${PACKAGING}" \
    -DpomFile="${POM_PATH}" \
    -DrepositoryId=github \
    -Durl="https://maven.pkg.github.com/${OWNER}/${REPOSITORY}"
}
export -f deploy_single

deploy_dependencies() {
  export OWNER REPOSITORY
  find ./build/host/outputs/repo -name '*release*.pom' | xargs -P 6 -I {} bash -c 'deploy_single "$@"' _ {}
  if [ $? -ne 0 ]; then
    echo "ERROR: One or more deployments failed"
    exit 1
  fi
}

finalize_and_deploy_root_pom() {
  cat <<EOF >>$ROOT_POM
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

  cd ./build/host/outputs/repo/
  mvn --batch-mode deploy
  cd $FLUTTER_PROJECT_DIR
}

main() {
  clean_project
  update_gradle_jvm_args
  update_android_manifest
  build_flutter_aar
  create_root_pom
  collect_dependencies
  deploy_dependencies
  finalize_and_deploy_root_pom
}

main
