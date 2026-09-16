#!/usr/bin/groovy
// =============================================================
// vars/notifySlack.groovy — Shared Library: Slack notifications
//
// Sends structured Slack notifications with build context.
// Used at pipeline start, success, failure, and unstable.
//
// Usage:
//   notifySlack(message: 'Build started', color: 'good')
//
//   // Or use the shorthand helpers:
//   notifySlack.started()
//   notifySlack.success()
//   notifySlack.failure(err)
// =============================================================

def call(Map config = [:]) {
  def message = config.message ?: "No message"
  def color   = config.color   ?: "#808080"
  def channel = config.channel ?: "#ci-notifications"

  def jobUrl    = "${env.JENKINS_URL}job/${env.JOB_NAME.replace('/', '/job/')}/${env.BUILD_NUMBER}"
  def shortName = env.JOB_NAME.tokenize('/').last()
  def branch    = env.GIT_BRANCH?.replace('origin/', '') ?: 'unknown'
  def commit    = env.GIT_COMMIT?.take(7) ?: 'unknown'
  def author    = env.GIT_AUTHOR_NAME ?: env.BUILD_USER ?: 'unknown'

  slackSend(
    channel: channel,
    color: color,
    message: """
*${shortName}* #${env.BUILD_NUMBER}
${message}
Branch: `${branch}` | Commit: `${commit}` | By: ${author}
<${jobUrl}|View Build>
    """.stripIndent().trim()
  )
}

// Convenience wrappers
def started() {
  call(message: "⏳ Build started", color: "#808080")
}

def success() {
  call(
    message: "✅ Build succeeded — duration: ${currentBuild.durationString.replace(' and counting', '')}",
    color: "good"
  )
}

def failure(Throwable err = null) {
  def errMsg = err ? "\nError: `${err.getMessage()?.take(200)}`" : ""
  call(
    message: "❌ Build FAILED${errMsg}",
    color: "danger"
  )
}

def unstable() {
  call(
    message: "⚠️ Build UNSTABLE — check test results",
    color: "warning"
  )
}
