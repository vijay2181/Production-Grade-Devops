# =============================================================
# docker/Dockerfile — Custom Jenkins Controller Image
#
# Why a custom image:
#   - Plugins are baked in at build time (not downloaded at runtime)
#   - Reproducible: same image = same plugins, always
#   - Faster startup: no plugin download delay
#   - Auditable: image digest tracked in GitOps
#
# Build:
#   docker build -t jenkins-controller:2.440.3 ./docker/
#   docker tag jenkins-controller:2.440.3 \
#     123456789012.dkr.ecr.us-east-1.amazonaws.com/jenkins-controller:2.440.3
#   docker push \
#     123456789012.dkr.ecr.us-east-1.amazonaws.com/jenkins-controller:2.440.3
# =============================================================
FROM jenkins/jenkins:2.440.3-jdk17

# Switch to root to install plugins
USER root

# Install system tools needed by some plugins
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    awscli \
    && rm -rf /var/lib/apt/lists/*

# Install cosign for image signing validation
RUN curl -sLo /usr/local/bin/cosign \
    "https://github.com/sigstore/cosign/releases/download/v2.2.3/cosign-linux-amd64" \
    && chmod +x /usr/local/bin/cosign

# Switch back to jenkins user
USER jenkins

# Skip setup wizard — configured entirely via JCasC
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc_configs

# Install plugins from pinned list
# jenkins-plugin-cli is included in the base image
COPY plugins/plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli \
    --plugin-file /usr/share/jenkins/ref/plugins.txt \
    --verbose

# Pre-create directories
RUN mkdir -p /var/jenkins_home/casc_configs \
             /var/jenkins_home/audit \
             /var/jenkins_home/logs
