# Gatling load test image for Polaris autoscaling benchmarks
#
# Prerequisites:
#   Run locally first to cache everything:
#     ./gradlew compileGatlingScala --no-daemon
#   Then build:
#     docker build -t polaris-loadtest .
#
# Run:
#   docker run --rm \
#     -e POLARIS_CLIENT_ID=... \
#     -e POLARIS_CLIENT_SECRET=... \
#     -e SIMULATION=ReadUpdateTreeDataset \
#     -e CONFIG_FILE=pb-autoscaling-test.conf \
#     polaris-loadtest

FROM eclipse-temurin:21-jdk

WORKDIR /app

# Copy pre-built project (compile locally first with ./gradlew compileGatlingScala)
COPY . /app/

# Extract pre-packaged Gradle cache (wrapper distro + dependency caches)
# Create with: tar czf gradle-cache.tar.gz -C ~/.gradle wrapper caches
COPY gradle-cache.tar.gz /tmp/gradle-cache.tar.gz
RUN mkdir -p /root/.gradle && tar xzf /tmp/gradle-cache.tar.gz -C /root/.gradle && rm /tmp/gradle-cache.tar.gz

# Verify the Gradle distribution was extracted correctly
RUN ls /root/.gradle/wrapper/dists/gradle-*/*/gradle-*/bin/gradle || \
    (echo "ERROR: Gradle distribution not found in cache. Rebuild gradle-cache.tar.gz with:" && \
     echo "  ./gradlew --version && tar czf gradle-cache.tar.gz -C ~/.gradle wrapper caches" && exit 1)

# Set GRADLE_USER_HOME so gradlew finds the cached distribution
ENV GRADLE_USER_HOME=/root/.gradle

# Copy config files
COPY pb-autoscaling-test.conf /app/

# Make gradlew executable
RUN chmod +x /app/gradlew

# Default environment
ENV SIMULATION=ReadUpdateTreeDataset
ENV CONFIG_FILE=pb-autoscaling-test.conf
ENV JAVA_OPTS="-Xmx2g -Xms1g"

# Entrypoint runs the simulation then prints summary stats to stdout (captured in pod logs)
ENTRYPOINT ["/bin/sh", "-c", \
  "./gradlew gatlingRun --no-daemon --offline \
    --simulation org.apache.polaris.benchmarks.simulations.${SIMULATION} \
    -Dconfig.file=${CONFIG_FILE} ; \
  EXIT_CODE=$? ; \
  echo '========== GATLING RESULTS SUMMARY ==========' ; \
  echo \"Pod: ${POD_NAME:-unknown}\" ; \
  cat build/reports/gatling/*/js/assertions.json 2>/dev/null || true ; \
  grep -h 'request count' build/reports/gatling/*/simulation.log 2>/dev/null || true ; \
  find build/reports/gatling -name 'index.html' -exec grep -A2 'total col-2\\|error-col' {} \\; 2>/dev/null || true ; \
  echo '==============================================' ; \
  exit $EXIT_CODE"]
