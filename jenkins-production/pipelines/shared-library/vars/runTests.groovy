#!/usr/bin/groovy
// =============================================================
// vars/runTests.groovy — Shared Library: Run test suites
//
// Runs the full test suite inside the build container.
// Publishes JUnit results and coverage reports.
//
// Usage:
//   runTests(
//     type: 'nodejs',        // nodejs | java | golang
//     coverage: true,        // optional, default: true
//     threshold: 80          // optional, minimum coverage %, default: 0 (no gate)
//   )
// =============================================================

def call(Map config = [:]) {
  def type      = config.type      ?: 'nodejs'
  def coverage  = config.coverage  != null ? config.coverage : true
  def threshold = config.threshold ?: 0

  container('build') {
    switch (type) {
      case 'nodejs':
        sh """
          # Install dependencies
          npm ci --prefer-offline

          # Run tests with JUnit reporter and coverage
          npm test -- \
            --ci \
            --reporters=default \
            --reporters=jest-junit \
            --coverageReporters=text \
            --coverageReporters=lcov \
            --coverageReporters=cobertura \
            2>&1
        """

        // Publish JUnit test results
        junit(
          testResults: 'junit.xml',
          allowEmptyResults: false,
          skipPublishingChecks: false
        )

        if (coverage) {
          // Publish coverage report as HTML artifact
          publishHTML(target: [
            allowMissing: false,
            alwaysLinkToLastBuild: true,
            keepAll: true,
            reportDir: 'coverage/lcov-report',
            reportFiles: 'index.html',
            reportName: 'Coverage Report'
          ])

          // Enforce minimum coverage threshold if set
          if (threshold > 0) {
            def coveragePct = sh(
              script: """
                cat coverage/coverage-summary.json \
                  | jq '.total.lines.pct' 2>/dev/null || echo 0
              """,
              returnStdout: true
            ).trim().toDouble()

            echo "Coverage: ${coveragePct}% (threshold: ${threshold}%)"

            if (coveragePct < threshold) {
              unstable("Coverage ${coveragePct}% is below threshold ${threshold}%")
            }
          }
        }
        break

      case 'java':
        sh """
          ./mvnw test \
            -Dsurefire.useFile=true \
            -Dmaven.test.failure.ignore=true \
            --batch-mode
        """
        junit 'target/surefire-reports/**/*.xml'

        if (coverage) {
          jacoco(
            execPattern: 'target/jacoco.exec',
            classPattern: 'target/classes',
            sourcePattern: 'src/main/java',
            minimumLineCoverage: threshold.toString()
          )
        }
        break

      case 'golang':
        sh """
          go test ./... \
            -v \
            -coverprofile=coverage.out \
            -json \
            2>&1 | tee test-output.json | go-junit-report > junit.xml
        """
        junit 'junit.xml'

        if (coverage) {
          def coveragePct = sh(
            script: "go tool cover -func=coverage.out | grep total | awk '{print \$3}' | sed 's/%//'",
            returnStdout: true
          ).trim().toDouble()

          echo "Go coverage: ${coveragePct}%"
          if (threshold > 0 && coveragePct < threshold) {
            unstable("Coverage ${coveragePct}% is below threshold ${threshold}%")
          }
        }
        break

      default:
        error("runTests: unknown type '${type}'. Supported: nodejs, java, golang")
    }
  }

  echo "✅ Tests completed"
}
