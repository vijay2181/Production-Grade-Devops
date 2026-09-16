#!/usr/bin/groovy
// =============================================================
// vars/buildImage.groovy — Shared Library: Build Docker image
//
// Uses Kaniko (not Docker socket) — no privileged containers.
// Builds from the workspace Dockerfile, pushes to ECR.
//
// Usage in Jenkinsfile:
//   buildImage(
//     image: 'myapp',
//     tag: env.GIT_COMMIT_SHORT,
//     dockerfile: 'Dockerfile',        // optional, default: Dockerfile
//     context: '.',                    // optional, default: .
//     buildArgs: ['NODE_ENV=production'] // optional
//   )
// =============================================================

def call(Map config = [:]) {
  def image      = config.image      ?: error("buildImage: 'image' parameter required")
  def tag        = config.tag        ?: error("buildImage: 'tag' parameter required")
  def dockerfile = config.dockerfile ?: 'Dockerfile'
  def context    = config.context    ?: '.'
  def buildArgs  = config.buildArgs  ?: []
  def registry   = env.DOCKER_REGISTRY ?: error("DOCKER_REGISTRY env var not set")
  def fullImage  = "${registry}/${image}:${tag}"
  def latestTag  = "${registry}/${image}:latest"

  echo "🔨 Building image: ${fullImage}"

  // Build extra args string
  def extraArgs = buildArgs.collect { "--build-arg ${it}" }.join(' ')

  container('kaniko') {
    // Authenticate with ECR
    // IRSA handles AWS auth — no explicit credential needed
    sh """
      # Get ECR login token and create docker config for Kaniko
      aws ecr get-login-password --region ${env.AWS_REGION} \
        | cat > /tmp/ecr-password

      mkdir -p /kaniko/.docker
      echo '{
        "credHelpers": {
          "${registry.split('/')[0]}": "ecr-login"
        }
      }' > /kaniko/.docker/config.json

      # Build with Kaniko
      # --cache=true: layer caching for faster builds
      # --cache-repo: store cache in ECR
      # --compressed-caching=false: reduces memory usage
      # --snapshot-mode=redo: more accurate but slower (use 'time' for speed)
      /kaniko/executor \
        --context=dir://${context} \
        --dockerfile=${dockerfile} \
        --destination=${fullImage} \
        --destination=${latestTag} \
        --cache=true \
        --cache-repo=${registry}/${image}-cache \
        --cache-ttl=168h \
        --compressed-caching=false \
        --snapshot-mode=redo \
        --log-format=text \
        --verbosity=info \
        ${extraArgs}
    """
  }

  // Store image reference for subsequent stages
  env.BUILT_IMAGE = fullImage
  echo "✅ Image built and pushed: ${fullImage}"

  return fullImage
}
