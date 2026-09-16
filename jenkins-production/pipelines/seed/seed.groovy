// =============================================================
// pipelines/seed/seed.groovy — Job DSL Seed Job
//
// The seed job creates all other Jenkins jobs from code.
// This is the ONLY job created manually (once, on first setup).
// All other jobs are created by this script.
//
// How it works:
//   1. Install jenkins-production repo as a Multibranch Pipeline
//   2. Scan for Jenkinsfiles in all service repos
//   3. Create Multibranch Pipelines for each service
//
// Run: Jenkins → New Item → "Freestyle" → "seed-job"
//       Build step → Process Job DSLs → Script: this file
// =============================================================

// ── Application pipelines ─────────────────────────────────────
// Each service gets a Multibranch Pipeline.
// Add new services to this list — seed job creates the pipeline automatically.

def services = [
  [name: 'myapp',            repo: 'company/myapp',            branch: 'main'],
  [name: 'user-service',     repo: 'company/user-service',     branch: 'main'],
  [name: 'payment-service',  repo: 'company/payment-service',  branch: 'main'],
  [name: 'notification-svc', repo: 'company/notification-svc', branch: 'main'],
]

services.each { svc ->
  multibranchPipelineJob("services/${svc.name}") {
    description("CI/CD pipeline for ${svc.name}")

    branchSources {
      github {
        id("${svc.name}-source")
        repoOwner('company')
        repository(svc.name.replace('company/', ''))
        credentialsId('github-app-credentials')

        traits {
          // Discover PRs from forks (for open source) or branches
          gitHubBranchDiscovery { strategyId(1) }  // All branches
          gitHubPullRequestDiscovery { strategyId(1) }  // PRs from origin

          // Only build branches with a Jenkinsfile
          headRegexFilter { regex('main|master|develop|feature/.*|hotfix/.*|release/.*') }
        }
      }
    }

    factory {
      workflowBranchProjectFactory {
        scriptPath('Jenkinsfile')
      }
    }

    orphanedItemStrategy {
      discardOldItems {
        // Keep old branch builds for 7 days after branch deleted
        daysToKeep(7)
        numToKeep(5)
      }
    }

    triggers {
      // Scan for new branches every hour (webhook also triggers)
      periodic(60)
    }
  }
}

// ── Infrastructure pipeline ───────────────────────────────────
// Terraform pipeline for infrastructure changes
pipelineJob('infrastructure/terraform-plan') {
  description('Terraform plan for all infrastructure changes')
  definition {
    cpsScm {
      scm {
        git {
          remote { url('https://github.com/company/infrastructure.git') }
          branches('*/main')
          credentials('github-app-credentials')
        }
      }
      scriptPath('pipelines/terraform/Jenkinsfile')
    }
  }
  triggers {
    scm('H/15 * * * *')  // Poll every 15 minutes
  }
}

// ── Maintenance jobs ──────────────────────────────────────────

// Nightly backup job
pipelineJob('maintenance/jenkins-backup') {
  description('Nightly backup of Jenkins home to S3')
  definition {
    cps {
      script('''
        pipeline {
          agent { kubernetes { label 'nodejs' } }
          options { timeout(time: 30, unit: 'MINUTES') }
          stages {
            stage('Backup') {
              steps {
                container('build') {
                  sh """
                    DATE=$(date +%Y%m%d)
                    aws s3 sync /var/jenkins_home \
                      s3://${ARTIFACTS_BUCKET}/backups/${DATE}/ \
                      --exclude "workspace/*" \
                      --exclude "*.log" \
                      --delete
                    echo "Backup complete: s3://${ARTIFACTS_BUCKET}/backups/${DATE}/"
                  """
                }
              }
            }
          }
        }
      '''.stripIndent())
      sandbox(true)
    }
  }
  triggers {
    cron('0 2 * * *')  // 2am daily
  }
}

// Weekly plugin update check (does NOT auto-apply)
pipelineJob('maintenance/plugin-update-check') {
  description('Check for available plugin updates — does not auto-apply')
  definition {
    cps {
      script('''
        pipeline {
          agent { kubernetes { label 'nodejs' } }
          stages {
            stage('Check Updates') {
              steps {
                script {
                  def updates = Jenkins.instance.pluginManager.plugins
                    .findAll { it.hasUpdate() }
                    .collect { "${it.shortName}: ${it.version} → ${it.updateInfo.version}" }
                  if (updates) {
                    currentBuild.description = "${updates.size()} plugin updates available"
                    echo updates.join("\\n")
                    // Notify but do NOT auto-update (reviewed and updated manually)
                    slackSend(
                      channel: '#platform-team',
                      color: 'warning',
                      message: "*${updates.size()} Jenkins plugin updates available:*\\n${updates.take(10).join('\\n')}"
                    )
                  } else {
                    echo "All plugins up to date"
                  }
                }
              }
            }
          }
        }
      '''.stripIndent())
      sandbox(false)  // Needs Jenkins.instance access — requires admin approval
    }
  }
  triggers {
    cron('0 9 * * 1')  // Monday 9am — start of week review
  }
}
