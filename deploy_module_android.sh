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

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  exit 1
fi

DIST_DIR="./dist/android"
OWNER="cashwalk"
REPOSITORY="Add-To-App-Flutter"

flutter clean
flutter pub get

MANIFEST_FILE='.android/Flutter/src/main/AndroidManifest.xml'
sed '/<\/application>/i\
    <meta-data \
        android:name="io.flutter.embedding.android.DisableMergedPlatformUIThread" \
        android:value="true" />\
' "$MANIFEST_FILE" > temp_manifest.xml && mv temp_manifest.xml "$MANIFEST_FILE"
echo "Meta-data 'io.flutter.embedding.android.DisableMergedPlatformUIThread' added successfully."

GRADLE_PROPERTIES_FILE=".android/gradle.properties"
JVM_ARGS="-Xmx16G -XX:MaxMetaspaceSize=16G -XX:+HeapDumpOnOutOfMemoryError"
if [ -f "$GRADLE_PROPERTIES_FILE" ]; then
  if grep -q "^org.gradle.jvmargs=" "$GRADLE_PROPERTIES_FILE"; then
    sed -i.bak -E "s|^(org.gradle.jvmargs=).*|\1$JVM_ARGS|" "$GRADLE_PROPERTIES_FILE"
  fi
fi

flutter build aar \
  "${LOCAL_ENGINE_FLAGS[@]}" \
  --no-debug \
  --no-profile \
  --output="$DIST_DIR" \
  --build-number="$VERSION" \
  --obfuscate \
  --split-debug-info=build/app/outputs/symbols

ROOT_POM="$DIST_DIR/host/outputs/repo/pom.xml"
cat > "$ROOT_POM" <<EOF
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

deploy_single() {
  local pom_path="$1"

  local group_id artifact_id version packaging artifact_file

  group_id=$(awk -F'[<>]' '/<groupId>/{print $3; exit}' "$pom_path")
  artifact_id=$(awk -F'[<>]' '/<artifactId>/{print $3; exit}' "$pom_path")
  version=$(awk -F'[<>]' '/<version>/{print $3; exit}' "$pom_path")

  packaging=$(awk -F'[<>]' '/<packaging>/{print $3; exit}' "$pom_path")
  if [ -z "$packaging" ] || [ "$packaging" = "pom" ]; then
    if [ -f "${pom_path%.pom}.aar" ]; then
      packaging="aar"
      artifact_file="${pom_path%.pom}.aar"
    elif [ -f "${pom_path%.pom}.jar" ]; then
      packaging="jar"
      artifact_file="${pom_path%.pom}.jar"
    else
      echo "WARNING: No artifact file found for $pom_path, skipping."
      return 0
    fi
  else
    artifact_file="${pom_path%.pom}.${packaging}"
    if [ ! -f "$artifact_file" ]; then
      echo "WARNING: Expected $packaging artifact not found at $artifact_file, skipping."
      return 0
    fi
  fi

  echo "Deploying [$packaging] ${group_id}:${artifact_id}:${version}"

  mvn --batch-mode deploy:deploy-file \
    -Dfile="${artifact_file}" \
    -DgroupId="${group_id}" \
    -DartifactId="${artifact_id}" \
    -Dversion="${version}" \
    -Dpackaging="${packaging}" \
    -DpomFile="${pom_path}" \
    -DrepositoryId=github \
    -Durl="https://maven.pkg.github.com/${OWNER}/${REPOSITORY}"
}

export -f deploy_single
export OWNER REPOSITORY

while IFS= read -r pom; do
  dep_group_id=$(awk -F'[<>]' '/<groupId>/{print $3; exit}' "$pom")
  dep_artifact_id=$(awk -F'[<>]' '/<artifactId>/{print $3; exit}' "$pom")
  dep_version=$(awk -F'[<>]' '/<version>/{print $3; exit}' "$pom")

  dep_packaging=$(awk -F'[<>]' '/<packaging>/{print $3; exit}' "$pom")
  if [ -z "$dep_packaging" ]; then
    if [ -f "${pom%.pom}.aar" ]; then
      dep_packaging="aar"
    elif [ -f "${pom%.pom}.jar" ]; then
      dep_packaging="jar"
    else
      dep_packaging="aar"
    fi
  fi

  cat >> "$ROOT_POM" <<EOF
      <dependency>
          <groupId>$dep_group_id</groupId>
          <artifactId>$dep_artifact_id</artifactId>
          <version>$dep_version</version>
          <type>$dep_packaging</type>
      </dependency>
EOF
done < <(find "$DIST_DIR/host/outputs/repo" -name '*release*.pom')

find "$DIST_DIR/host/outputs/repo" -name '*release*.pom' \
  | xargs -P 6 -I {} bash -c 'deploy_single "$@"' _ {}

cat >> "$ROOT_POM" <<EOF
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

(
  cd "$DIST_DIR/host/outputs/repo"
  mvn --batch-mode deploy
)

echo "Done. Version = $VERSION"
