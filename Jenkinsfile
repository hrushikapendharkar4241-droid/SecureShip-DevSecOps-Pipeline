// SecureShip – security-gated CI/CD pipeline for ShopPilot
//
//  Checkout → Secret scan → Build images → Tests (inside the image) → SonarQube
//  → Trivy image + Dockerfile scan (+SBOM) → POLICY GATE → Deploy over SSH
//  → Health check (auto-rollback on failure) → DAST (OWASP ZAP) → Evidence + ledger
//
// Every stage writes machine-readable results to reports/. The gate reads all of them
// and decides PASS/FAIL against security/policy.yaml. Nothing reaches the server unless
// the gate passes, and nothing stays on the server unless it proves it is healthy.

pipeline {
    agent any

    options {
        timestamps()
        ansiColor('xterm')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '30'))
        timeout(time: 90, unit: 'MINUTES')
    }

    triggers {
        // Free & works behind NAT. With a Cloudflare Tunnel you can use a GitHub webhook instead.
        pollSCM('H/5 * * * *')
    }

    parameters {
        string(name: 'APP_REPO', defaultValue: (env.APP_REPO_URL ?: 'https://github.com/hrushikapendharkar4241-droid/shoppilot.git'),
               description: 'ShopPilot Git repository')
        string(name: 'APP_BRANCH', defaultValue: 'master', description: 'Branch to build (ShopPilot uses master)')
        // ShopPilot is a private repo: bootstrap.sh stores a read-only token as credential 'shoppilot-git'
        string(name: 'APP_CREDENTIALS_ID', defaultValue: (env.APP_GIT_CREDENTIALS_ID ?: ''),
               description: "Jenkins credential for a private ShopPilot repo ('shoppilot-git' from bootstrap; blank = public repo)")
        booleanParam(name: 'DEPLOY', defaultValue: true, description: 'Deploy when the security gate passes')
        choice(name: 'CHAOS_MODE', choices: ['none', 'crash', 'unhealthy'],
               description: 'DEMO ONLY – ship a deliberately broken backend to prove automatic rollback')
        booleanParam(name: 'RUN_DAST', defaultValue: true, description: 'OWASP ZAP baseline scan against the deployed app')
    }

    environment {
        IMAGE_PREFIX = 'shoppilot'
        SONAR_PROJECT_KEY = 'shoppilot'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                sh 'rm -rf reports && mkdir -p reports && chmod +x scripts/*.sh scripts/remote/*.sh'
                script {
                    dir('app') {
                        if (params.APP_CREDENTIALS_ID?.trim()) {
                            git url: params.APP_REPO, branch: params.APP_BRANCH, credentialsId: params.APP_CREDENTIALS_ID
                        } else {
                            git url: params.APP_REPO, branch: params.APP_BRANCH
                        }
                    }
                    env.APP_COMMIT = sh(script: 'git -C app rev-parse HEAD', returnStdout: true).trim()
                    env.APP_TAG = "${env.BUILD_NUMBER}-${env.APP_COMMIT.substring(0, 8)}"
                    env.APP_REPO = params.APP_REPO
                    env.APP_BRANCH = params.APP_BRANCH
                    env.CHAOS_MODE = params.CHAOS_MODE
                    currentBuild.displayName = "#${env.BUILD_NUMBER} · ${env.APP_COMMIT.substring(0, 8)}"
                }
                sh 'scripts/record-build.sh'
            }
        }

        stage('Secret Scan') {
            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    sh 'scripts/secrets-scan.sh'
                }
            }
        }

        stage('Build Images') {
            steps {
                sh 'scripts/build.sh'
            }
        }

        stage('Unit & API Tests') {
            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    sh 'scripts/test.sh'
                }
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'reports/tests/junit.xml'
                }
            }
        }

        stage('SonarQube') {
            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
                        sh 'scripts/sonar.sh'
                    }
                }
            }
        }

        stage('Trivy Scan + SBOM') {
            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    sh 'scripts/scan.sh'
                }
            }
        }

        stage('Security Gate') {
            steps {
                script {
                    int rc = sh(script: 'scripts/gate.sh', returnStatus: true)
                    env.GATE_DECISION = (rc == 0) ? 'PASS' : 'FAIL'
                    if (rc != 0) {
                        error('SECURITY GATE FAILED – deployment blocked. See reports/gate.json and evidence.html')
                    }
                }
            }
        }

        stage('Deploy + Health Check') {
            when {
                allOf {
                    expression { params.DEPLOY }
                    expression { env.GATE_DECISION == 'PASS' }
                }
            }
            steps {
                withCredentials([sshUserPrivateKey(credentialsId: 'deploy-ssh-key', keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')]) {
                    script {
                        int rc = sh(script: 'scripts/deploy.sh', returnStatus: true)
                        env.DEPLOY_RC = "${rc}"
                        if (rc == 2) {
                            error('New release failed its health check – AUTOMATICALLY ROLLED BACK to the previous version')
                        } else if (rc != 0) {
                            error("Deployment failed (exit ${rc}) – check reports/deploy.log")
                        }
                    }
                }
            }
        }

        stage('DAST (OWASP ZAP)') {
            when {
                allOf {
                    expression { params.RUN_DAST }
                    expression { env.DEPLOY_RC == '0' }
                }
            }
            steps {
                script {
                    int rc = sh(script: 'scripts/dast.sh', returnStatus: true)
                    if (rc != 0) {
                        unstable('DAST reported high-risk alerts – see reports/dast/zap.html')
                    }
                }
            }
        }
    }

    post {
        always {
            script {
                withEnv(["PIPELINE_RESULT=${currentBuild.currentResult}", "DEPLOY_ENABLED=${params.DEPLOY}"]) {
                    // Ledger key signs the entry; the deploy SSH key reaches the append-only anchor
                    // store on the server; an optional Git anchor repo adds a second, independent store.
                    def binds = [
                        string(credentialsId: 'ledger-hmac-key', variable: 'LEDGER_KEY'),
                        sshUserPrivateKey(credentialsId: 'deploy-ssh-key', keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')
                    ]
                    if (env.ANCHOR_GIT_REPO) {
                        binds.add(usernamePassword(credentialsId: 'ledger-anchor-git', usernameVariable: 'ANCHOR_GIT_USER', passwordVariable: 'ANCHOR_GIT_TOKEN'))
                    }
                    int rc
                    try {
                        withCredentials(binds) {
                            rc = sh(script: 'scripts/evidence.sh', returnStatus: true)
                        }
                    } catch (err) {
                        echo "Ledger/anchor credentials unavailable (${err.getMessage()}) – writing an unsigned, unanchored entry"
                        rc = sh(script: 'scripts/evidence.sh', returnStatus: true)
                    }
                    if (rc == 2) {
                        currentBuild.result = 'FAILURE'
                        echo 'LEDGER INTEGRITY PROBLEM – the release history does not match its hash chain or external anchors. See reports/ledger-verify.json'
                    } else if (rc == 3) {
                        unstable('Ledger entry could not be anchored externally – see reports/anchor-status.json')
                    } else if (rc != 0) {
                        unstable("Evidence step failed (exit ${rc})")
                    }
                }
            }
            archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true, fingerprint: true
            echo "Evidence report: ${env.BUILD_URL}artifact/reports/evidence.html"
        }
        cleanup {
            sh 'scripts/cleanup.sh || true'
        }
    }
}
