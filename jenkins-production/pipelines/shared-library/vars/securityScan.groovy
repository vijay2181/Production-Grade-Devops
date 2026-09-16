#!/usr/bin/groovy
// =============================================================
// vars/securityScan.groovy — Shared Library: Security scanning
//
// Runs Trivy image vulnerability scan.
// CRITICAL CVEs fail the pipeline.
// HIGH CVEs generate a warning but allow continuation.
// Results stored as a Jenkins artifact.
//
// Usage:
//   securityScan(
//     image: env.BUILT_IMAGE,
//     failOnSeverity: 'CRITICAL',   // optional, default: CRITICAL
//     ignoreUnfixed: true           // optional, default: true
//   )
// =============================================================

def call(Map config = [:]) {
  def image          = config.image          ?: env.BUILT_IMAGE ?: error("securityScan: no image specified")
  def failOnSeverity = config.failOnSeverity ?: 'CRITICAL'
  def ignoreUnfixed  = config.ignoreUnfixed  != null ? config.ignoreUnfixed : true
  def outputFile     = 'trivy-results.json'

  echo "🔍 Scanning image: ${image}"

  container('trivy') {
    def ignoreFlag = ignoreUnfixed ? '--ignore-unfixed' : ''

    // Run scan — exit code 1 if vulnerabilities found at threshold severity
    def exitCode = sh(
      script: """
        trivy image \
          --severity ${failOnSeverity},HIGH,MEDIUM \
          --format json \
          --output ${outputFile} \
          --exit-code 1 \
          --no-progress \
          ${ignoreFlag} \
          ${image} 2>&1 || true

        # Also generate a human-readable table for the build log
        trivy image \
          --severity ${failOnSeverity},HIGH,MEDIUM \
          --format table \
          --no-progress \
          ${ignoreFlag} \
          ${image} 2>&1
      """,
      returnStatus: true
    )

    // Archive results regardless of pass/fail
    archiveArtifacts artifacts: outputFile, allowEmptyArchive: false

    // Count CVEs by severity from JSON output
    def criticalCount = sh(
      script: "cat ${outputFile} | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity==\"CRITICAL\")] | length' 2>/dev/null || echo 0",
      returnStdout: true
    ).trim().toInteger()

    def highCount = sh(
      script: "cat ${outputFile} | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity==\"HIGH\")] | length' 2>/dev/null || echo 0",
      returnStdout: true
    ).trim().toInteger()

    echo "📊 Scan results — CRITICAL: ${criticalCount} | HIGH: ${highCount}"

    if (criticalCount > 0) {
      // Notify Slack before failing
      notifySlack(
        message: "🚨 Image scan FAILED: ${criticalCount} CRITICAL CVEs in `${image}`\nCheck build artifacts for details.",
        color: 'danger'
      )
      error("Security scan failed: ${criticalCount} CRITICAL vulnerabilities found in ${image}")
    }

    if (highCount > 0) {
      unstable("⚠️ ${highCount} HIGH severity vulnerabilities found — review trivy-results.json")
    }

    echo "✅ Security scan passed"
  }
}
