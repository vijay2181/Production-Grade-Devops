#!/usr/bin/groovy
// =============================================================
// vars/deployToEKS.groovy — Shared Library: Deploy via ArgoCD
//
// This function does NOT run kubectl directly against the cluster.
// Instead, it:
//   1. Updates the image tag in the GitOps repository
//   2. Commits and pushes the change
//   3. Triggers an ArgoCD sync via the ArgoCD API
//   4. Waits for the sync to complete and health check to pass
//
// Why not kubectl:
//   - Cluster state must always reflect Git (GitOps contract)
//   - kubectl bypasses ArgoCD drift detection
//   - No kubeconfig files stored in Jenkins
//
// Usage:
//   deployToEKS(
//     environment: 'dev',              // dev | staging | prod
//     image: env.BUILT_IMAGE,
//     appName: 'myapp',
//     gitopsRepo: 'company/gitops',    // optional, uses GITOPS_REPO env if not set
//     waitForHealth: true              // optional, default: true
//   )
// =============================================================

def call(Map config = [:]) {
  def environment  = config.environment  ?: error("deployToEKS: 'environment' required")
  def image        = config.image        ?: env.BUILT_IMAGE ?: error("deployToEKS: no image")
  def appName      = config.appName      ?: env.APP_NAME ?: error("deployToEKS: 'appName' required")
  def gitopsRepo   = config.gitopsRepo   ?: env.GITOPS_REPO ?: error("deployToEKS: GITOPS_REPO not set")
  def waitForHealth = config.waitForHealth != null ? config.waitForHealth : true
  def argocdApp    = "${appName}-${environment}"
  def imageTag     = image.split(':').last()

  echo "🚀 Deploying ${appName}:${imageTag} to ${environment}"

  container('build') {
    withCredentials([gitUsernamePassword(
      credentialsId: 'github-app-credentials',
      gitToolName: 'Default'
    )]) {
      // Step 1: Update image tag in GitOps repo
      sh """
        # Clone the GitOps repository
        git clone https://github.com/${gitopsRepo}.git /tmp/gitops
        cd /tmp/gitops

        # Update image tag using kustomize edit
        # Path: apps/${appName}/overlays/${environment}/kustomization.yaml
        cd apps/${appName}/overlays/${environment}
        kustomize edit set image ${appName}=${image}

        # Verify the change
        grep -A1 'images:' kustomization.yaml

        # Commit and push
        git config user.email "jenkins@company.com"
        git config user.name "Jenkins CI"
        git add kustomization.yaml
        git diff --staged --stat

        # Only commit if there are actual changes
        if git diff --staged --quiet; then
          echo "No changes to commit — image tag already matches"
        else
          git commit -m "ci: deploy ${appName}:${imageTag} to ${environment}

          Deployed by: Jenkins build #${env.BUILD_NUMBER}
          Pipeline: ${env.JOB_NAME}
          Commit: ${env.GIT_COMMIT}
          Triggered by: ${env.BUILD_USER ?: 'automated'}"

          git push origin main
          echo "✅ GitOps repo updated"
        fi
      """
    }

    // Step 2: Trigger ArgoCD sync
    withCredentials([string(credentialsId: 'argocd-token', variable: 'ARGOCD_TOKEN')]) {
      sh """
        ARGOCD_SERVER="${env.ARGOCD_SERVER}"

        # Trigger sync
        curl -sf -X POST \
          -H "Authorization: Bearer \${ARGOCD_TOKEN}" \
          -H "Content-Type: application/json" \
          "https://\${ARGOCD_SERVER}/api/v1/applications/${argocdApp}/sync" \
          -d '{"prune": true, "dryRun": false}' \
          | jq .status.operationState.phase

        echo "ArgoCD sync triggered for ${argocdApp}"
      """

      if (waitForHealth) {
        // Step 3: Wait for ArgoCD to report Healthy
        timeout(time: 10, unit: 'MINUTES') {
          sh """
            ARGOCD_SERVER="${env.ARGOCD_SERVER}"
            echo "Waiting for ${argocdApp} to become Healthy..."

            for i in \$(seq 1 60); do
              HEALTH=\$(curl -sf \
                -H "Authorization: Bearer \${ARGOCD_TOKEN}" \
                "https://\${ARGOCD_SERVER}/api/v1/applications/${argocdApp}" \
                | jq -r .status.health.status)

              SYNC=\$(curl -sf \
                -H "Authorization: Bearer \${ARGOCD_TOKEN}" \
                "https://\${ARGOCD_SERVER}/api/v1/applications/${argocdApp}" \
                | jq -r .status.sync.status)

              echo "[\${i}/60] Health: \${HEALTH} | Sync: \${SYNC}"

              if [ "\${HEALTH}" = "Healthy" ] && [ "\${SYNC}" = "Synced" ]; then
                echo "✅ ${argocdApp} is Healthy and Synced"
                exit 0
              fi

              if [ "\${HEALTH}" = "Degraded" ]; then
                echo "❌ ${argocdApp} health is Degraded — deployment failed"
                exit 1
              fi

              sleep 10
            done

            echo "❌ Timeout waiting for ${argocdApp} to become healthy"
            exit 1
          """
        }
      }
    }
  }

  echo "✅ Deployed ${appName}:${imageTag} to ${environment}"
}
