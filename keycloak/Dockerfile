# Build Keycloak theme
FROM maven:3.9-eclipse-temurin-17 AS theme-builder
WORKDIR /app

RUN apt-get update -qq && apt-get install -y -qq nodejs npm

COPY optimce-keycloak-theme/package.json optimce-keycloak-theme/package-lock.json* ./
RUN npm install

COPY optimce-keycloak-theme/ .
RUN npm run build-keycloak-theme

# Extract, rename and repackage theme
FROM ubuntu:resolute@sha256:5e275723f82c67e387ba9e3c24baa0abdcb268917f276a0561c97bef9450d0b4 AS theme-extractor
RUN apt-get update -qq && apt-get install -y -qq unzip zip && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY --from=theme-builder /app/dist_keycloak/keycloak-theme-for-kc-all-other-versions.jar .
RUN mkdir -p /theme-fix /dist && \
    cd /theme-fix && \
    unzip -o /src/keycloak-theme-for-kc-all-other-versions.jar && \
    mv theme/keycloakify-starter theme/optimce && \
    echo '{"themes":[{"name":"optimce","types":["login"]}]}' > META-INF/keycloak-themes.json && \
    zip -r /dist/keycloak-theme-for-kc-all-other-versions.jar META-INF theme && \
    cd / && rm -rf /theme-fix /src

# Build kc-groupid-mapper
FROM maven:3.9.6-eclipse-temurin-17 AS builder
WORKDIR /app

COPY kc-groupid-mapper/pom.xml .
RUN mvn -B -q -e -DskipTests dependency:go-offline

COPY kc-groupid-mapper/src ./src
RUN mvn -B -q -DskipTests package

# Final stage
FROM quay.io/keycloak/keycloak:26.5.5@sha256:a7b0cb7a43a1235a61872883414d3f1d9a3ceac9df6e5907bd12202778a6265c
WORKDIR /opt/keycloak
COPY --from=theme-extractor /dist/keycloak-theme-for-kc-all-other-versions.jar /opt/keycloak/providers/
COPY --from=builder /app/target/kc-groupid-mapper-*.jar /opt/keycloak/providers/
RUN /opt/keycloak/bin/kc.sh build
