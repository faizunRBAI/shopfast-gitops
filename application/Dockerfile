# syntax=docker/dockerfile:1

# --- Build stage -----------------------------------------------------------
FROM maven:3.9.9-eclipse-temurin-21 AS build

WORKDIR /build

# Dependencies first so the layer cache survives source-only changes.
COPY pom.xml ./
RUN mvn -B -ntp dependency:go-offline

COPY src ./src
RUN mvn -B -ntp -DskipTests package

# --- Runtime stage ---------------------------------------------------------
FROM eclipse-temurin:21.0.5_11-jre-jammy AS runtime

# Non-root runtime user (CIS Docker 4.1).
RUN groupadd --system --gid 10001 shopfast \
 && useradd --system --uid 10001 --gid shopfast --home /app --shell /usr/sbin/nologin shopfast \
 && mkdir -p /app \
 && chown -R shopfast:shopfast /app

WORKDIR /app

COPY --from=build --chown=shopfast:shopfast /build/target/shopfast.jar /app/shopfast.jar

USER shopfast

EXPOSE 8080

ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+UseContainerSupport" \
    SHOPFAST_RELEASE_COLOR="blue" \
    SHOPFAST_RELEASE_VERSION="dev"

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD ["/bin/sh", "-c", "exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /actuator/health HTTP/1.0\\r\\n\\r\\n' >&3 && grep -q '\"status\":\"UP\"' <&3"]

# Exec form so the JVM is PID 1 and receives SIGTERM for graceful shutdown.
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/shopfast.jar"]
