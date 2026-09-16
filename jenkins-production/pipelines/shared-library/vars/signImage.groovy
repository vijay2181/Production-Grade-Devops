#!/usr/bin/groovy
// =============================================================
// vars/signImage.groovy — Shared Library: Sign image with Cosign
//
// Signs the container image using Cosign keyless signing (OIDC)
// or key-based signing depending on environment.
// Signature stored in ECR alongside the image.
// Kyverno policy (Project 4) verifies signature at deploy time.
//
// Usage:
//   signImage(image: env.BUILT_IMAGE)
// =============================================================

def call(Map config = [:]) {
  def image = config.image ?: env.BUILT_IMAGE ?: error("signImage: no image specified")

  echo "✍️  Signing image: ${image}"

  container('build') {
    // Install cosign if not present in the container
    sh '''
      if ! command -v cosign &>/dev/null; then
        curl -sLo /usr/local/bin/cosign \
          "https://github.com/sigstore/cosign/releases/download/v2.2.3/cosign-linux-amd64"
        chmod +x /usr/local/bin/cosign
      fi
    '''

    withCredentials([
      string(credentialsId: 'cosign-private-key', variable: 'COSIGN_PRIVATE_KEY'),
      string(credentialsId: 'cosign-password',    variable: 'COSIGN_PASSWORD')
    ]) {
      sh """
        # Write private key to temp file (never log it)
        echo "\${COSIGN_PRIVATE_KEY}" > /tmp/cosign.key
        chmod 600 /tmp/cosign.key

        # Sign the image
        # --yes: non-interactive
        # The signature is pushed to the same ECR repository as the image
        cosign sign \
          --key /tmp/cosign.key \
          --yes \
          ${image}

        # Clean up private key immediately
        rm -f /tmp/cosign.key

        echo "Signature stored in ECR alongside ${image}"
      """
    }
  }

  echo "✅ Image signed: ${image}"
}
